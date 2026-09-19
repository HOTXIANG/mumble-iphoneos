# Live Activity regression checks

Run from the repository root on a Mac with Xcode and Python 3:

```sh
bash Tests/live_activity/run_tests.sh
```

The script extracts the actual Live Activity methods from
`ServerModelManager+HandoffLiveActivity.swift` and compiles them with Swift 6.
`Harness.swift` supplies small ActivityKit and server model doubles. Production
logic is not copied into the tests. Generated files and the compiler cache are
created in a temporary directory and removed when the script exits.

The checks cover accurate initial content, repeated snapshot deduplication,
burst coalescing, muted speaker filtering, reconnect timer restoration,
immediate stale-date renewal for an unchanged reconnect snapshot, heartbeat
isolation from Handoff, serial writes and state reversion during a suspended
write, ending during a pending write, rapid reconnect, server switching, and
cancellation during the coalescing window. The fake async update deliberately
continues after cancellation to exercise the race with ending an activity.

These tests verify manager behavior. They do not simulate ActivityKit scheduling,
system update budgets, background execution, or device rendering. The mock
activity is actor-isolated, so Swift may report that the production
`nonisolated(unsafe)` bindings are unnecessary for this mock type; the actual
ActivityKit type still needs the production app's build verification.

## Simulator visual checks

The DEBUG iOS Simulator app exposes `liveActivity.start`, `update`, `list`, and
`end` through the existing `ws://localhost:54296` test server. These commands are
excluded from device and Release builds. Launch an idle app in the foreground;
no Mumble server connection is needed. The fixtures use the actual app's
`MumbleActivityAttributes` and widget extension.

```sh
python3 Tests/live_activity/simulator_command.py start '{"fixture":"speaking","serverName":"Mumble Preview"}'
python3 Tests/live_activity/simulator_command.py list
python3 Tests/live_activity/simulator_command.py update '{"id":"ID_FROM_START","fixture":"longNames"}'
python3 Tests/live_activity/simulator_command.py end
```

Preset `fixture` values are `listening`, `speaking`, `muted`, `deafened`, and
`longNames`. Start/update also accept `speakers`, `channelName`, `userCount`,
`isSelfMuted`, and `isSelfDeafened` overrides. An update without a preset preserves
unmentioned content fields. `serverName` is static and can only be set on start.
`staleAfter` defaults to 3600 seconds; set it to 0 to inspect stale presentation.
`relevanceScore` defaults to 100 and accepts values from 0 to 100.

After starting, return Home to inspect compact presentation and hold the island
to inspect expanded presentation. Check the lock screen, too. To inspect the
system's two-activity layout, keep an activity from a second app active alongside
Mumble, then inspect Mumble's minimal presentation in both island positions.
Multiple Mumble fixtures can also be started to inspect the lock screen stack;
the system decides which activity or activities to show on the island.

`end` with an `id` ends that fixture. With no `id`, it immediately removes all
fixtures registered by these commands, including across debug app relaunches.
It never ends unregistered server activities. Clean up fixtures before connecting
to a real server. The script uses the repository's standard-library WebSocket
client, so no third-party Python packages are required.

Registered fixtures survive the disconnected-app foreground cleanup in DEBUG
Simulator builds, so opening permission prompts or returning to the app does not
remove the test data. Explicit fixture cleanup and app termination still end them.
ActivityKit may propagate an update after the command response; inspect the
rendered surface or call `list` again before asserting the new state.

### Verified on iPhone 17 Pro Simulator (iOS 27.0)

Visual checks on 2026-09-11/12 used the production widget extension and a separate
temporary timer app to produce the system's real two-app presentation:

- Single compact view, expanded view, and stacked lock-screen cards.
- Mumble in both attached and detached minimal positions; the 24-point indicator
  stays within the island for speaking, muted, and deafened states.
- Short names show two speakers; long names fall back to one speaker and the
  remaining count changes accordingly (four long names show one name plus `+3`).
- Long channel names and 128 participants at standard and XXXL system text sizes;
  the widget caps Dynamic Type at XL to fit the system's height limit.
- Stale content hides outdated speaker/participant counts and offers a refresh
  message. Purple indicators match the icon hue, with brighter foregrounds for
  the black island and distinct mute/deafen status colors.

Local visual evidence is in the ignored `Tests/Artifacts/live_activity/` directory:
`15-dual-island-final.png`, `16-expanded-final.png`,
`13-lock-long-names-final.png`, and `14-lock-large-type-final.png`.
Earlier dual-position/state evidence is in `06-lock-two-activities.png`,
`07-two-detached-speaking.png`, `08-two-detached-muted.png`,
`09-two-detached-deafened.png`, and `10-expanded-stale.png`.
Use `simctl io <UDID> screenshot --mask black` to include the Dynamic Island
composite in saved simulator screenshots. These are simulator checks; physical
device update budgets and background scheduling are not covered.
