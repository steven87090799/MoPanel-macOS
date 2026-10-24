// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import ObjectiveC
import SwiftUI
import MoPanelCore

struct NativeUIActionEvidence: Codable {
    let identifier: String
    let role: String
    let enabledBeforePress: Bool
    /// Only the modern API returns Bool. Nil is intentional for a legacy void
    /// dispatch or when the modern method was never invoked.
    let pressAccepted: Bool?
    let ownedWindow: Bool
    let dispatchMethod: String
    let modernSelectorSupported: Bool
    let modernSelectorAllowed: Bool?
    let modernMethodInvoked: Bool
    let legacyPressAdvertised: Bool
    let legacyVoidDispatched: Bool
    var postconditionVerified: Bool

    var hasSingleSuccessfulDispatch: Bool {
        if dispatchMethod == "legacyAXPress" {
            return legacyPressAdvertised && legacyVoidDispatched && !modernMethodInvoked && pressAccepted == nil
        }
        return dispatchMethod == "modernPerformPress" && modernSelectorSupported && modernSelectorAllowed == true &&
            modernMethodInvoked && pressAccepted == true && !legacyVoidDispatched
    }
}

private struct NativeUIPressDispatch {
    let method: String
    let modernSupported: Bool
    let modernAllowed: Bool?
    let modernInvoked: Bool
    let modernResult: Bool?
    let legacyAdvertised: Bool
    let legacyDispatched: Bool

    var dispatchedSuccessfully: Bool { legacyDispatched || (modernInvoked && modernResult == true) }
}

struct NativeUIReport: Codable {
    let passed: Bool
    let mechanism: String
    let fixtureOnly: Bool
    let ownProcessOnly: Bool
    let physicalInputInjected: Bool
    let accessibilityPermissionRequested: Bool
    let routeSetupUsesModelState: Bool
    let directActionFallbackUsed: Bool
    let cleanupRequestedAfterFailure: Bool
    let publicAccessibilityEnvironmentEnabled: Bool?
    let checks: [String: Bool]
    let actions: [NativeUIActionEvidence]
    let maximumTreeNodesObserved: Int
    let maximumProtocolNodesObserved: Int
    let maximumSelectorOnlyNodesObserved: Int
    let observedElementClasses: [String]
    let maximumUnsupportedChildrenObserved: Int
    let observedUnsupportedChildTypes: [String]
    let observedControlIdentifiers: [String]
    let errors: [String]
}

/// Uses public, in-process AppKit accessibility interfaces. This is not an
/// external AXUIElement client, mouse/keyboard injection or a TCC workaround.
/// An accepted accessibility press is always checked against its real effect.
@MainActor enum NativeUITestHarness {
    static func run(model: AppModel, window: NSWindow) async -> NativeUIReport {
        let runner = OwnWindowRunner(model: model, window: window)
        return await runner.run()
    }
}

/// Enable SwiftUI's documented assistive-technology environment only for the
/// exact fixture smoke launch. Normal launches inherit the system environment.
/// The reader below observes the actual environment supplied to the real root;
/// it is not an actionable accessibility element or a substitute control.
struct NativeUISmokeAccessibilityEnvironment: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if Array(ProcessInfo.processInfo.arguments.dropFirst()) == ["--smoke-test"] {
            content
                .background(alignment: .topLeading) {
                    NativeUIAccessibilityEnvironmentReader()
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .environment(\.accessibilityEnabled, true)
        } else {
            content
        }
    }
}

@MainActor private struct NativeUIAccessibilityEnvironmentReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NativeUIAccessibilityEnvironmentView {
        let view = NativeUIAccessibilityEnvironmentView(frame: .zero)
        view.observedEnabled = context.environment.accessibilityEnabled
        return view
    }
    func updateNSView(_ view: NativeUIAccessibilityEnvironmentView, context: Context) {
        view.observedEnabled = context.environment.accessibilityEnabled
    }
}

@MainActor private final class NativeUIAccessibilityEnvironmentView: NSView {
    fileprivate var observedEnabled: Bool?
    override func isAccessibilityElement() -> Bool { false }
}

private enum NativeUIControl: String, CaseIterable {
    case snapshot = "mopanel.dashboard.snapshot"
    case appScan = "mopanel.uninstall.scan"
    case overview = "mopanel.analyze.overview"
    case rescan = "mopanel.analyze.rescan"
    case parent = "mopanel.analyze.parent"
    case scanStop = "mopanel.scan.stop"
    case dismissError = "mopanel.error.dismiss"
    case preview = "mopanel.maintenance.clean.preview"
    case review = "mopanel.maintenance.clean.review"
    case confirmationCancel = "mopanel.confirmation.cancel"
    case acknowledge = "mopanel.confirmation.acknowledge"
    case confirm = "mopanel.confirmation.continue"
    case operationStop = "mopanel.operation.stop"
    case operationClose = "mopanel.operation.close"
    case operationDetails = "mopanel.operation.details.toggle"

    var allowedRoles: Set<String> {
        self == .acknowledge ? ["AXCheckBox", "AXSwitch"] : ["AXButton"]
    }
}

private enum NativeUIFailure: LocalizedError {
    case unsafeContext, missingWindow, treeLimit, duplicateControl(String), unavailableControl(String),
         actionRejected(String), unexpectedState(String), timedOut(String)
    var errorDescription: String? {
        switch self {
        case .unsafeContext: return "Native UI tests require the exact smoke launch and the unchanged bundled mock executable."
        case .missingWindow: return "The explicitly supplied own-process content window is unavailable."
        case .treeLimit: return "The own-window accessibility tree exceeded its bounded traversal limit."
        case .duplicateControl(let id): return "Multiple actionable accessibility elements have identifier \(id)."
        case .unavailableControl(let id): return "No unique enabled own-window accessibility control was exposed for \(id)."
        case .actionRejected(let id): return "No permitted public accessibility press was dispatched successfully for \(id); inspect the recorded interface and actual return value."
        case .unexpectedState(let description): return "Native UI postcondition failed: \(description)."
        case .timedOut(let description): return "Native UI test timed out: \(description)."
        }
    }
}

/// AppKit permits role-specific accessibility protocols without conformance to
/// the entire NSAccessibilityProtocol. SwiftUI virtual elements can therefore
/// expose public AX selectors without passing that broader protocol cast. Keep
/// those objects in the same own-window tree instead of silently dropping them.
/// Only documented AppKit selectors/legacy attributes are queried. In particular
/// a BOOL or NSRect result must never be read using NSObject.perform(_:).
@MainActor private struct OwnAccessibilityNode {
    let object: NSObject
    private var direct: (any NSAccessibilityProtocol)? { object as? any NSAccessibilityProtocol }
    var hasProtocolConformance: Bool { direct != nil }
    var hasAccessibilitySelectors: Bool {
        ["accessibilityChildren", "accessibilityRole", "accessibilityAttributeValue:"]
            .contains { object.responds(to: NSSelectorFromString($0)) }
    }
    var identifierAccessorStatus: String {
        if direct != nil { return "protocol" }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector) else { return "absent" }
        return implementation(selector, result: .object) == nil ? "unsupported-abi" : "compatible"
    }
    private typealias ObjectGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias ObjectAttributeGetter = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
    private typealias VoidAction = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private typealias BooleanGetter = @convention(c) (AnyObject, Selector) -> Bool
    private typealias CharBooleanGetter = @convention(c) (AnyObject, Selector) -> Int8
    private typealias RectGetter = @convention(c) (AnyObject, Selector) -> NSRect
    private typealias SelectorPermission = @convention(c) (AnyObject, Selector, Selector) -> Bool
    private typealias CharSelectorPermission = @convention(c) (AnyObject, Selector, Selector) -> Int8

    private enum ResultKind { case object, boolean, rect, void }
    private func implementation(_ selector: Selector, result: ResultKind, arguments: [String] = []) -> (IMP, String)? {
        guard object.responds(to: selector), let type = object_getClass(object),
              let method = class_getInstanceMethod(type, selector),
              method_getNumberOfArguments(method) == UInt32(arguments.count + 2) else { return nil }
        func encoding(_ index: UInt32?) -> String? {
            var buffer = [CChar](repeating: 0, count: 256)
            if let index { method_getArgumentType(method, index, &buffer, buffer.count) }
            else { method_getReturnType(method, &buffer, buffer.count) }
            guard buffer.last == 0 else { return nil }
            return String(cString: buffer).drop(while: { "rnNoORV".contains($0) }).description
        }
        func isObject(_ value: String) -> Bool { value == "@" || value.hasPrefix("@\"") }
        guard let resultEncoding = encoding(nil), let receiver = encoding(0), isObject(receiver), encoding(1) == ":" else { return nil }
        for (index, expected) in arguments.enumerated() {
            guard let value = encoding(UInt32(index + 2)), expected == "@" ? isObject(value) : value == expected else { return nil }
        }
        switch result {
        case .object: guard isObject(resultEncoding) else { return nil }
        case .boolean: guard ["B", "c"].contains(resultEncoding) else { return nil }
        case .rect: guard resultEncoding == String(cString: NSValue(rect: .zero).objCType) else { return nil }
        case .void: guard resultEncoding == "v" else { return nil }
        }
        return (method_getImplementation(method), resultEncoding)
    }

    private func objectValue(_ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard let (implementation, _) = implementation(selector, result: .object) else { return nil }
        let getter = unsafeBitCast(implementation, to: ObjectGetter.self)
        return getter(object, selector)?.takeUnretainedValue()
    }
    private func booleanValue(_ name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard let (implementation, encoding) = implementation(selector, result: .boolean) else { return nil }
        if encoding == "c" { return unsafeBitCast(implementation, to: CharBooleanGetter.self)(object, selector) != 0 }
        return unsafeBitCast(implementation, to: BooleanGetter.self)(object, selector)
    }
    private func legacyAttribute(_ name: String) -> AnyObject? {
        // Old AppKit objects can reject unknown attributes. Query only an
        // attribute they advertise; never enumerate or read labels/values.
        guard let supported = objectValue("accessibilityAttributeNames") as? [String], supported.contains(name) else { return nil }
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard let (implementation, _) = implementation(selector, result: .object, arguments: ["@"]) else { return nil }
        let getter = unsafeBitCast(implementation, to: ObjectAttributeGetter.self)
        return getter(object, selector, name as NSString)?.takeUnretainedValue()
    }
    func accessibilityIdentifier() -> String? {
        direct?.accessibilityIdentifier() ?? objectValue("accessibilityIdentifier") as? String ?? legacyAttribute("AXIdentifier") as? String
    }
    func accessibilityRole() -> String? {
        direct?.accessibilityRole()?.rawValue ?? objectValue("accessibilityRole") as? String ?? legacyAttribute("AXRole") as? String
    }
    func accessibilityWindow() -> NSWindow? {
        if let value = direct?.accessibilityWindow() as? NSWindow { return value }
        if let value = objectValue("accessibilityWindow") as? NSWindow { return value }
        if let value = legacyAttribute("AXWindow") as? NSWindow { return value }
        if let view = object as? NSView { return view.window }
        return object as? NSWindow
    }
    func belongs(to expected: NSWindow) -> Bool {
        if let view = object as? NSView { return view.window === expected }
        if let owner = accessibilityWindow() {
            if owner === expected { return true }
            // A sheet element may report its sheet parent as AXWindow. This
            // alone is not ownership proof; require its public parent chain to
            // reach the actual supplied sheet or a view in that sheet below.
            guard expected.sheetParent === owner else { return false }
        }
        var visited = Set<ObjectIdentifier>([ObjectIdentifier(object)])
        var current = self
        for _ in 0..<40 {
            let parent = current.direct?.accessibilityParent() as? NSObject
                ?? current.objectValue("accessibilityParent") as? NSObject
                ?? current.legacyAttribute("AXParent") as? NSObject
            guard let parent, visited.insert(ObjectIdentifier(parent)).inserted else { return false }
            if let window = parent as? NSWindow { return window === expected }
            if let view = parent as? NSView { return view.window === expected }
            if parent is NSApplication { return false }
            current = OwnAccessibilityNode(object: parent)
        }
        return false
    }
    func accessibilityFrame() -> NSRect? {
        if let direct { return direct.accessibilityFrame() }
        let selector = NSSelectorFromString("accessibilityFrame")
        if let (implementation, _) = implementation(selector, result: .rect) {
            return unsafeBitCast(implementation, to: RectGetter.self)(object, selector)
        }
        guard let position = legacyAttribute("AXPosition") as? NSValue,
              let size = legacyAttribute("AXSize") as? NSValue else { return nil }
        return NSRect(origin: position.pointValue, size: size.sizeValue)
    }
    func isAccessibilityElement() -> Bool {
        if let direct { return direct.isAccessibilityElement() }
        if let value = booleanValue("isAccessibilityElement") { return value }
        return booleanValue("accessibilityIsIgnored") == false
    }
    func enabledValue() -> Bool? {
        if let direct { return direct.isAccessibilityEnabled() }
        return booleanValue("isAccessibilityEnabled") ?? (legacyAttribute("AXEnabled") as? NSNumber)?.boolValue
    }
    func isAccessibilityEnabled() -> Bool { enabledValue() == true }
    func accessibilityChildren() -> [Any] {
        var children = direct?.accessibilityChildren() ?? objectValue("accessibilityChildren") as? [Any] ?? []
        if let direct { children.append(contentsOf: direct.accessibilityChildrenInNavigationOrder() ?? []) }
        else { children.append(contentsOf: objectValue("accessibilityChildrenInNavigationOrder") as? [Any] ?? []) }
        children.append(contentsOf: objectValue("accessibilityVisibleChildren") as? [Any] ?? [])
        children.append(contentsOf: legacyAttribute("AXChildren") as? [Any] ?? [])
        return children
    }
    private func selectorAllowed(_ selector: Selector) -> Bool? {
        if let direct { return direct.isAccessibilitySelectorAllowed(selector) }
        let permission = NSSelectorFromString("isAccessibilitySelectorAllowed:")
        guard object.responds(to: permission),
              let (implementation, encoding) = implementation(permission, result: .boolean, arguments: [":"]) else { return nil }
        return encoding == "c"
            ? unsafeBitCast(implementation, to: CharSelectorPermission.self)(object, permission, selector) != 0
            : unsafeBitCast(implementation, to: SelectorPermission.self)(object, permission, selector)
    }
    func dispatchAccessibilityPress() -> NativeUIPressDispatch {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let modernSupported = object.responds(to: selector) &&
            (direct != nil || implementation(selector, result: .boolean) != nil)
        let modernAllowed = modernSupported ? selectorAllowed(selector) : nil
        let advertised = objectValue("accessibilityActionNames") as? [String]
        let legacyAdvertised = advertised.map { $0.count <= 256 && $0.contains(NSAccessibility.Action.press.rawValue) } == true
        let legacySelector = NSSelectorFromString("accessibilityPerformAction:")
        // NSButtonCell is a real, visible product control's native AX element,
        // not a proxy introduced by the test. AppKit may implement its action
        // with the documented key-based interface despite inherited modern
        // protocol methods. Select one advertised interface BEFORE invocation.
        let legacyImplementation = object is NSButtonCell && legacyAdvertised
            ? implementation(legacySelector, result: .void, arguments: ["@"])?.0 : nil
        let method = legacyImplementation != nil ? "legacyAXPress"
            : modernSupported && modernAllowed == true ? "modernPerformPress" : "none"
        if Array(ProcessInfo.processInfo.arguments.dropFirst()) == ["--smoke-test"] {
            let allowed = modernAllowed.map { $0 ? "true" : "false" } ?? "unknown"
            fputs("[MoPanelNativeUI] press.capability method=\(method) modernSupported=\(modernSupported) modernAllowed=\(allowed) legacyAdvertised=\(legacyAdvertised) legacyABI=\(legacyImplementation != nil)\n", stderr)
            fflush(stderr)
        }
        if let legacyImplementation {
            // An advertised fixed AXPress action has a void return. Record only
            // that dispatch returned; the caller must still prove its effect.
            let perform = unsafeBitCast(legacyImplementation, to: VoidAction.self)
            perform(object, legacySelector, NSAccessibility.Action.press.rawValue as NSString)
            return .init(method: method, modernSupported: modernSupported, modernAllowed: modernAllowed,
                         modernInvoked: false, modernResult: nil, legacyAdvertised: true, legacyDispatched: true)
        }
        if method == "modernPerformPress" {
            let accepted = direct?.accessibilityPerformPress() ?? booleanValue("accessibilityPerformPress")
            // Never try a second action API after this call, even on false.
            return .init(method: method, modernSupported: modernSupported, modernAllowed: modernAllowed,
                         modernInvoked: true, modernResult: accepted, legacyAdvertised: legacyAdvertised, legacyDispatched: false)
        }
        return .init(method: method, modernSupported: modernSupported, modernAllowed: modernAllowed,
                     modernInvoked: false, modernResult: nil, legacyAdvertised: legacyAdvertised, legacyDispatched: false)
    }
}

@MainActor private final class OwnWindowRunner {
    private let model: AppModel
    private let window: NSWindow
    private let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    private var contextWasValidated = false
    private var publicAccessibilityEnvironmentEnabled: Bool?
    private var environmentWasObserved = false
    private var checks: [String: Bool] = [:]
    private var actions: [NativeUIActionEvidence] = []
    private var errors: [String] = []
    private var maximumTreeNodesObserved = 0
    private var maximumProtocolNodesObserved = 0
    private var maximumSelectorOnlyNodesObserved = 0
    private var observedElementClasses = Set<String>()
    private var maximumUnsupportedChildrenObserved = 0
    private var observedUnsupportedChildTypes = Set<String>()
    private var observedIdentifiers = Set<String>()
    private var cleanupRequested = false
    private var activeControl: NativeUIControl?
    private var phaseBreadcrumbs = 0
    private var nodeBreadcrumbs = 0
    private var nodeDiagnostics = 0
    private var priorityNodeDiagnostics = Set<String>()

    init(model: AppModel, window: NSWindow) { self.model = model; self.window = window }

    func run() async -> NativeUIReport {
        breadcrumb("run.begin")
        do {
            breadcrumb("fixture.validate.begin")
            try validateContext()
            breadcrumb("fixture.validate.end")
            contextWasValidated = true
            guard !model.hasRunningOperation, model.pending == nil, !model.showOperation,
                  model.error == nil else { throw NativeUIFailure.unexpectedState("start with no active operation, modal or error") }
            checks["exact_bundled_fixture_guard"] = true
            try await waitFor("public SwiftUI accessibility environment was read back") {
                self.publicAccessibilityEnvironmentEnabled == true
            }
            environmentWasObserved = true
            breadcrumb("environment.read.true")
            checks["public_accessibility_environment_read_back"] = true
            // Route selection and monitor teardown are test setup, explicitly
            // distinguished from the user-facing actions asserted below.
            model.pauseMonitoring()

            model.section = .dashboard
            let statusActivity = model.activities.first?.id
            try await press(.snapshot)
            let statusCommand = try MoleInvocation.make(command: .status, options: [.json]).displayCommand
            try await waitFor("snapshot action completed") {
                self.completedActivity(after: statusActivity, command: statusCommand) && self.model.status?.host == "fixture-only"
            }
            try record("snapshot_button_loaded_fixture_metrics", model.error == nil)
            try verifyLastPress(.snapshot)

            model.section = .uninstall
            let inventoryActivity = model.activities.first?.id
            try await press(.appScan)
            let inventoryCommand = try MoleInvocation.make(command: .uninstall, options: [.uninstallList]).displayCommand
            try await waitFor("app inventory action completed") {
                self.completedActivity(after: inventoryActivity, command: inventoryCommand) && self.model.apps.count == 3
            }
            try record("inventory_button_loaded_fixture_apps", model.error == nil && model.apps.allSatisfy { $0.bundleID.hasPrefix("org.example.fixture.") })
            try verifyLastPress(.appScan)

            model.section = .analyze
            let overviewActivity = model.activities.first?.id
            try await press(.overview)
            let overviewCommand = try MoleInvocation.make(command: .analyze, options: [.json]).displayCommand
            try await waitFor("overview scan action completed", seconds: 5) {
                self.completedActivity(after: overviewActivity, command: overviewCommand) && self.model.analysis?.path == "/Users/fixture"
            }
            try record("overview_button_preserved_partial_and_unavailable", model.error == nil && model.analysis?.scanStatus == .partial &&
                       model.analysis?.entries.contains(where: { $0.scanStatus == .unavailable && $0.measuredBytes == nil }) == true)
            try verifyLastPress(.overview)

            let rescanActivity = model.activities.first?.id
            try await press(.rescan)
            let rescanCommand = try MoleInvocation.make(command: .analyze, options: [.json, .analyzePath("/Users/fixture")]).displayCommand
            try await waitFor("rescan action completed") {
                self.completedActivity(after: rescanActivity, command: rescanCommand) && self.model.analysis != nil
            }
            try record("rescan_button_used_current_fixture_path", model.error == nil)
            try verifyLastPress(.rescan)

            let parentActivity = model.activities.first?.id
            try await press(.parent)
            let parentCommand = try MoleInvocation.make(command: .analyze, options: [.json, .analyzePath("/Users")]).displayCommand
            try await waitFor("parent action completed") {
                self.completedActivity(after: parentActivity, command: parentCommand) && self.model.analysis != nil
            }
            try record("parent_button_requested_parent_path", model.error == nil)
            try verifyLastPress(.parent)

            // The exact mock overview branch delays output for three seconds.
            // Nothing is seeded directly into the model to imitate a scan.
            let cancelledScanActivity = model.activities.first?.id
            try await press(.overview)
            try await waitFor("overview scan entered busy state") { self.model.busy == overviewCommand }
            try verifyLastPress(.overview)
            try await press(.scanStop)
            try await waitFor("scan cancellation settled") {
                self.completedActivity(after: cancelledScanActivity, command: overviewCommand) && self.model.error != nil
            }
            try record("scan_stop_button_cancelled_without_partial_json", model.analysis == nil && !model.hasRunningOperation)
            try verifyLastPress(.scanStop)
            try await press(.dismissError)
            try await waitFor("error dismissal") { self.model.error == nil }
            try record("dismiss_error_button_cleared_message", true)
            try verifyLastPress(.dismissError)

            model.section = .clean
            try await press(.preview)
            let previewCommand = try MoleInvocation.make(command: .clean, options: [.dryRun]).displayCommand
            try await waitFor("dry-run operation sheet opened") {
                self.model.showOperation && self.model.operationSession.running && self.model.operationCommand == previewCommand
            }
            try record("preview_button_started_dry_run_without_confirmation", model.operationWasPreview && model.pending == nil)
            try record("operation_progress_remained_in_main_window", window.attachedSheet == nil)
            try verifyLastPress(.preview)
            try await press(.operationStop)
            try await waitFor("operation cancellation settled") {
                !self.model.operationSession.running && self.model.operationResult?.cancelled == true
            }
            try record("operation_stop_button_cancelled_fixture_child", true)
            try verifyLastPress(.operationStop)
            try await press(.operationClose)
            try await waitFor("operation sheet closed") { !self.model.showOperation && self.window.attachedSheet == nil }
            try record("operation_close_button_returned_to_page", true)
            try verifyLastPress(.operationClose)

            let beforeReview = model.activities.first?.id
            try await press(.review)
            try await waitFor("review confirmation opened") { self.model.pending?.invocation.arguments == ["clean"] }
            try record("confirmation_remained_in_main_window", window.attachedSheet == nil)
            let disabledContinue = try await find(.confirm, enabled: false)
            try record("confirmation_requires_acknowledgement", !disabledContinue.isAccessibilityEnabled() && !model.operationSession.running)
            try verifyLastPress(.review)
            try await press(.confirmationCancel)
            try await waitFor("review cancellation closed sheet") { self.model.pending == nil && self.window.attachedSheet == nil }
            try record("confirmation_cancel_did_not_execute", model.activities.first?.id == beforeReview && !model.showOperation)
            try verifyLastPress(.confirmationCancel)

            try await press(.review)
            try await waitFor("second review confirmation opened") { self.model.pending?.invocation.arguments == ["clean"] }
            try verifyLastPress(.review)
            try await press(.acknowledge)
            _ = try await find(.confirm, enabled: true)
            try record("acknowledgement_enabled_continue", true)
            try verifyLastPress(.acknowledge)
            let confirmationActivity = model.activities.first?.id
            try await press(.confirm)
            let cleanCommand = try MoleInvocation.make(command: .clean).displayCommand
            try await waitFor("interactive fixture started inline") {
                self.model.showOperation && self.model.operationSession.running && self.model.operationIsInteractive
            }
            try record("interactive_details_start_folded", !model.operationDetailsExpanded && window.attachedSheet == nil)
            try verifyLastPress(.confirm)
            try await press(.operationDetails)
            try await waitFor("inline details expanded") { self.model.operationDetailsExpanded }
            try record("inline_details_expanded_without_window", window.attachedSheet == nil && model.operationSession.running)
            try verifyLastPress(.operationDetails)
            try await press(.operationDetails)
            try await waitFor("inline details folded") { !self.model.operationDetailsExpanded }
            try await Task.sleep(for: .milliseconds(80))
            try record("folding_details_did_not_cancel_interactive_child", model.operationSession.running && model.operationResult == nil)
            try verifyLastPress(.operationDetails)
            try await waitFor("confirmed fixture action completed", seconds: 8) {
                self.completedActivity(after: confirmationActivity, command: cleanCommand) && self.model.showOperation &&
                    self.model.operationCommand == cleanCommand && self.model.operationResult?.succeeded == true
            }
            // Interactive output is intentionally not retained, even in tests.
            // Exact resource/fingerprint guards plus the fresh command activity
            // and a successful child result establish the executed fixture.
            try validateContext()
            try record("confirmation_button_executed_only_mock", model.installation?.source == .fixture && model.pending == nil && !model.operationSession.running)
            try record("interactive_output_remained_unretained", model.operationIsInteractive && model.operationResult?.stdout.isEmpty == true && model.operationResult?.stderr.isEmpty == true)
            try await press(.operationClose)
            try await waitFor("confirmed operation sheet closed") { !self.model.showOperation && self.window.attachedSheet == nil }
            try record("confirmed_operation_returned_to_page", !model.hasRunningOperation && model.error == nil)
            try verifyLastPress(.operationClose)
            try record("all_19_dispatches_have_verified_postconditions", actions.count == 19 &&
                       actions.allSatisfy { $0.hasSingleSuccessfulDispatch && $0.postconditionVerified })
            try validateContext()
            checks["fixture_guard_retained_after_all_actions"] = true
        } catch {
            breadcrumb("run.failed")
            errors.append(error.localizedDescription)
            if let error = model.error { errors.append(String(error.prefix(1_024))) }
            if contextWasValidated {
                // Failure teardown is not counted as a tested button. Never use
                // direct model calls to rescue an action or manufacture success.
                cleanupRequested = true
                model.cancelScan()
                model.operationSession.cancel()
                model.pending = nil
            }
        }
        breadcrumb("run.report")
        return NativeUIReport(passed: errors.isEmpty && checks["fixture_guard_retained_after_all_actions"] == true && checks.values.allSatisfy { $0 },
            mechanism: "AppKit own-window accessibility tree; one public modern press or advertised NSButtonCell AXPress, followed by explicit postcondition verification", fixtureOnly: contextWasValidated,
            ownProcessOnly: true, physicalInputInjected: false, accessibilityPermissionRequested: false,
            routeSetupUsesModelState: true, directActionFallbackUsed: false, cleanupRequestedAfterFailure: cleanupRequested,
            publicAccessibilityEnvironmentEnabled: publicAccessibilityEnvironmentEnabled,
            checks: checks, actions: actions, maximumTreeNodesObserved: maximumTreeNodesObserved,
            maximumProtocolNodesObserved: maximumProtocolNodesObserved,
            maximumSelectorOnlyNodesObserved: maximumSelectorOnlyNodesObserved,
            observedElementClasses: observedElementClasses.sorted(),
            maximumUnsupportedChildrenObserved: maximumUnsupportedChildrenObserved,
            observedUnsupportedChildTypes: observedUnsupportedChildTypes.sorted(),
            observedControlIdentifiers: observedIdentifiers.sorted(), errors: errors)
    }

    private func validateContext() throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard Array(arguments.dropFirst()) == ["--smoke-test"], model.fixtureMode, model.isTestLaunch,
              !model.readOnlyBenchmarkRequested, model.testLaunchError == nil,
              Bundle.main.bundleURL.pathExtension == "app",
              let expected = AppResources.bundle?.url(forResource: "mock-mo", withExtension: "sh", subdirectory: "Fixtures"),
              let installed = model.installation, installed.source == .fixture else { throw NativeUIFailure.unsafeContext }
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let resource = expected.resolvingSymlinksInPath()
        guard resource.path.hasPrefix(app + "/Contents/Resources/"),
              installed.executable.resolvingSymlinksInPath() == resource,
              installed.resolved.resolvingSymlinksInPath() == resource,
              try CLIProbe.fingerprint(installed.executable) == installed.fingerprint else { throw NativeUIFailure.unsafeContext }
        guard NSApp.windows.contains(where: { $0 === window }), window.contentView != nil, window.isVisible else { throw NativeUIFailure.missingWindow }
        publicAccessibilityEnvironmentEnabled = readAccessibilityEnvironment()
        if environmentWasObserved && publicAccessibilityEnvironmentEnabled != true {
            throw NativeUIFailure.unexpectedState("public SwiftUI accessibility environment changed or detached")
        }
    }

    private func readAccessibilityEnvironment() -> Bool? {
        guard let content = window.contentView else { return nil }
        var pending: [(NSView, Int)] = [(content, 0)]
        var visited = Set<ObjectIdentifier>()
        var observations: [Bool] = []
        while let (view, depth) = pending.popLast() {
            guard visited.insert(ObjectIdentifier(view)).inserted else { continue }
            guard visited.count <= 4_096, depth <= 40, view.window === window else { return nil }
            if let reader = view as? NativeUIAccessibilityEnvironmentView,
               let enabled = reader.observedEnabled { observations.append(enabled) }
            guard pending.count + view.subviews.count <= 4_096 else { return nil }
            pending.append(contentsOf: view.subviews.map { ($0, depth + 1) })
        }
        // Require one actual reader attached to this supplied content window.
        // A requested flag or a reader in a different window is not evidence.
        return observations.count == 1 ? observations.first : nil
    }

    private func validateAction(_ control: NativeUIControl) throws {
        try validateContext()
        let valid: Bool
        switch control {
        case .snapshot: valid = model.section == .dashboard && model.canStart
        case .appScan: valid = model.section == .uninstall && model.canStart
        case .overview, .rescan, .parent: valid = model.section == .analyze && model.canStart
        case .scanStop: valid = model.section == .analyze && model.busy == "mo analyze --json"
        case .dismissError: valid = model.section == .analyze && model.error != nil
        case .preview, .review: valid = model.section == .clean && model.canStart && model.pending == nil && !model.showOperation
        case .confirmationCancel, .acknowledge, .confirm:
            valid = model.section == .clean && model.pending?.invocation.arguments == ["clean"] && !model.showOperation
        case .operationStop, .operationClose, .operationDetails:
            valid = model.section == .clean && model.showOperation && ["mo clean", "mo clean --dry-run"].contains(model.operationCommand)
        }
        guard valid else { throw NativeUIFailure.unexpectedState("action context for \(control.rawValue)") }
    }

    private func record(_ name: String, _ value: Bool) throws {
        checks[name] = value
        breadcrumb(value ? "postcondition.pass" : "postcondition.fail")
        if !value { throw NativeUIFailure.unexpectedState(name) }
    }

    private func completedActivity(after previousID: UUID?, command: String) -> Bool {
        model.activities.first?.id != previousID && model.activities.first?.command == command && !model.hasRunningOperation
    }

    private func waitFor(_ description: String, seconds: Double = 3,
                         condition: () -> Bool) async throws {
        breadcrumb("postcondition.wait.begin")
        let local = ContinuousClock.now.advanced(by: .milliseconds(Int64(seconds * 1_000)))
        repeat {
            try validateContext()
            if condition() { breadcrumb("postcondition.wait.end"); return }
            guard ContinuousClock.now < deadline, ContinuousClock.now < local else { throw NativeUIFailure.timedOut(description) }
            try await Task.sleep(for: .milliseconds(40))
        } while true
    }

    private func press(_ control: NativeUIControl) async throws {
        activeControl = control
        breadcrumb("press.validate.begin")
        try validateAction(control)
        breadcrumb("press.find.begin")
        let element = try await find(control, enabled: true)
        breadcrumb("press.find.end")
        try validateAction(control)
        breadcrumb("press.role.begin")
        let role = element.accessibilityRole() ?? ""
        breadcrumb("press.role.end", role: role)
        let targetWindow = try scopeWindow(for: control)
        guard element.belongs(to: targetWindow), control.allowedRoles.contains(role), element.isAccessibilityEnabled() else {
            throw NativeUIFailure.unavailableControl(control.rawValue)
        }
        breadcrumb("press.perform.begin", role: role)
        let dispatch = element.dispatchAccessibilityPress()
        breadcrumb(dispatch.dispatchedSuccessfully ? "press.perform.dispatched" : "press.perform.rejected", role: role)
        actions.append(.init(identifier: control.rawValue, role: role, enabledBeforePress: true,
                             pressAccepted: dispatch.modernResult, ownedWindow: true, dispatchMethod: dispatch.method,
                             modernSelectorSupported: dispatch.modernSupported, modernSelectorAllowed: dispatch.modernAllowed,
                             modernMethodInvoked: dispatch.modernInvoked, legacyPressAdvertised: dispatch.legacyAdvertised,
                             legacyVoidDispatched: dispatch.legacyDispatched, postconditionVerified: false))
        guard dispatch.dispatchedSuccessfully else { throw NativeUIFailure.actionRejected(control.rawValue) }
        await Task.yield()
    }

    /// Called only after this action's existing business wait/record checks.
    /// Returning from a legacy void method alone never establishes success.
    private func verifyLastPress(_ control: NativeUIControl) throws {
        try validateContext()
        guard let last = actions.last, last.identifier == control.rawValue,
              last.hasSingleSuccessfulDispatch, !last.postconditionVerified else {
            throw NativeUIFailure.unexpectedState("one actual dispatch must precede its matching postcondition")
        }
        actions[actions.count - 1].postconditionVerified = true
        activeControl = control
        breadcrumb("press.postcondition.verified")
    }

    private func scopeWindow(for control: NativeUIControl) throws -> NSWindow {
        guard window.attachedSheet == nil else { throw NativeUIFailure.unavailableControl(control.rawValue) }
        return window
    }

    private func find(_ control: NativeUIControl, enabled: Bool) async throws -> OwnAccessibilityNode {
        activeControl = control
        breadcrumb("find.begin")
        let local = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            try validateContext()
            if let target = try? scopeWindow(for: control) {
                let matches = try matches(control, in: target)
                guard matches.count <= 1 else { throw NativeUIFailure.duplicateControl(control.rawValue) }
                if let match = matches.first {
                    breadcrumb("find.enabled.begin")
                    let actualEnabled = match.enabledValue()
                    breadcrumb("find.enabled.end")
                    if actualEnabled == enabled { breadcrumb("find.end"); return match }
                }
            }
            guard ContinuousClock.now < deadline, ContinuousClock.now < local else { throw NativeUIFailure.unavailableControl(control.rawValue) }
            try await Task.sleep(for: .milliseconds(40))
        } while true
    }

    private func matches(_ control: NativeUIControl, in targetWindow: NSWindow) throws -> [OwnAccessibilityNode] {
        guard let content = targetWindow.contentView else { throw NativeUIFailure.missingWindow }
        breadcrumb("tree.layout.begin", node: 0)
        content.layoutSubtreeIfNeeded()
        breadcrumb("tree.layout.end", node: 0)
        // The AX hierarchy can skip the content view and expose virtual SwiftUI
        // children through its NSWindow. Include both legitimate owned roots.
        var queue: [(NSObject, Int)] = [(targetWindow, 0), (content, 0)]
        var index = 0
        var visited = Set<ObjectIdentifier>()
        var result: [OwnAccessibilityNode] = []
        var protocolNodes = 0, selectorOnlyNodes = 0
        var unsupportedChildren = 0
        func enqueue(_ children: [Any], depth: Int) throws {
            guard children.count <= 4_096, queue.count + children.count <= 16_384 else { throw NativeUIFailure.treeLimit }
            for child in children {
                if let child = child as? NSObject { queue.append((child, depth)) }
                else {
                    unsupportedChildren += 1
                    if observedUnsupportedChildTypes.count < 32 {
                        let name = String(String(reflecting: type(of: child)).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "._<>".contains($0)) }.prefix(140))
                        observedUnsupportedChildTypes.insert(name)
                    }
                }
            }
        }
        try enqueue(NSAccessibility.unignoredChildren(from: [content]), depth: 1)
        while index < queue.count {
            let (object, depth) = queue[index]; index += 1
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            guard visited.count <= 4_096, depth <= 40, queue.count <= 16_384 else { throw NativeUIFailure.treeLimit }
            let accessibility = OwnAccessibilityNode(object: object)
            if accessibility.hasProtocolConformance || accessibility.hasAccessibilitySelectors {
                if accessibility.hasProtocolConformance { protocolNodes += 1 } else { selectorOnlyNodes += 1 }
                breadcrumb("tree.identifier.begin", node: visited.count)
                let identifier = accessibility.accessibilityIdentifier()
                let role = accessibility.accessibilityRole()
                breadcrumb("tree.identifier.end", node: visited.count)
                if let identifier, NativeUIControl(rawValue: identifier) != nil { observedIdentifiers.insert(identifier) }
                if identifier == control.rawValue,
                   let role, control.allowedRoles.contains(role),
                   accessibility.isAccessibilityElement(),
                   accessibility.belongs(to: targetWindow),
                   let frame = accessibility.accessibilityFrame() {
                    let hiddenView = (object as? NSView)?.isHiddenOrHasHiddenAncestor ?? false
                    if !hiddenView, targetWindow.isVisible, frame.width > 0, frame.height > 0,
                       frame.intersects(targetWindow.frame) { result.append(accessibility) }
                }
                breadcrumb("tree.children.begin", node: visited.count)
                let children = accessibility.accessibilityChildren()
                breadcrumb("tree.children.end", node: visited.count)
                guard children.count <= 4_096 else { throw NativeUIFailure.treeLimit }
                diagnoseNode(accessibility, identifier: identifier, role: role, childCount: children.count, targetWindow: targetWindow)
                try enqueue(children, depth: depth + 1)
                let unignored = NSAccessibility.unignoredChildren(from: children)
                try enqueue(unignored, depth: depth + 1)
            }
            // Public NSView traversal handles an ignored hosting wrapper. It
            // never searches outside the explicitly owned window/content tree.
            if let view = object as? NSView, view.window === targetWindow {
                for child in view.subviews { queue.append((child, depth + 1)) }
            }
        }
        maximumTreeNodesObserved = max(maximumTreeNodesObserved, visited.count)
        maximumProtocolNodesObserved = max(maximumProtocolNodesObserved, protocolNodes)
        maximumSelectorOnlyNodesObserved = max(maximumSelectorOnlyNodesObserved, selectorOnlyNodes)
        maximumUnsupportedChildrenObserved = max(maximumUnsupportedChildrenObserved, unsupportedChildren)
        breadcrumb("tree.end", node: visited.count)
        return result
    }

    private func diagnoseNode(_ node: OwnAccessibilityNode, identifier: String?, role: String?, childCount: Int, targetWindow: NSWindow) {
        guard Array(ProcessInfo.processInfo.arguments.dropFirst()) == ["--smoke-test"] else { return }
        let name = String(NSStringFromClass(type(of: node.object)).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "._<>".contains($0)) }.prefix(140))
        if observedElementClasses.count < 48 { observedElementClasses.insert(name) }
        let knownIdentifier = identifier.flatMap(NativeUIControl.init(rawValue:))?.rawValue
        // The actual control may be visited after hundreds of sidebar nodes.
        // Reserve bounded, deduplicated diagnostics for exact allowlisted IDs
        // so a failed predicate remains inspectable without logging UI text.
        if knownIdentifier != nil {
            guard priorityNodeDiagnostics.count < 128 else { return }
        } else {
            guard nodeDiagnostics < 256 else { return }
            nodeDiagnostics += 1
        }
        let roles = ["AXButton", "AXCheckBox", "AXSwitch", "AXGroup", "AXWindow", "AXStaticText", "AXScrollArea", "AXSplitGroup", "AXOutline", "AXRow", "AXTextField", "AXUnknown"]
        let safeRole = role.map { roles.contains($0) ? $0 : "other" } ?? "none"
        let safeIdentifier = knownIdentifier ?? (identifier == nil ? "none" : "other")
        let owner = node.accessibilityWindow()
        let ownership = node.belongs(to: targetWindow) ? "owned" : owner.map { _ in "other" } ?? "unknown"
        let enabled = node.enabledValue().map { $0 ? "true" : "false" } ?? "unknown"
        let frame = node.accessibilityFrame().map { $0.width > 0 && $0.height > 0 && $0.intersects(targetWindow.frame) ? "visible" : "empty-or-outside" } ?? "unknown"
        let hiddenView = (node.object as? NSView).map { $0.isHiddenOrHasHiddenAncestor ? "true" : "false" } ?? "not-a-view"
        let diagnostic = "class=\(name) protocol=\(node.hasProtocolConformance) role=\(safeRole) id=\(safeIdentifier) idABI=\(node.identifierAccessorStatus) element=\(node.isAccessibilityElement()) enabled=\(enabled) window=\(ownership) frame=\(frame) hiddenView=\(hiddenView) children=\(childCount)"
        if knownIdentifier != nil, !priorityNodeDiagnostics.insert(diagnostic).inserted { return }
        fputs("[MoPanelNativeUI] node \(diagnostic)\n", stderr)
        fflush(stderr)
    }

    /// Diagnostics are restricted to this explicit fixture launch and fixed
    /// phase/control names, role names and counts. No AX labels/values, terminal
    /// content, credentials or user paths are printed. Flush before potentially
    /// synchronous AppKit calls so a watchdog sample can identify a stuck stage.
    private func breadcrumb(_ phase: String, role: String? = nil, node: Int? = nil) {
        guard Array(ProcessInfo.processInfo.arguments.dropFirst()) == ["--smoke-test"] else { return }
        if node != nil {
            guard nodeBreadcrumbs < 768 else { return }
            nodeBreadcrumbs += 1
        } else {
            guard phaseBreadcrumbs < 256 else { return }
            phaseBreadcrumbs += 1
        }
        let safeRole = role.map { ["AXButton", "AXCheckBox", "AXSwitch"].contains($0) ? $0 : "other" } ?? "none"
        let line = "[MoPanelNativeUI] \(phase) id=\(activeControl?.rawValue ?? "none") role=\(safeRole) node=\(node ?? 0)\n"
        fputs(line, stderr)
        fflush(stderr)
    }
}
