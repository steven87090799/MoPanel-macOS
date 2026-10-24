// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(Combine)
import Combine
public typealias ProcessObservable = ObservableObject
#else
public protocol ProcessObservable: AnyObject {}
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif

public struct ProcessRequest: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]?
    public let workingDirectory: URL?
    public let timeout: TimeInterval
    public let outputLimit: Int
    public let retainsOutput: Bool
    public let cooperativeCancellation: Bool

    public init(executable: URL, arguments: [String], environment: [String: String]? = nil,
                workingDirectory: URL? = nil, timeout: TimeInterval = 300,
                outputLimit: Int = 16 * 1024 * 1024, retainsOutput: Bool = true,
                cooperativeCancellation: Bool = false) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.workingDirectory = workingDirectory; self.timeout = timeout
        self.outputLimit = outputLimit; self.retainsOutput = retainsOutput
        self.cooperativeCancellation = cooperativeCancellation
    }
}

public struct ProcessResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
    public let timedOut: Bool
    public let cancelled: Bool
    public let outputTruncated: Bool
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 && !cancelled && !timedOut && !outputTruncated }
}

public enum ManagedProcessError: LocalizedError {
    case alreadyRunning, invalidRequest, helperMissing, executableMissing
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "A process is already running."
        case .invalidRequest: return "The executable, arguments, or process limits are invalid."
        case .helperMissing: return "MoPanelGuardian is missing or not executable. Reinstall the complete app."
        case .executableMissing: return "The selected executable does not exist or cannot be executed."
        }
    }
}

/// One owned child operation. All input stays in memory and is never logged.
/// Guardian watches a private pipe, so app death also cancels owned children.
@MainActor public final class ManagedProcess: ProcessObservable {
    @Published public private(set) var running = false
    @Published public private(set) var exitCode: Int32?
    @Published public private(set) var failure: String?
    @Published public private(set) var outputTruncated = false
    public private(set) var stdout = Data()
    public private(set) var stderr = Data()
    public var onOutput: ((Data) -> Void)? {
        didSet {
            guard let onOutput, !pendingTerminalOutput.isEmpty else { return }
            let pending = pendingTerminalOutput
            pendingTerminalOutput.removeAll(keepingCapacity: false)
            onOutput(pending)
        }
    }
    public var onError: ((Data) -> Void)?
    public var onExit: ((ProcessResult) -> Void)?

    private let helperURL: URL
    private let inputQueue = DispatchQueue(label: "app.mopanel.process.input", qos: .userInitiated)
    private var process: Process?
    private var controlHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputClosed = false
    private var errorClosed = false
    private var terminatedCode: Int32?
    private var completion: ProcessResult?
    private var waiters: [CheckedContinuation<ProcessResult, Never>] = []
    private var request: ProcessRequest?
    private var interactive = false
    private var pendingTerminalOutput = Data()
    private var cancellationRequested = false

    public init(helperURL: URL? = nil) {
        self.helperURL = helperURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/MoPanelGuardian")
    }

    deinit {
        // The guardian must outlive this object long enough to perform cleanup.
        try? controlHandle?.close()
    }

    public func start(request: ProcessRequest, interactive: Bool = false) throws {
        guard !running else { throw ManagedProcessError.alreadyRunning }
        guard request.executable.isFileURL, request.executable.path.hasPrefix("/"),
              !request.executable.path.utf8.contains(0), request.arguments.count <= 4096,
              request.arguments.allSatisfy({ !$0.utf8.contains(0) }),
              request.timeout.isFinite, request.timeout >= 0, request.timeout <= 86400,
              request.outputLimit >= 1024, request.outputLimit <= 128 * 1024 * 1024 else {
            throw ManagedProcessError.invalidRequest
        }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { throw ManagedProcessError.helperMissing }
        guard FileManager.default.isExecutableFile(atPath: request.executable.path) else { throw ManagedProcessError.executableMissing }
        self.request = request; self.interactive = interactive
        stdout.removeAll(keepingCapacity: false); stderr.removeAll(keepingCapacity: false)
        pendingTerminalOutput.removeAll(keepingCapacity: false)
        exitCode = nil; failure = nil; completion = nil; terminatedCode = nil
        outputTruncated = false; cancellationRequested = false; outputClosed = false; errorClosed = false
        let child = Process(), control = Pipe(), output = Pipe(), error = Pipe()
        child.executableURL = helperURL
        child.arguments = [interactive ? "--pty" : "--capture", "--timeout-ms", String(Int64(request.timeout * 1000))]
            + (request.cooperativeCancellation ? ["--cooperative"] : [])
            + ["--", request.executable.path] + request.arguments
        child.environment = Self.safeEnvironment(overrides: request.environment, interactive: interactive)
        child.currentDirectoryURL = request.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        child.standardInput = control; child.standardOutput = output; child.standardError = error
        controlHandle = control.fileHandleForWriting
        outputHandle = output.fileHandleForReading; errorHandle = error.fileHandleForReading
        child.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            DispatchQueue.main.async { [weak self] in
                self?.terminatedCode = status
                self?.finishIfReady()
            }
        }
        process = child; running = true
        do {
            try child.run()
            // Parent must close its copies of child ends so EOF is observable.
            try? control.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? error.fileHandleForWriting.close()
            startReader(output.fileHandleForReading, isError: false)
            startReader(error.fileHandleForReading, isError: true)
        } catch {
            running = false; failure = error.localizedDescription
            try? controlHandle?.close(); controlHandle = nil
            try? outputHandle?.close(); try? errorHandle?.close()
            process = nil
            throw error
        }
    }

    private func startReader(_ handle: FileHandle, isError: Bool) {
        // POSIX read returns available bytes immediately. Foundation's
        // read(upToCount:) can wait to fill its requested count, starving small
        // watch frames and PTY prompts until EOF. Backpressure still permits
        // only one <=64 KiB callback in flight for each stream.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer {
                try? handle.close()
                DispatchQueue.main.async { [weak self] in self?.receive(Data(), isError: isError) }
            }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = buffer.withUnsafeMutableBytes { storage in
                    read(handle.fileDescriptor, storage.baseAddress, storage.count)
                }
                if count == 0 { return }
                if count < 0 {
                    if errno == EINTR { continue }
                    DispatchQueue.main.async { [weak self] in
                        self?.outputTruncated = true
                        self?.failure = "Unable to read the complete command output."
                        self?.cancel()
                    }
                    return
                }
                let data = Data(buffer.prefix(count))
                let consumed = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { [weak self] in
                    self?.receive(data, isError: isError)
                    consumed.signal()
                }
                consumed.wait()
            }
        }
    }

    /// Pipe output is bounded. Stream consumers use retainsOutput=false.
    private func receive(_ data: Data, isError: Bool) {
        if data.isEmpty {
            if isError { errorClosed = true } else { outputClosed = true }
            finishIfReady(); return
        }
        guard let request else { return }
        if isError {
            let remaining = max(0, request.outputLimit - stderr.count)
            stderr.append(data.prefix(remaining)); onError?(data)
            if data.count > remaining { outputTruncated = true; cancel() }
        } else {
            if request.retainsOutput && !interactive {
                let remaining = max(0, request.outputLimit - stdout.count)
                stdout.append(data.prefix(remaining))
                if data.count > remaining { outputTruncated = true; cancel() }
            }
            if let onOutput { onOutput(data) }
            else if interactive {
                if pendingTerminalOutput.count + data.count <= 256 * 1024 { pendingTerminalOutput.append(data) }
                else { outputTruncated = true; cancel() }
            }
        }
    }

    private func finishIfReady() {
        guard let code = terminatedCode, outputClosed, errorClosed, completion == nil else { return }
        let result = ProcessResult(stdout: stdout, stderr: stderr, exitCode: code,
                                   timedOut: code == 124 && (request?.timeout ?? 0) > 0,
                                   cancelled: cancellationRequested || code == 130,
                                   outputTruncated: outputTruncated)
        completion = result; exitCode = code; running = false
        if result.timedOut { failure = "The command exceeded its time limit and was stopped." }
        else if outputTruncated { failure = "Output exceeded the safe memory limit; the command was stopped." }
        else if code != 0 && !result.cancelled { failure = "The command exited with status \(code)." }
        try? controlHandle?.close(); controlHandle = nil
        outputHandle = nil; errorHandle = nil; process = nil
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume(returning: result) }
        onExit?(result)
    }

    public func wait() async -> ProcessResult {
        if let completion { return completion }
        if !running {
            return ProcessResult(stdout: stdout, stderr: stderr, exitCode: exitCode ?? 125,
                                 timedOut: false, cancelled: cancellationRequested, outputTruncated: outputTruncated)
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    public func cancel() {
        guard running, !cancellationRequested else { return }
        cancellationRequested = true
        sendFrame(kind: 67, data: Data())
        // Even if a control frame cannot be delivered, EOF triggers cancellation.
        if let handle = controlHandle {
            inputQueue.async { try? handle.close() }
            controlHandle = nil
        }
    }

    public func send(_ data: Data) {
        guard running, interactive, !cancellationRequested, data.count <= 16384 else { return }
        sendFrame(kind: 73, data: data)
    }

    public func resize(columns: Int, rows: Int) {
        guard interactive else { return }
        let cols = min(1000, max(20, columns)), height = min(500, max(5, rows))
        sendFrame(kind: 82, data: Data([UInt8(cols >> 8), UInt8(cols & 255), UInt8(height >> 8), UInt8(height & 255)]))
    }

    private func sendFrame(kind: UInt8, data: Data) {
        guard let handle = controlHandle, data.count <= 65536 else { return }
        let count = UInt32(data.count)
        let bytes = Data([kind, UInt8((count >> 24) & 255), UInt8((count >> 16) & 255),
                          UInt8((count >> 8) & 255), UInt8(count & 255)]) + data
        inputQueue.async {
            var frame = bytes
            defer { frame.resetBytes(in: frame.startIndex..<frame.endIndex) }
            try? handle.write(contentsOf: frame)
        }
    }

    /// Do not inherit shell hooks, DYLD injection, sudo askpass, or MOLE_* overrides.
    /// Users choose CLI options through the typed adapter instead.
    public static func safeEnvironment(overrides: [String: String]? = nil, interactive: Bool) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let allowed = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SSH_AUTH_SOCK"]
        var result: [String: String] = [:]
        for key in allowed { if let value = inherited[key], !value.utf8.contains(0) { result[key] = value } }
        result["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        result["LANG"] = "en_US.UTF-8"
        result["SHELL"] = accountShell()
        result["TERM"] = interactive ? "xterm-256color" : "dumb"
        result["HOMEBREW_NO_ANALYTICS"] = "1"
        if interactive { result["COLORTERM"] = "truecolor" }
        // Only trusted, explicit caller data; reject all interpreter startup hooks.
        let overrideKeys = Set(["HOME", "PATH", "LANG", "LC_ALL", "TMPDIR", "NO_COLOR"])
        for (key, value) in overrides ?? [:] where overrideKeys.contains(key) && !value.utf8.contains(0) {
            result[key] = value
        }
        // App Updates opts out of implicit Homebrew self-update, cleanup and
        // unrelated dependent upgrades. These are fixed protective switches,
        // never a general Homebrew environment or script-hook passthrough.
        for key in ["HOMEBREW_NO_AUTO_UPDATE", "HOMEBREW_NO_INSTALL_CLEANUP", "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] {
            if overrides?[key] == "1" { result[key] = "1" }
        }
        let editorPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MoPanelEditor").path
        if overrides?["EDITOR"] == editorPath, FileManager.default.isExecutableFile(atPath: editorPath) {
            result["EDITOR"] = editorPath
        }
        if let language = overrides?["MOPANEL_LANGUAGE"], ["zh-Hant", "en"].contains(language) {
            result["MOPANEL_LANGUAGE"] = language
        }
        return result
    }

    private static func accountShell() -> String {
        #if canImport(Darwin)
        let fallback = "/bin/zsh"
        #else
        let fallback = "/bin/bash"
        #endif
        var record = passwd()
        var pointer: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16384)
        return buffer.withUnsafeMutableBufferPointer { bytes in
            guard let base = bytes.baseAddress, getpwuid_r(getuid(), &record, base, bytes.count, &pointer) == 0,
                  pointer != nil, let shell = record.pw_shell else { return fallback }
            let path = String(cString: shell)
            guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  FileManager.default.isExecutableFile(atPath: path) else { return fallback }
            return path
        }
    }
}

public enum ProcessRunner {
    @MainActor public static func capture(_ request: ProcessRequest, helperURL: URL? = nil) async throws -> ProcessResult {
        let child = ManagedProcess(helperURL: helperURL)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try child.start(request: request)
            let result = await child.wait()
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { @MainActor in child.cancel() }
        }
    }
}
