# Native action and lifetime audit

Date: 2026-10-24. Source reviewed at `69f6e08` plus the narrow fixes described below. This is a source review and a Linux guardian regression report, **not a replacement for the currently failing macOS GUI launch gate**.

## Findings fixed in this audit

### Test-launch isolation

`SystemToolsController.startKeepAwake` and `startCleanScreen` previously had no test-launch guard. The native UI automation allowlist did not invoke them, but a normal call to these public controller entry points could still create a real long-lived power assertion or present overlays during a fixture/benchmark launch.

- `SystemToolsController.swift:90,99,228`: normal user tool actions now reject any launch recognized by `ReadOnlyBenchmark.isTestLaunch`, before stopping or starting any session.
- `SystemToolsView.swift:67,90`: the corresponding Start controls are disabled in that mode.
- `ProcessInspectorView.swift:86`: Open Activity Monitor now has both an action guard and a disabled state in test launches.
- The separate `runSafeSmokeTest` remains available: it creates and releases a five-second assertion, constructs and closes overlay windows without presenting them, and reads limited system metadata. It never calls the normal Start methods or ejects a volume.

Verification: Swift frontend syntax parsing and `git diff --check` passed. These new guard paths have not yet been exercised in a successful macOS UI run. No real application was opened/terminated, no real volume was ejected, and no normal power/overlay session was started during this audit.

### Closed output pipe while a cooperative child is finishing

Before this fix, `MoPanelGuardian` watched its stdout pipe for `POLLOUT` but did not handle a destination that returned only `POLLERR`, `POLLHUP`, or `POLLNVAL`. If the GUI disappeared while that pipe was full, the helper could repeatedly poll an unusable descriptor. Its bounded output buffer could also fill and stop draining the PTY, preventing a cooperative child from reaching its safe completion boundary.

`Sources/MoPanelGuardian/main.c:210,229,237,276,282` now marks that destination unavailable, removes it from subsequent polls, requests the existing cancellation path, and continues reading/discarding terminal output. The PTY is not forcibly closed while the transaction is running. The existing child/descendant ownership checks, ordinary cancellation grace, and cooperative cancellation policy are unchanged.

The new `test_closed_full_output_pipe_drains_cooperative_child` fills a disposable pipe before launch, starts a harmless PTY fixture that handles SIGINT, produces 4 MiB of synthetic output, and writes a temporary completion marker after 2.3 seconds. The parent closes its output reader and control writer. A fixture-owned five-second alarm bounds the broken-case lifetime. It invokes no Mole, Homebrew, launchctl, user app, or personal-file operation.

| Execution | Result | Elapsed | CPU from `wait4` | Safe completion marker |
|---|---|---:|---:|---|
| Before fix | Regression failed; fixture alarm ended the blocked operation | 4.997 s | 5.044 s | Missing |
| After fix, focused run | Passed; cancellation exit 130 | 2.346 s | 0.085 s | Present |
| After fix, full host-namespace suite | Passed; cancellation exit 130 | 2.336 s | 0.068 s | Present |

`cc -std=c11 -Wall -Wextra -Werror -O2` passed. The full Linux host-namespace guardian suite passed **17/17 with zero skips**, including detached-descendant cleanup, ordinary timeout, cooperative safe boundary, controlling PTY, resize, password echo suppression, special argv and large-output completeness. The earlier sandbox run had 16 passes and one explicitly recorded PID-namespace skip; it is not counted as a complete pass.

Evidence:

- `GUARDIAN_CLOSED_OUTPUT_BEFORE.txt`
- `GUARDIAN_CLOSED_OUTPUT_AFTER.txt`
- `GUARDIAN_CLOSED_OUTPUT_SUITE.txt` — initial sandbox run, one skip.
- `GUARDIAN_CLOSED_OUTPUT_FULL.txt` — host-namespace run, 17 passes, no skips.

The new guardian regression still requires the next macOS CI run. Linux results do not validate Darwin `libproc` or AppKit behavior.

## Native controls reviewed

| Module / controls | Actual behavior and relevant guard | Source location |
|---|---|---|
| Startup Read / Refresh, Recheck | Bounded plist inventory and typed, read-only launchctl requests; busy/external-operation/test-launch checks; cancellation and per-command timeout. | `StartupView.swift:28,99`; `StartupController.swift:66,70,94,137,293` |
| Startup Enable / Disable review and confirmation | Fresh identity/content/ownership checks, unique label proof, fresh launchctl state, explicit sheet, typed commands, read-back. Partial completion is disclosed without automatic retry or rollback. | `StartupController.swift:155,160,179`; `StartupView.swift:116` |
| Startup Finder / System Settings | Native handoffs, blocked by test-launch guard. Opening settings is explicitly not reported as a completed setting change. | `StartupController.swift:237,241` |
| Startup Stop / Back | Cancels active managed child and bounded inventory, clears pending plan; page disappearance also cancels. | `StartupController.swift:87`; `StartupView.swift:34,58,132` |
| App Updates check / local inventory / choose Homebrew | Explicit actions only; `actionsAllowed`, busy/shutdown and cross-module gates. Local inventory is bounded and cancellable. Homebrew may fetch missing public metadata, as disclosed. | `AppUpdatesController.swift:74,89,106,118,253`; `AppUpdatesView.swift:97,98,168` |
| App Updates preview / confirm | Typed single-cask dry run; matching installed receipt and current metadata; five-minute consent lifetime; current executable fingerprint; app must be closed; confirmed PTY upgrade, then version read-back. | `AppUpdatesController.swift:131,157,314,348,378,394` |
| Update Homebrew / indexes | Separate confirmation explicitly describes `brew update` and its Homebrew/tap effects; test mode and operation guards apply. | `AppUpdatesView.swift:70`; `AppUpdatesController.swift:196` |
| App Updates Stop / operation Close / page exit | Read cancellation is immediate; mutation cancellation is cooperative. Operation sheet cannot close while its managed session or post-update verification is active. Page exit cancels read work. | `AppUpdatesController.swift:211,215,219`; `AppUpdatesView.swift:61,255` |
| App Updates Finder / App / App Store | Native handoffs; test mode blocks every external launch/reveal. App opening rechecks bundle identity. | `AppUpdatesController.swift:223,231,239` |
| Keep Awake Start / Stop | Native IOPM assertion, selected deadline, power-change observation, low-battery policy, sleep and quit release. No launch item or pmset change. New test guards described above. | `SystemToolsController.swift:99,123,137,142,193`; `SystemToolsView.swift:48` |
| Clean Screen Start / Finish / Esc | Native windows, explicit start, five-minute timer, application deactivation/screen change/sleep exits, no global input interception. New test guard described above. | `SystemToolsController.swift:228,256,269`; `SystemToolsView.swift:81` |
| External volumes Refresh / Eject | Reads mounted-volume metadata only; explicit named-volume confirmation; test mode and external-operation guard; fresh volume identity and protection check; normal NSWorkspace eject, no force fallback. | `SystemToolsView.swift:32,104,122`; `SystemToolsController.swift:292,304` |
| Doctor Generate / Copy / Save | Read-only metadata report; copy changes the clipboard only on explicit click; save uses the native save panel. These report controls are outside the automated AX allowlist. | `SystemToolsController.swift:341,391,397`; `SystemToolsView.swift:133` |
| Menu bar Dashboard / Tools / Pause / Resume / Quit | Real navigation, foreground-window request, shared model collector and normal termination request. Menu bar is opt-in and off by default/test initialization. | `MenuBarPanel.swift:21,24,29,31,37`; `AppModel.swift:17,93,246,303` |
| Process search / sort / pin | Local presentation of Mole-provided samples only; pinning creates no collector. | `ProcessInspectorView.swift:26,40,56` |
| Process Inspect / Quit / Force Quit / Back | Exact regular-app identity, recent matching Mole sample, protected-app denial and test-mode denial at review and confirmation. Native NSRunningApplication object retained; no arbitrary PID kill. Confirmation discloses possible unsaved-data loss. | `ProcessInspectorView.swift:112,133,151`; `NativeControlPolicy.swift:32` |

Every reviewed button is connected to a real action, a local UI state change, or an explicitly named native handoff. This source audit does not prove every button's physical accessibility action has executed successfully. The test harness deliberately covers only its named own-process fixture flows; all other UI/hardware behavior remains separately scoped.

## Lifetime findings and limits

- `AppModel.startMonitoring` owns one `watchSession` and will not replace it until it exits. Restart requests are coalesced; `stopMonitoring` cancels that session and clears restart intent (`AppModel.swift:246,297`).
- Native busy callbacks synchronously prevent incompatible operations. The root state-change notification updates monitoring demand without creating another collector (`MoPanelApp.swift:16,46,79`).
- The application delegate requests termination when the last window closes and calls all native/controller shutdown hooks on termination (`MoPanelApp.swift:98,99`). `AppModel.shutdown` cancels scan, watch and operation sessions; the control-pipe lifeline covers an unexpected parent exit (`AppModel.swift:441`; `ManagedProcess.swift:105,248`).
- Startup stops read/mutation requests on page exit and quit. App Updates cancels read-only work on page exit and requests cooperative cancellation on quit. Keep Awake and Clean Screen release their assertions, timers, observers and windows on the explicit quit hook.
- **Cooperative work can outlive the GUI while the official child reaches its safe boundary.** That behavior is intentional for an app replacement/rollback; it is not a promise that every helper exits immediately. A child that never completes cooperative cancellation can still remain alive. The guardian fix prevents its vanished output reader from introducing a separate backpressure deadlock or busy loop; it does not invent a safe force-kill point inside another program's transaction.
- Closing the main window with optional menu-bar/overlay UI present has not yet received a successful end-to-end macOS UI acceptance run. The source termination hooks are present; runtime behavior must be described as pending while startup smoke fails.

## Startup crash comparison — evidence boundary

Baseline with an earlier 11/12 smoke result: `9a7cf7d72f7a8005da078767187ea7a5593c1b74`.

The current crash is recorded after `SmokeHarness` prints `entered`, before its initial 300 ms yield reaches `detect.begin`. Comparing the baseline to the current source leaves these newly reachable initial-render paths: the additional MenuBarExtra scene value, three additional StateObjects/environment objects (including AppUpdates' termination notification observer), root `onAppear` native-operation bindings and added change observers, and the sidebar's conditional foreground style. The unselected new pages' action methods, Charts, PTY and native AX automation have not run at this point.

At that initial source-review stage, no definite dangling capture or invalid native API invocation was established. The earlier onReceive-to-onChange change did **not** resolve the crash.

### Subsequent LLDB evidence and narrow lifecycle correction

Run `40076975513` supplied a real ARM64 stack from the isolated debug copy. Its log contains 5,139 instances of SwiftUI's publication-during-view-update warning. The main-thread trace repeats `AppGraph.graphDidChange`, `GraphHost.flushTransactions`, `AppGraph.sceneList` and `AppKitWindowController.updateRootHost` until the stack is exhausted. The top app frame happens to be construction of the Settings keyboard shortcut; that position does not show that the shortcut itself is defective. The distributed release bundle and helper hashes remained unchanged by the separate diagnostic.

The following narrow changes are now staged for the next macOS verification:

1. Remove `ContentView.onDisappear`'s unconditional assignment of `model.windowActive = false`. Replacing a SwiftUI root host can make its old view disappear even while the actual window remains open. Publishing app-wide state from that callback both misrepresented window activity and could feed the graph update back into itself. Activity remains owned by scene phase, with last-window and quit cleanup owned by the existing application delegate.
2. Compare the requested scene activity with `model.windowActive` **before** assigning. A same-value `@Published` assignment still publishes; a guard only inside `didSet` would be too late.
3. Give MenuBarExtra an explicit `Binding` that compares the incoming insertion value with `model.menuBarEnabled` **before** assigning. A framework write-back of its current value no longer republishes the app model. Actual menu-bar preference changes retain their normal behavior.

These changes apply to the product path; no new fixture-only skip, removed shortcut, disabled feature, relaxed AX requirement or deadline change was introduced. The existing scene-phase test guard was not broadened. Swift frontend syntax parsing and diff whitespace checks passed, but neither is a macOS runtime test.

The recursion is established by the trace. The final crash stack does not capture the originating property setter, so the relative contribution of the incorrect disappearance callback and same-value scene binding remains an inference until the next run. **Release smoke remains failed until the real app genuinely passes.**
