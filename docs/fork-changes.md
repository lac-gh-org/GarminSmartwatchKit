# Changes on lac-gh-org's `trio-app` not yet in dabear's `main`

What this fork's `trio-app` (and `loop-app`, which merges it) carries beyond
dabear/GarminSmartwatchKit `main`, so each can go upstream as its own small PR.
Keep this list up to date with each change; drop an entry once it's merged.

This file is for the fork only: leave it out of upstream PRs.

## Merged upstream

- **Loop fixes**, PR #3, merged 2026-11-16 as e737268: plugin binary as a dynamic
  library (910df21), insulin sensitivity in Loop's unit (5be6d2f), the host's own
  glucose readings (89d3dd4, 06c704f). trio-app and loop-app merged dabear's main
  (up to bc42aee, hostDidReceiveURL) on 2026-11-16.

## Still to PR, in a sensible order

1. **WatchAID entry** (6c9a494): the sideloaded watch app as a watchface choice,
   the host's full 3 h at 5-minute spacing, and a sideload note in the settings.
   Wants the watch app public, or at least linked, first.
2. **Host name** (4608d2a): `host` ("Trio", "Loop", from CFBundleDisplayName) in
   the first entry, for display only. Watch apps must work without it.
3. **Glucose Colors hidden for a Loop host** (7eb8e4b): needs 2. Uses the host name
   because nothing in the delegate exposes the host's look; raise this with dabear
   (his rule: no functionality from the host name when the delegate exposes it).
4. **Time in range** (2026-11-15, matched to Trio's home stats panel 2026-11-16):
   a Time in Range settings section: Show on Watch (on by default, as Trio's home
   panel), then Period (Today, the default as in Trio / Past 24 Hours) and
   Range (Standard 70–180, default / Extended 63–180 mg/dL, Trio's
   `TimeInRangeType`); `tirLow`, `tirInRange`, `tirHigh` in the first entry, whole
   percent adding up to 100, from the first reading of the period on.
   The host is now read back 24 h (25 h on the day the clocks go back), not 3 h;
   what the watch shows still covers 3 h. Comes with the WatchAID arc that uses it.
   - Possible follow-up: Trio has its own Statistics Range and lower limit
     (`homeStatsPanelRange`, `timeInRangeType` 70/63) that the kit can't see, so on
     Trio the watch can differ from Trio's home panel. Matching it needs a new
     optional delegate call in LoopKit's SmartwatchManagerDelegate (default `nil`,
     so Loop needn't change), Trio's adapter, and the kit preferring the host's
     values. Left out so as not to touch LoopKit while #684 is in review.
5. **Settings decode one by one** (with 4): a setting missing from saved settings
   takes its default instead of resetting all of them. Worth upstream on its own:
   without it, any new setting resets every user's Garmin settings on update.

## Fork only, never upstream

- The Trio App entry (ce95517, c836811), removed again in ff0a8d0: net zero.
- 2c7dd81, reverted by 910df21: net zero.
- 61ef5d2, the test helper rename after dabear's SmartwatchManager rework (his main
  made the same rename in fb83e6c; check nothing else is left in it).
- This file.

The kit's tests need LoopKit next-dev (dabear's 8e8ef67), so "Kit tests" CI runs
them in Loop's workspace until Trio's LoopKit is on next-dev. Trio builds still
compile the kit's code, just not its tests.
