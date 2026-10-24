// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import MoPanelCore

struct NativeUIActionEvidence: Codable {
    let identifier: String
    let role: String
    let enabledBeforePress: Bool
    let pressAccepted: Bool
    let ownedWindow: Bool
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
    let checks: [String: Bool]
    let actions: [NativeUIActionEvidence]
    let maximumTreeNodesObserved: Int
    let observedControlIdentifiers: [String]
    let errors: [String]
}

/// Uses the public, in-process AppKit accessibility protocol. This is not an
/// external AXUIElement client, mouse/keyboard injection or a TCC workaround.
/// An accepted accessibility press is always checked against its real effect.
@MainActor enum NativeUITestHarness {
    static func run(model: AppModel, window: NSWindow) async -> NativeUIReport {
        let runner = OwnWindowRunner(model: model, window: window)
        return await runner.run()
    }
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

    var requiresSheet: Bool {
        [.confirmationCancel, .acknowledge, .confirm, .operationStop, .operationClose].contains(self)
    }
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
        case .actionRejected(let id): return "accessibilityPerformPress returned false for \(id)."
        case .unexpectedState(let description): return "Native UI postcondition failed: \(description)."
        case .timedOut(let description): return "Native UI test timed out: \(description)."
        }
    }
}

@MainActor private final class OwnWindowRunner {
    private let model: AppModel
    private let window: NSWindow
    private let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    private var contextWasValidated = false
    private var checks: [String: Bool] = [:]
    private var actions: [NativeUIActionEvidence] = []
    private var errors: [String] = []
    private var maximumTreeNodesObserved = 0
    private var observedIdentifiers = Set<String>()
    private var cleanupRequested = false

    init(model: AppModel, window: NSWindow) { self.model = model; self.window = window }

    func run() async -> NativeUIReport {
        do {
            try validateContext()
            contextWasValidated = true
            guard !model.hasRunningOperation, model.pending == nil, !model.showOperation,
                  model.error == nil else { throw NativeUIFailure.unexpectedState("start with no active operation, modal or error") }
            checks["exact_bundled_fixture_guard"] = true
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

            model.section = .uninstall
            let inventoryActivity = model.activities.first?.id
            try await press(.appScan)
            let inventoryCommand = try MoleInvocation.make(command: .uninstall, options: [.uninstallList]).displayCommand
            try await waitFor("app inventory action completed") {
                self.completedActivity(after: inventoryActivity, command: inventoryCommand) && self.model.apps.count == 3
            }
            try record("inventory_button_loaded_fixture_apps", model.error == nil && model.apps.allSatisfy { $0.bundleID.hasPrefix("org.example.fixture.") })

            model.section = .analyze
            let overviewActivity = model.activities.first?.id
            try await press(.overview)
            let overviewCommand = try MoleInvocation.make(command: .analyze, options: [.json]).displayCommand
            try await waitFor("overview scan action completed", seconds: 5) {
                self.completedActivity(after: overviewActivity, command: overviewCommand) && self.model.analysis?.path == "/Users/fixture"
            }
            try record("overview_button_preserved_partial_and_unavailable", model.error == nil && model.analysis?.scanStatus == .partial &&
                       model.analysis?.entries.contains(where: { $0.scanStatus == .unavailable && $0.measuredBytes == nil }) == true)

            let rescanActivity = model.activities.first?.id
            try await press(.rescan)
            let rescanCommand = try MoleInvocation.make(command: .analyze, options: [.json, .analyzePath("/Users/fixture")]).displayCommand
            try await waitFor("rescan action completed") {
                self.completedActivity(after: rescanActivity, command: rescanCommand) && self.model.analysis != nil
            }
            try record("rescan_button_used_current_fixture_path", model.error == nil)

            let parentActivity = model.activities.first?.id
            try await press(.parent)
            let parentCommand = try MoleInvocation.make(command: .analyze, options: [.json, .analyzePath("/Users")]).displayCommand
            try await waitFor("parent action completed") {
                self.completedActivity(after: parentActivity, command: parentCommand) && self.model.analysis != nil
            }
            try record("parent_button_requested_parent_path", model.error == nil)

            // The exact mock overview branch delays output for three seconds.
            // Nothing is seeded directly into the model to imitate a scan.
            let cancelledScanActivity = model.activities.first?.id
            try await press(.overview)
            try await waitFor("overview scan entered busy state") { self.model.busy == overviewCommand }
            try await press(.scanStop)
            try await waitFor("scan cancellation settled") {
                self.completedActivity(after: cancelledScanActivity, command: overviewCommand) && self.model.error != nil
            }
            try record("scan_stop_button_cancelled_without_partial_json", model.analysis == nil && !model.hasRunningOperation)
            try await press(.dismissError)
            try await waitFor("error dismissal") { self.model.error == nil }
            try record("dismiss_error_button_cleared_message", true)

            model.section = .clean
            try await press(.preview)
            let previewCommand = try MoleInvocation.make(command: .clean, options: [.dryRun]).displayCommand
            try await waitFor("dry-run operation sheet opened") {
                self.model.showOperation && self.model.operationSession.running && self.model.operationCommand == previewCommand
            }
            try record("preview_button_started_dry_run_without_confirmation", model.operationWasPreview && model.pending == nil)
            try await press(.operationStop)
            try await waitFor("operation cancellation settled") {
                !self.model.operationSession.running && self.model.operationResult?.cancelled == true
            }
            try record("operation_stop_button_cancelled_fixture_child", true)
            try await press(.operationClose)
            try await waitFor("operation sheet closed") { !self.model.showOperation && self.window.attachedSheet == nil }
            try record("operation_close_button_returned_to_page", true)

            let beforeReview = model.activities.first?.id
            try await press(.review)
            try await waitFor("review confirmation opened") { self.model.pending?.invocation.arguments == ["clean"] }
            let disabledContinue = try await find(.confirm, enabled: false)
            try record("confirmation_requires_acknowledgement", !disabledContinue.isAccessibilityEnabled() && !model.operationSession.running)
            try await press(.confirmationCancel)
            try await waitFor("review cancellation closed sheet") { self.model.pending == nil && self.window.attachedSheet == nil }
            try record("confirmation_cancel_did_not_execute", model.activities.first?.id == beforeReview && !model.showOperation)

            try await press(.review)
            try await waitFor("second review confirmation opened") { self.model.pending?.invocation.arguments == ["clean"] }
            try await press(.acknowledge)
            _ = try await find(.confirm, enabled: true)
            try record("acknowledgement_enabled_continue", true)
            let confirmationActivity = model.activities.first?.id
            try await press(.confirm)
            let cleanCommand = try MoleInvocation.make(command: .clean).displayCommand
            try await waitFor("confirmed fixture action completed") {
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
            try validateContext()
            checks["fixture_guard_retained_after_all_actions"] = true
        } catch {
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
        return NativeUIReport(passed: errors.isEmpty && checks["fixture_guard_retained_after_all_actions"] == true && checks.values.allSatisfy { $0 },
            mechanism: "AppKit NSAccessibilityProtocol on own-window objects", fixtureOnly: contextWasValidated,
            ownProcessOnly: true, physicalInputInjected: false, accessibilityPermissionRequested: false,
            routeSetupUsesModelState: true, directActionFallbackUsed: false, cleanupRequestedAfterFailure: cleanupRequested,
            checks: checks, actions: actions, maximumTreeNodesObserved: maximumTreeNodesObserved,
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
        case .operationStop, .operationClose:
            valid = model.section == .clean && model.showOperation && ["mo clean", "mo clean --dry-run"].contains(model.operationCommand)
        }
        guard valid else { throw NativeUIFailure.unexpectedState("action context for \(control.rawValue)") }
    }

    private func record(_ name: String, _ value: Bool) throws {
        checks[name] = value
        if !value { throw NativeUIFailure.unexpectedState(name) }
    }

    private func completedActivity(after previousID: UUID?, command: String) -> Bool {
        model.activities.first?.id != previousID && model.activities.first?.command == command && !model.hasRunningOperation
    }

    private func waitFor(_ description: String, seconds: Double = 3,
                         condition: () -> Bool) async throws {
        let local = ContinuousClock.now.advanced(by: .milliseconds(Int64(seconds * 1_000)))
        repeat {
            try validateContext()
            if condition() { return }
            guard ContinuousClock.now < deadline, ContinuousClock.now < local else { throw NativeUIFailure.timedOut(description) }
            try await Task.sleep(for: .milliseconds(40))
        } while true
    }

    private func press(_ control: NativeUIControl) async throws {
        try validateAction(control)
        let element = try await find(control, enabled: true)
        try validateAction(control)
        let role = element.accessibilityRole()?.rawValue ?? ""
        let targetWindow = try scopeWindow(for: control)
        guard let owned = element.accessibilityWindow() as? NSWindow, owned === targetWindow,
              control.allowedRoles.contains(role), element.isAccessibilityEnabled() else {
            throw NativeUIFailure.unavailableControl(control.rawValue)
        }
        let accepted = element.accessibilityPerformPress()
        actions.append(.init(identifier: control.rawValue, role: role, enabledBeforePress: true,
                             pressAccepted: accepted, ownedWindow: true))
        guard accepted else { throw NativeUIFailure.actionRejected(control.rawValue) }
        await Task.yield()
    }

    private func scopeWindow(for control: NativeUIControl) throws -> NSWindow {
        if control.requiresSheet {
            guard let sheet = window.attachedSheet, sheet.sheetParent === window,
                  NSApp.windows.contains(where: { $0 === sheet }), sheet.contentView != nil,
                  sheet.isVisible else {
                throw NativeUIFailure.unavailableControl(control.rawValue)
            }
            return sheet
        }
        guard window.attachedSheet == nil else { throw NativeUIFailure.unavailableControl(control.rawValue) }
        return window
    }

    private func find(_ control: NativeUIControl, enabled: Bool) async throws -> any NSAccessibilityProtocol {
        let local = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            try validateContext()
            if let target = try? scopeWindow(for: control) {
                let matches = try matches(control, in: target)
                guard matches.count <= 1 else { throw NativeUIFailure.duplicateControl(control.rawValue) }
                if let match = matches.first, match.isAccessibilityEnabled() == enabled { return match }
            }
            guard ContinuousClock.now < deadline, ContinuousClock.now < local else { throw NativeUIFailure.unavailableControl(control.rawValue) }
            try await Task.sleep(for: .milliseconds(40))
        } while true
    }

    private func matches(_ control: NativeUIControl, in targetWindow: NSWindow) throws -> [any NSAccessibilityProtocol] {
        guard let content = targetWindow.contentView else { throw NativeUIFailure.missingWindow }
        content.layoutSubtreeIfNeeded()
        var queue: [(NSObject, Int)] = [(content, 0)]
        var index = 0
        var visited = Set<ObjectIdentifier>()
        var result: [any NSAccessibilityProtocol] = []
        while index < queue.count {
            let (object, depth) = queue[index]; index += 1
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            guard visited.count <= 4_096, depth <= 40, queue.count <= 16_384 else { throw NativeUIFailure.treeLimit }
            if let accessibility = object as? any NSAccessibilityProtocol {
                let identifier = accessibility.accessibilityIdentifier()
                if let identifier, NativeUIControl(rawValue: identifier) != nil { observedIdentifiers.insert(identifier) }
                if identifier == control.rawValue,
                   let role = accessibility.accessibilityRole()?.rawValue, control.allowedRoles.contains(role),
                   accessibility.isAccessibilityElement(),
                   let owner = accessibility.accessibilityWindow() as? NSWindow, owner === targetWindow {
                    let frame = accessibility.accessibilityFrame()
                    let hiddenView = (object as? NSView)?.isHiddenOrHasHiddenAncestor ?? false
                    if !hiddenView, targetWindow.isVisible, frame.width > 0, frame.height > 0,
                       frame.intersects(targetWindow.frame) { result.append(accessibility) }
                }
                for child in accessibility.accessibilityChildren() ?? [] {
                    if let child = child as? NSObject { queue.append((child, depth + 1)) }
                }
            }
            // Public NSView traversal handles an ignored hosting wrapper. It
            // never searches outside the explicitly owned window/content tree.
            if let view = object as? NSView, view.window === targetWindow {
                for child in view.subviews { queue.append((child, depth + 1)) }
            }
        }
        maximumTreeNodesObserved = max(maximumTreeNodesObserved, visited.count)
        return result
    }
}
