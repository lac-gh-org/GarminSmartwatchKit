import ConnectIQ
import Foundation
import Testing

@testable import GarminSmartwatchKit

/// The Connect IQ SDK's callback thread is undocumented, so its callbacks are made here from a
/// background queue; and `delete()` must leave nothing that can still send.
@MainActor
@Suite("Garmin threading and deletion", .serialized) struct GarminThreadingTests {
    /// Runs an SDK callback the way the SDK might: off the main thread.
    private func onBackground(_ work: @escaping () -> Void) {
        nonisolated(unsafe) let work = work
        DispatchQueue.global().async { work() }
    }

    // MARK: - Callbacks off the main thread

    @Test("A device status from a background queue settles on main and gates sends")
    func statusFromBackground() async {
        let rig = DeliveryRig()
        nonisolated(unsafe) let manager = rig.manager
        nonisolated(unsafe) let device = rig.deviceA

        onBackground { manager.deviceStatusChanged(device, status: .notConnected) }
        #expect(await rig.eventually { rig.manager.disconnectedDevices == [rig.deviceA.uuid] })

        rig.broadcast(120)
        #expect(rig.sends(on: rig.deviceA).isEmpty)
        #expect(rig.sends(on: rig.deviceB).count == 2)

        onBackground { manager.deviceStatusChanged(device, status: .connected) }
        #expect(await rig.eventually { rig.manager.disconnectedDevices.isEmpty })
        rig.broadcast(120)
        #expect(rig.sends(on: rig.deviceA).count == 2)
        #expect(rig.spy.offMainSends == 0)
    }

    @Test("Characteristics discovered from a background queue flush the owed state on main")
    func characteristicsFromBackground() async {
        let rig = DeliveryRig()
        rig.manager.deviceStatusChanged(rig.deviceA, status: .notConnected)
        rig.broadcast(120)
        #expect(rig.manager.owedDeliveries.count == 2)

        nonisolated(unsafe) let manager = rig.manager
        nonisolated(unsafe) let device = rig.deviceA
        onBackground { manager.deviceCharacteristicsDiscovered(device) }

        #expect(await rig.eventually { rig.sends(on: rig.deviceA).count == 2 })
        #expect(rig.manager.owedDeliveries.isEmpty)
        #expect(rig.manager.disconnectedDevices.isEmpty)
        #expect(rig.spy.offMainSends == 0)
    }

    @Test("A message from a background queue clears the absent mark and delivers what is owed, on main")
    func messageFromBackground() async {
        let rig = DeliveryRig()
        let key = rig.key(rig.swissalpineUUID, on: rig.deviceA)
        rig.spy.setResult(.failure_AppNotFound, for: rig.swissalpineUUID, on: rig.deviceA.uuid)
        rig.broadcast(120)
        #expect(rig.manager.absentApps == [key])
        rig.spy.setResult(nil, for: rig.swissalpineUUID, on: rig.deviceA.uuid)

        nonisolated(unsafe) let manager = rig.manager
        nonisolated(unsafe) let app = rig.app(rig.swissalpineUUID, on: rig.deviceA)
        onBackground { manager.receivedMessage(["v": 1, "req": "nothing"], from: app) }

        #expect(await rig.eventually { rig.manager.lastSentDataHashes[key] != nil })
        #expect(rig.manager.absentApps.isEmpty)
        #expect(rig.manager.owedDeliveries[key] == nil)
        #expect(rig.sends(to: rig.swissalpineUUID, on: rig.deviceA).count == 2)
        #expect(rig.spy.offMainSends == 0)
    }

    // MARK: - Deletion

    @Test("Deleting clears the delivery state")
    func deleteClearsState() async {
        let rig = DeliveryRig()
        rig.manager.deviceStatusChanged(rig.deviceA, status: .notConnected)
        rig.spy.setResult(.failure_AppNotFound, for: rig.swissalpineUUID, on: rig.deviceB.uuid)
        rig.broadcast(120)
        #expect(!rig.manager.owedDeliveries.isEmpty)
        #expect(!rig.manager.absentApps.isEmpty)
        #expect(!rig.manager.lastSentDataHashes.isEmpty)

        await rig.manager.delete()

        #expect(rig.manager.isDeleted)
        #expect(rig.manager.owedDeliveries.isEmpty)
        #expect(rig.manager.absentApps.isEmpty)
        #expect(rig.manager.lastSentDataHashes.isEmpty)
    }

    @Test("A resend still waiting for its delay is not sent after deletion")
    func noRetryAfterDelete() async {
        let rig = DeliveryRig(datafield: .none, devices: [0])
        rig.manager.sendRetryDelay = 0.2
        rig.spy.script([.failure_Timeout], for: rig.watchfaceUUID, on: rig.deviceA.uuid)
        rig.broadcast(120)
        #expect(rig.spy.sent.count == 1)

        await rig.manager.delete()
        await rig.settle(0.5)

        #expect(rig.spy.sent.count == 1, "The pending resend was dropped")
    }

    @Test("A send completing after deletion does not flush what its app was owed")
    func noOwedFlushAfterDelete() async {
        let rig = DeliveryRig(datafield: .none, devices: [0])
        rig.spy.holdsCompletions = true
        rig.broadcast(120)
        #expect(rig.spy.pendingCount == 1)
        // The app becomes owed a newer state while the first send is still in flight.
        rig.manager.deviceStatusChanged(rig.deviceA, status: .notConnected)
        rig.broadcast(121)
        rig.manager.deviceStatusChanged(rig.deviceA, status: .connected)
        #expect(rig.spy.sent.count == 1)

        await rig.manager.delete()
        rig.spy.holdsCompletions = false
        rig.spy.completePending(onBackground: true)
        await rig.settle()

        #expect(rig.spy.sent.count == 1, "The owed state was not sent")
        #expect(rig.manager.lastSentDataHashes.isEmpty)
    }

    @Test("After deletion, broadcasts, reconnects and messages send nothing")
    func nothingSentAfterDelete() async {
        let rig = DeliveryRig()
        rig.manager.deviceStatusChanged(rig.deviceA, status: .notConnected)
        rig.broadcast(120)
        let before = rig.spy.sent.count

        await rig.manager.delete()
        rig.broadcast(121)
        rig.manager.deviceCharacteristicsDiscovered(rig.deviceA)
        rig.hearFrom(rig.watchfaceUUID, on: rig.deviceA)
        rig.manager.receivedMessage("status", from: rig.app(rig.watchfaceUUID, on: rig.deviceB))
        rig.manager.updateDeviceList([rig.deviceA])
        await rig.settle()

        #expect(rig.spy.sent.count == before)
    }
}
