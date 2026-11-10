# GarminSmartwatchKit — experimental

> **Experimental.** Not tested on a Garmin yet. Don't rely on it for treatment decisions.

Garmin (Connect IQ) as a LoopKit `SmartwatchManager` plugin, for hosts such as [Trio](https://github.com/nightscout/Trio) and Loop.

It is derived from Trio's `GarminManager`, `GarminWatchState` and `GarminWatchSettings` (Trio contributors, MIT). The Connect IQ code is Trio's. What changed is where the data comes from: the plugin builds the Garmin watch state only from the host's `SmartwatchStatusSnapshot`, and keeps its devices and settings in its own `rawState`.

## What it does

- Sends glucose (with up to 24 readings of history for SwissAlpine and the complication app), trend, delta, IOB, COB, last loop, temp or scheduled basal, ISF, eventual glucose, sensitivity ratio and target to:
  - a watchface or watch app: Trio, SwissAlpine, or Complication;
  - a datafield: Trio or SwissAlpine.
- **Display only:** it declares `glucose`, `history`, `loopStatus` and `therapy`, and no remote actions. Nothing goes from the watch to the host.
- Settings: watches (chosen in Garmin Connect), watch apps, display values and glucose colours.
- Logs go to the host's device log.

## Using it

- **Frameworks:** `GarminSmartwatchKit` and `GarminSmartwatchKitUI`, for hosts that link plugins (Trio).
- **Plugin bundle:** `GarminSmartwatchPlugin.loopplugin`, for hosts that load plugin bundles (Loop). Its `Info.plist` still sets `com.loopkit.Loop.PluginComingSoon`, but no host reads that key any more: Loop's Garmin and personal builds load the plugin and offer it in Add Watch like any watch.
- **Dependencies:** LoopKit and LoopKitUI (the `next-dev` API, as Loop and Trio since #1718 use) from the host's workspace, and Garmin's [Connect IQ SDK](https://github.com/garmin/connectiq-companion-app-sdk-ios) (Swift package).
- **Host app:** needs a URL scheme (Garmin Connect calls back with the chosen watches; the host passes that URL to `watchHostDidReceiveURL`) and `LSApplicationQueriesSchemes` for Garmin Connect (`gcm-ciq`), as Trio and Loop's Garmin and personal branches have.

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`; the generated project is committed.

## Screenshot

Until 2026-11-09 Loop's personal build listed Garmin as coming soon, as below; it now offers Garmin like any watch:

<img src="docs/loop-add-watch-coming-soon.png" width="220" alt="Loop's Add Watch: Pebble, and Garmin marked Coming soon">

## Licence

MIT. See `LICENSE`, which keeps Trio's copyright notice.
