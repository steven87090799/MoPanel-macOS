import Foundation

/// A menu bar item is an explicit monitoring consumer, never a second collector.
public enum MonitoringDemand {
    public static func isNeeded(dashboardSelected: Bool, windowActive: Bool, menuBarEnabled: Bool,
                                paused: Bool, shuttingDown: Bool, systemSleeping: Bool = false) -> Bool {
        !paused && !shuttingDown && !systemSleeping && ((dashboardSelected && windowActive) || menuBarEnabled)
    }
}

public struct RunningApplicationIdentity: Equatable, Sendable {
    public let pid: Int32
    public let bundleIdentifier: String
    public let appPath: String
    public let executablePath: String
    public let launchedAt: Date
    public let isRegularApplication: Bool
    public init(pid: Int32, bundleIdentifier: String, appPath: String, executablePath: String,
                launchedAt: Date, isRegularApplication: Bool) {
        self.pid = pid; self.bundleIdentifier = bundleIdentifier; self.appPath = appPath
        self.executablePath = executablePath; self.launchedAt = launchedAt
        self.isRegularApplication = isRegularApplication
    }
}

public enum QuitAppPolicy {
    public enum Denial: String, Error, Sendable {
        case testing, staleSample, identityChanged, protectedApplication, notRegularApplication, sampleMismatch
    }
    /// The original NSRunningApplication object is retained by the UI and used
    /// for the action. This policy does not authorize sending a signal to a PID.
    public static func validate(expected: RunningApplicationIdentity, current: RunningApplicationIdentity,
                                selfPID: Int32, sampleCommand: String, sampledAt: Date,
                                now: Date, testMode: Bool) throws {
        if testMode { throw Denial.testing }
        guard expected == current else { throw Denial.identityChanged }
        guard expected.pid > 1, expected.pid != selfPID,
              expected.launchedAt.timeIntervalSince1970.isFinite,
              expected.launchedAt.timeIntervalSince1970 > 0 else { throw Denial.protectedApplication }
        let age = now.timeIntervalSince(sampledAt)
        guard age >= 0, age <= 15, expected.launchedAt <= sampledAt else { throw Denial.staleSample }
        guard expected.isRegularApplication, !expected.bundleIdentifier.isEmpty,
              expected.appPath.hasPrefix("/"), expected.appPath.hasSuffix(".app"),
              expected.executablePath.hasPrefix(expected.appPath + "/Contents/MacOS/") else { throw Denial.notRegularApplication }
        let identifier = expected.bundleIdentifier.lowercased()
        let path = expected.appPath.lowercased()
        guard !identifier.hasPrefix("com.apple."), !identifier.hasPrefix("org.mopanel."),
              !identifier.contains("buho"), !path.contains("buhocleaner"),
              !["/system/", "/usr/", "/bin/", "/sbin/", "/library/apple/"].contains(where: path.hasPrefix) else {
            throw Denial.protectedApplication
        }
        // A fallback ps command line, truncated path, or ambiguous whitespace is
        // deliberately not accepted as identity evidence.
        guard sampleCommand == expected.executablePath else { throw Denial.sampleMismatch }
    }
}
