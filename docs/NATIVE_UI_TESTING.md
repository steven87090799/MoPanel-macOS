# Own-process native UI action checks

`NativeUITestHarness` adds action checks to the existing window/route/adapter smoke test. It is an in-process AppKit accessibility test of selected real controls. It does not simulate a physical mouse, validate every control, operate another app, grant Accessibility permission or alter TCC.

## Public API and ownership boundary

The harness starts with one explicitly supplied `NSWindow` and its content view. It traverses the public accessibility children, navigation-order children, visible children and `NSAccessibility.unignoredChildren(from:)`, with `NSView.subviews` for ignored hosting containers. For modal actions it only traverses that window's currently attached sheet. It finds a stable SwiftUI `accessibilityIdentifier`, requires a unique appropriate accessibility role, a known enabled state, a nonzero visible frame and proof of the exact owning window, then invokes `accessibilityPerformPress()`.

AppKit permits role-specific accessibility protocols without requiring the entire `NSAccessibilityProtocol`. The adapter therefore prefers that complete protocol when present but also accepts an object's documented public selectors. For selector-only objects it verifies the Objective-C method's argument count, receiver/selector/argument encodings and result encoding before using a correctly typed implementation pointer. Object results, BOOL (`B` or `c`) results and NSRect results use separate ABI-correct calls. It never interprets a BOOL or struct as `Unmanaged<AnyObject>`, uses no private selector, and never invokes a selector with an unknown signature. The public legacy attribute getter is a compatibility read path only: a fixed attribute must first appear in `accessibilityAttributeNames`, avoiding unsupported-attribute exceptions. An actual action still requires the Boolean-returning public `accessibilityPerformPress()`; there is no action fallback to a model method or legacy unverified action.

Window ownership is normally the returned NSWindow or an NSView's real window. A sheet element that reports its sheet parent still has to prove that its bounded public accessibility-parent chain reaches the actual sheet or an NSView in that sheet. A parent window alone is insufficient. Unknown frame, role, enabled state or ownership is rejected.

Apple documents the press result as indicating that an action was triggered, **not that the action succeeded**. Every press is followed by a separate bounded postcondition: a new operation activity UUID and exact command, decoded fixture data, modal state, or subprocess cancellation/result. A missing element, ambiguous identifier, unsupported accessibility tree, rejected press, failed outcome or timeout fails the test. It never calls the model action directly as a substitute for a failed UI interaction.

The harness does not use `AXUIElement`, `CGEvent`, desktop screenshots, global event injection, permission requests, private selectors, Objective-C method swizzling or undocumented accessibility switches. Its tree traversal has depth, node and queue limits. Bounded diagnostics expose only known control identifiers, class/type names, fixed role/ownership/frame/ABI flags and counts; they do not dump labels, values, paths, terminal text or arbitrary accessibility identifiers. Children that are not supported object types are counted and reported by type, not silently treated as controls.

## Fixture enforcement

Every lookup/press and postcondition wait revalidates:

- Exact launch arguments `--smoke-test`, without other flags.
- `AppModel` fixture/test state and no read-only-real-benchmark configuration.
- A packaged `.app`, with the `AppResources` mock script resolving beneath its `Contents/Resources`.
- Exact canonical equality between that resource and both selected/resolved CLI paths, installation source `.fixture`, and the unchanged CLI fingerprint.
- Continued membership of the explicit test window in the current app's windows.

Action-specific guards additionally require the expected page and safe fixture command. Only the allowlisted controls below can be pressed. Homebrew installation/upgrades, real app removal, Finder/System Settings, native hardware actions, eject, Startup and configuration editing are excluded from this action runner.

Two exact branches of the bundled mock have a three-second delay: `analyze --json` without a path, and `clean --dry-run`. Both trap interrupt/termination/hangup and produce no partial JSON/output before the delay. The test needs those short delays to reach the actual Stop buttons. Explicit-path analysis and the large fixture benchmark path keep their prior immediate response. The mock never invokes an installed Mole or reads/deletes a cleanup target.

## Selected control coverage

| Real control | Identifier | Required evidence |
|---|---|---|
| Dashboard Snapshot | `mopanel.dashboard.snapshot` | New `mo status --json` activity and `fixture-only` status |
| Uninstall Scan / Refresh | `mopanel.uninstall.scan` | New list command and three fixture app records |
| Analyze Scan Overview | `mopanel.analyze.overview` | New JSON command; partial and unavailable sizes preserved |
| Analyze Rescan | `mopanel.analyze.rescan` | New command for the currently displayed fixture path |
| Analyze Parent | `mopanel.analyze.parent` | New command for the parent of that path |
| Global Stop Scan | `mopanel.scan.stop` | Busy scan settles, cancelled error appears, no incomplete JSON accepted |
| Dismiss error | `mopanel.error.dismiss` | The displayed error state clears |
| Clean Scan and Preview | `mopanel.maintenance.clean.preview` | Dry-run operation sheet/session starts without destructive confirmation |
| Operation Stop | `mopanel.operation.stop` | Owned fixture child exits with the cancellation result |
| Operation Close | `mopanel.operation.close` | Finished operation sheet closes and main page returns |
| Clean Review and Start | `mopanel.maintenance.clean.review` | Confirmation appears; no process starts beforehand |
| Confirmation Cancel | `mopanel.confirmation.cancel` | Sheet closes; activity UUID remains unchanged |
| Confirmation acknowledgement | `mopanel.confirmation.acknowledge` | Actual checkbox/switch press enables Continue, which was initially disabled |
| Confirmation Continue | `mopanel.confirmation.continue` | Fresh exact `mo clean` activity, successful child exit and unchanged bundled mock resource/fingerprint |

The sequence makes 17 press attempts when successful because Overview, Review and Close are reused. Route selection and initial monitoring teardown use direct model state as **test setup**. This runner therefore does not prove sidebar selection, keyboard shortcuts, pointer hit testing, VoiceOver speech/navigation, visual layout correctness, native file pickers or real CLI cleanup. The analyzer fixture is synthetic and reuses a static response; Parent/Rescan assertions verify command binding, not real directory traversal.

The clean operation uses a PTY. Production interactive output deliberately remains unretained, including during tests; the harness checks that the result has empty retained stdout/stderr. It does not enable terminal logging or claim to inspect the terminal's output marker. The separate script-level fixture test verifies the mock's no-change marker; UI execution evidence is based on the exact bundled executable/fingerprint, new command activity and successful process result.

## Integration and evidence

Call after the existing adapter/watch/route smoke checks and before the final own-window screenshot:

```swift
let report = await NativeUITestHarness.run(model: model, window: mainWindow)
```

The caller must pass the actual MoPanel content window, not select a different application by title. `NativeUIReport` is Codable and records overall `passed`, per-outcome `checks`, per-press `actions`, known identifiers observed, tree node count, safety/scope flags and errors. On failure, it requests cancellation of owned fixture work as teardown; that direct cancellation is explicitly recorded and never counted as a successful Stop-button test.

Run `40077546222` established that the real app launches and the other 19 smoke checks pass, including the live watch and safe native API probes. Its Screenshot shows the Snapshot button, but the original protocol-only traversal observed 169 nodes, no control identifiers and zero accepted actions. This is a failed native-button test, not a missing visible button and not a successful automation run. The public-selector/window-root changes described above address that traversal assumption and add diagnostics; their successful macOS compilation and actual press outcomes remain pending the next CI run. No control action, fixture guard, postcondition or watchdog has been weakened.

The runner has a 20-second whole-sequence deadline, two-second element lookup deadlines and three-second normal outcome deadlines (five seconds for the intentionally delayed overview). The usual successful path contains one completed three-second delay. These are failure bounds, not retries that re-execute an action. Keep the outer smoke watchdog; change it only based on measured CI timing.

Linux Swift syntax parsing and `bash -n` pass. `docs/NATIVE_UI_FIXTURE_TEST_OUTPUT.txt` records actual mock script JSON/no-change outputs and process-group interrupt tests. Those checks are **not macOS compilation or UI interaction evidence**. The macOS CI smoke report is the authority for whether the public accessibility bridge actually exposes and operates these controls. Until a run passes, the correct status is **implemented; native UI action verification pending**.

If SwiftUI does not expose a usable own-process accessibility tree on the tested SDK, record the failure and keep it unresolved. A separate Xcode XCTest UI runner launching only this fixture-mode app is the appropriate next test mechanism; do not silently replace these checks with direct model calls or bypass system permissions.

## Apple references

Inspected 2026-10-24:

- [NSAccessibilityProtocol](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol)
- [NSAccessibilityElementProtocol](https://developer.apple.com/documentation/appkit/nsaccessibilityelementprotocol)
- [NSAccessibilityButton](https://developer.apple.com/documentation/appkit/nsaccessibilitybutton)
- [unignoredChildren(from:)](https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/unignoredchildren(from:))
- [Legacy NSAccessibility interface](https://developer.apple.com/documentation/appkit/nsaccessibility)
- [accessibilityChildren()](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol/accessibilitychildren())
- [accessibilityIdentifier()](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol/accessibilityidentifier())
- [accessibilityWindow()](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol/accessibilitywindow())
- [accessibilityPerformPress()](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol/accessibilityperformpress())
- [SwiftUI accessibility fundamentals](https://developer.apple.com/documentation/swiftui/accessibility-fundamentals)
