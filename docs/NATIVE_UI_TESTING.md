# Own-process native UI action checks

`NativeUITestHarness` adds action checks to the existing window/route/adapter smoke test. It is an in-process AppKit accessibility test of selected real controls. It does not simulate a physical mouse, validate every control, operate another app, grant Accessibility permission or alter TCC.

## Public API and ownership boundary

The harness starts with one explicitly supplied `NSWindow` and its content view. It traverses the public accessibility children, navigation-order children, visible children and `NSAccessibility.unignoredChildren(from:)`, with `NSView.subviews` for ignored hosting containers. For modal actions it only traverses that window's currently attached sheet. It finds a stable `accessibilityIdentifier`, requires a unique appropriate accessibility role, a known enabled state, a nonzero visible frame and proof of the exact owning window, then selects and invokes exactly one supported public accessibility press interface.

AppKit permits role-specific accessibility protocols without requiring the entire `NSAccessibilityProtocol`. The adapter therefore prefers that complete protocol when present but also accepts an object's documented public selectors. For selector-only objects it verifies the Objective-C method's argument count, receiver/selector/argument encodings and result encoding before using a correctly typed implementation pointer. Object results, BOOL (`B` or `c`) results, NSRect results and void actions use separate ABI-correct calls. It never interprets a BOOL or struct as `Unmanaged<AnyObject>`, uses no private selector, and never invokes a selector with an unknown signature. A public legacy attribute getter first requires the fixed attribute to appear in `accessibilityAttributeNames`, avoiding unsupported-attribute exceptions.

For the actual matched `NSButtonCell`, an explicitly advertised `AXPress` in the bounded public `accessibilityActionNames()` list, together with a verified `void accessibilityPerformAction:(object)` signature, selects that documented legacy action. This is AppKit's real cell action, not a hidden control or application-model callback. This deprecated API is supported for compatibility, not assumed equivalent to a modern Bool-returning method. Other elements, or cells without that advertised capability, use `accessibilityPerformPress()` only when its public selector is supported and permitted. Interface selection happens before invocation. There is exactly one action API call; a false modern result is never followed by a retry through another interface.

Window ownership is normally the returned NSWindow or an NSView's real window. A sheet element that reports its sheet parent still has to prove that its bounded public accessibility-parent chain reaches the actual sheet or an NSView in that sheet. A parent window alone is insufficient. Unknown frame, role, enabled state or ownership is rejected.

Apple documents the modern press result as indicating that an action was triggered, **not that the action succeeded**. The legacy action returns void and supplies no acceptance Bool. Every dispatch is followed by a separate bounded postcondition: a new operation activity UUID and exact command, decoded fixture data, modal state, or subprocess cancellation/result. A missing element, ambiguous identifier, unsupported accessibility tree, rejected modern press, failed outcome or timeout fails the test. It never calls the model action directly as a substitute for a failed UI interaction.

The harness does not use `AXUIElement`, `CGEvent`, desktop screenshots, global event injection, permission requests, private selectors, Objective-C method swizzling or undocumented accessibility switches. Its tree traversal has depth, node and queue limits. Bounded diagnostics expose only known control identifiers, class/type names, fixed role/ownership/frame/ABI flags and counts; they do not dump labels, values, paths, terminal text or arbitrary accessibility identifiers. Children that are not supported object types are counted and reported by type, not silently treated as controls.

### Public SwiftUI accessibility environment

For the exact `--smoke-test` launch only, the real `ContentView` uses the public `.environment(\.accessibilityEnabled, true)` value. Apple documents this as a writable SwiftUI environment property, available on macOS 10.15 and later, that indicates an assistive technology is enabled. Normal launches receive their inherited system environment without an override. This does not turn on VoiceOver, change system preferences, grant permissions or set a private accessibility attribute.

A noninteractive, zero-size `NSViewRepresentable` reader records **`context.environment.accessibilityEnabled` as actually delivered by SwiftUI**. It has no action and is hidden from accessibility; it is only an environment probe, never an alternative button. Before any action, the runner must find exactly one such reader in its supplied content window and read `true`. Every subsequent fixture-context check revalidates that observation. `publicAccessibilityEnvironmentEnabled` and the `public_accessibility_environment_read_back` check report this actual observed value, not a static requested flag. The reader changes no observable model or published state during a view update.

These checks exercise an assistive-technology-enabled SwiftUI environment. They do not establish complete VoiceOver compatibility, and Apple's property documentation does not promise that setting it materializes every own-process accessibility node. The next Mac run must demonstrate the real identifiers, presses and outcomes; a successful environment read alone does not pass native action verification.

### Visible native product controls

`NativeControls.swift` provides `NativeActionButton` and `NativeAcknowledgementToggle` using `NSViewRepresentable` and real AppKit `NSButton` controls. The selected Snapshot, inventory, analysis, preview/review, cancellation, close and confirmation controls use these wrappers **during normal production launches and during tests**. They are the visible, focusable controls the user operates; there is no hidden proxy, test-only duplicate, lookup-by-label/coordinate or direct action fallback. Maintenance uses the same controls for all its official commands, not just the tested Clean page. Cards, navigation and the surrounding layout remain SwiftUI.

Each update supplies the current action or Binding to its coordinator, applies SwiftUI's inherited `isEnabled` and `controlSize`, and sets the identifier and accessibility label on the actual NSButton and its actual cell. AppKit can expose the cell as the actionable accessibility element while the control view acts as an ignored container. This identity synchronization does not force either object's role, element flag, enabled state, window, frame or press behavior. The confirmation acknowledgement is a standard native checkbox. Its Binding remains the same state that gates Continue; `REMOVE` text requirements remain in the original view. Buttons retain their original operation closures and scan/operation guards. Stop uses AppKit's public destructive-action property. Cancel and Close use the original unmodified Escape equivalent; no new Return shortcut was added to the destructive confirmation. The shared wrapper supports a Return equivalent only when explicitly requested by a future call site.

Sizing uses intrinsic or proposed sizes without directly changing the representable view's frame or bounds. Checkbox labels wrap to the offered width. Teal/orange emphasis and SF Symbols are applied through native properties. Dismantling clears the target, action and retained callback/Binding. These implementation properties still require real Mac layout and interaction verification; Linux parsing cannot establish their behavior.

## Fixture enforcement

Every lookup/press and postcondition wait revalidates:

- Exact launch arguments `--smoke-test`, without other flags.
- `AppModel` fixture/test state and no read-only-real-benchmark configuration.
- A packaged `.app`, with the `AppResources` mock script resolving beneath its `Contents/Resources`.
- Exact canonical equality between that resource and both selected/resolved CLI paths, installation source `.fixture`, and the unchanged CLI fingerprint.
- Continued membership of the explicit test window in the current app's windows and read-back of its real root's public accessibility environment.

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

The sequence makes 17 press attempts when successful because Overview, Review and Close are reused. Each action's `postconditionVerified` remains false until its existing outcome checks complete; the second Overview must enter its real busy state, and the second Review must open its real confirmation. Overall success additionally requires exactly 17 single-interface dispatch records and all 17 verified postconditions. Route selection and initial monitoring teardown use direct model state as **test setup**. This runner therefore does not prove sidebar selection, keyboard shortcuts, pointer hit testing, VoiceOver speech/navigation, visual layout correctness, native file pickers or real CLI cleanup. The analyzer fixture is synthetic and reuses a static response; Parent/Rescan assertions verify command binding, not real directory traversal.

The clean operation uses a PTY. Production interactive output deliberately remains unretained, including during tests; the harness checks that the result has empty retained stdout/stderr. It does not enable terminal logging or claim to inspect the terminal's output marker. The separate script-level fixture test verifies the mock's no-change marker; UI execution evidence is based on the exact bundled executable/fingerprint, new command activity and successful process result.

## Integration and evidence

Call after the existing adapter/watch/route smoke checks and before the final own-window screenshot:

```swift
let report = await NativeUITestHarness.run(model: model, window: mainWindow)
```

The caller must pass the actual MoPanel content window, not select a different application by title. `NativeUIReport` is Codable and records overall `passed`, per-outcome `checks`, per-press `actions`, known identifiers observed, tree node count, the observed public accessibility environment, safety/scope flags and errors. On failure, it requests cancellation of owned fixture work as teardown; that direct cancellation is explicitly recorded and never counted as a successful Stop-button test.

Per-action evidence distinguishes `dispatchMethod`, `modernSelectorSupported`, `modernSelectorAllowed`, `modernMethodInvoked`, `legacyPressAdvertised`, `legacyVoidDispatched` and `postconditionVerified`. `pressAccepted` is optional: it contains only the actual modern method's Bool result, and is absent when that method was not invoked. A returned legacy void dispatch is not recorded as a true Bool. Successful public legacy dispatch still requires the corresponding real business postcondition before the action can pass.

Run `40077546222` established that the real app launches and the other 19 smoke checks pass, including the live watch and safe native API probes. Its screenshot shows the Snapshot button, but the original protocol-only traversal observed 169 nodes, no control identifiers and zero accepted actions.

Run `40078440635` successfully compiled and signed the public-selector/window-root adapter on the real Mac runner. The formal app exited normally with the same 19/20 smoke result in 10.129 seconds. Traversal found 257 nodes (173 full-protocol and 84 selector-only), zero unsupported child types, no allowlisted control identifiers and zero actions. Selector-only AppKit rows and proxy cells returned valid roles and window/frame information, so the adapter was not simply returning nil for all getters. The visible SwiftUI controls still had no corresponding virtual button nodes in the collected hierarchy. This is evidence of a missing semantic tree in this test context, not proof that the on-screen buttons are absent.

Run `40079692503` compiled and signed the public environment experiment on the real Mac runner. Both `publicAccessibilityEnvironmentEnabled` and its read-back check were true. The formal app exited normally with 19/20 checks in 9.776 seconds. The tree grew to 313 nodes (207 full-protocol and 106 selector-only) and included `SwiftUI.AccessibilityNode` objects, including two button-role nodes with supported getter signatures and valid enabled/window/frame information. None exposed an allowlisted identifier, so zero actions occurred and Snapshot lookup still failed. Thus the public environment affected the tree but did not complete control discovery; it must not be reported as a successful UI action run.

Run `40080195228` compiled and signed the visible native product controls on the real Mac runner. Its 143 Swift tests passed. The formal app exited normally with 19/20 smoke checks in 10.873 seconds, observing the exact Snapshot identifier for the first time, but still accepted no actions. The tree contained 316 nodes (210 full-protocol and 106 selector-only). The bounded trace showed an exposed `NSButtonCell` with button role, enabled status, own-window membership and a visible frame, but no identifier; the later identifier-bearing node fell outside the first-256 general-node diagnostic allowance. This supports control/cell identity separation as a candidate cause, not a proven successful interaction.

The subsequent narrow correction synchronized the same public identifier and accessibility label onto the real product button cell and reserved up to 128 deduplicated diagnostics for allowlisted identifiers, independently of the 256 general-node limit. These diagnostics record only fixed IDs and class/role/state flags, never labels or values.

Run `40081012904` compiled and signed that cell-identity correction and passed 171 Swift tests, including the new isolated Git tests. The formal app exited normally with 19/20 smoke checks in 8.322 seconds. Snapshot passed the exact identifier, uniqueness, role, element, enabled, owning-window and visible-frame requirements. The native cell was the eligible `AXButton`; its NSButton wrapper was an ignored `AXUnknown` element. The old press wrapper returned false, recording one rejected attempt and no verified outcome. That wrapper combined a modern selector-permission check with the modern method call, so the old evidence did not distinguish permission denial from an actual false method result.

The current capability-selection correction records that distinction and supports the actual cell's explicitly advertised public legacy AXPress as described above. It does not invoke both action interfaces to probe which works. Its Mac compilation and 17 actual dispatch/postcondition results remain pending. All existing context, identifier, uniqueness, ownership/frame/role/enable, business-outcome and watchdog checks remain; per-action verification and an exact 17-dispatch requirement were added. No private accessibility activation switch or guessed selector was introduced.

The runner has a 20-second whole-sequence deadline, two-second element lookup deadlines and three-second normal outcome deadlines (five seconds for the intentionally delayed overview). The usual successful path contains one completed three-second delay. These are failure bounds, not retries that re-execute an action. Keep the outer smoke watchdog; change it only based on measured CI timing.

Linux Swift syntax parsing and `bash -n` pass. `docs/NATIVE_UI_FIXTURE_TEST_OUTPUT.txt` records actual mock script JSON/no-change outputs and process-group interrupt tests. Those checks are **not macOS compilation or UI interaction evidence**. The macOS CI smoke report is the authority for whether the public accessibility bridge actually exposes and operates these controls. Until a run passes, the correct status is **implemented; native UI action verification pending**.

### Dashboard and update workflow follow-up (2026-10-25)

The local Apple Silicon runner now verifies 29 real accessibility presses, including opening layout editing, moving GPU before CPU, resetting the layout, and checking the same stable release twice. It also checks that Snapshot, app inventory, disk analysis and cleanup scan actions occupy the upper-right portion of the window. Release-check fixtures use a bundled release document and never access GitHub; loading, completion, repeated checks and version comparison have separate coverage.

Manual computer-use checks additionally dragged a summary card, an entire dashboard section and an individual trend chart, then verified the changed order in the real accessibility tree and restored defaults. Dashboard movement uses a local SwiftUI drag gesture with geometry captured only while editing; section and card targets are separate. Keyboard-accessible move buttons use the same persisted layout model. These checks supplement the accessibility harness; physical dragging is not claimed as part of its 29 presses.

Startup metadata now has login, background-app and service categories. The background-task adapter reads Apple's `sfltool dumpbtm` report, with bounded output, cancellation and current-user/system filtering. Adapter tests do not establish live completeness. If the system read is unavailable, the UI explicitly distinguishes the service files that were read from the login/background inventory that is missing. Imported reports retain their source timestamp; registered states do not bypass the existing fresh-state checks before service changes. Local inventory reports remain outside distributed reports and source control.

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
- [accessibilityActionNames()](https://developer.apple.com/documentation/objectivec/nsobject-swift.class/accessibilityactionnames()) — documented legacy capability advertisement; deprecated.
- [accessibilityPerformAction(_:)](https://developer.apple.com/documentation/objectivec/nsobject-swift.class/accessibilityperformaction(_:)) — documented legacy void action; deprecated.
- [Supporting Actions](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Accessibility/cocoaAXSupportingActions/cocoaAXSupportActions.html) — Apple's archived explanation of the legacy action contract.
- [SwiftUI accessibility fundamentals](https://developer.apple.com/documentation/swiftui/accessibility-fundamentals)
- [EnvironmentValues.accessibilityEnabled](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityenabled) — Apple's DocC declaration was read directly and confirms `var accessibilityEnabled: Bool { get set }`; the declaration does not guarantee own-process tree materialization.
- [NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable)
- [NSViewRepresentableContext.environment](https://developer.apple.com/documentation/swiftui/nsviewrepresentablecontext/environment)
- [NSButton keyEquivalent](https://developer.apple.com/documentation/appkit/nsbutton/keyequivalent)
- [NSButton hasDestructiveAction](https://developer.apple.com/documentation/appkit/nsbutton/hasdestructiveaction)
- [NSButton.ButtonType.switch](https://developer.apple.com/documentation/appkit/nsbutton/buttontype/switch)
- [NSButtonCell](https://developer.apple.com/documentation/appkit/nsbuttoncell)
- [setAccessibilityIdentifier(_:)](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol/setaccessibilityidentifier(_:))
