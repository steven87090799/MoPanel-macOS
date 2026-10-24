// SPDX-License-Identifier: GPL-3.0-or-later
// Compiled with the actual ManagedProcess.swift by test_control_pipe_sigpipe.py.
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main struct ClosedPipeProbe {
    @MainActor static func main() async throws {
        // Only this disposable executable changes its own disposition. Neither
        // the app nor the XCTest host has its signal behavior changed.
        signal(SIGPIPE, SIG_DFL)
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let mode = CommandLine.arguments[2]
        #if MOPANEL_SAFE_CONTROL_WRITER
        if mode == "pending" { try checkExistingPendingSignal(); return }
        #endif
        let session = ManagedProcess(helperURL: helper)
        var triggered = false, observed = Data()
        session.onOutput = { bytes in
            observed.append(bytes)
            guard !triggered, String(decoding: observed, as: UTF8.self).contains("CLOSED_READY") else { return }
            triggered = true
            print("CONTROL_CLOSED_WHILE_RUNNING=\(session.running)")
            fflush(stdout)
            switch mode {
            case "resize": session.resize(columns: 100, rows: 40)
            case "send": session.send(Data("fixture input\r".utf8))
            case "cancel": session.cancel()
            default: preconditionFailure("Unknown isolated probe mode")
            }
        }
        try session.start(request: .init(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], timeout: 2), interactive: true)
        let result = await session.wait()
        session.onOutput = nil
        guard triggered, !session.running else { exit(42) }
        print("PROBE_SURVIVED mode=\(mode) exit=\(result.exitCode) cancelled=\(result.cancelled)")
    }

    #if MOPANEL_SAFE_CONTROL_WRITER
    private static func checkExistingPendingSignal() throws {
        var blocked = sigset_t(), previous = sigset_t()
        sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE)
        guard pthread_sigmask(SIG_BLOCK, &blocked, &previous) == 0 else { exit(43) }
        defer {
            // This test generated the preexisting signal itself. Consume it
            // before restoring the original mask under SIG_DFL.
            var pending = sigset_t()
            if sigpending(&pending) == 0, sigismember(&pending, SIGPIPE) == 1 {
                var received: Int32 = 0
                _ = sigwait(&blocked, &received)
            }
            _ = pthread_sigmask(SIG_SETMASK, &previous, nil)
        }
        guard pthread_kill(pthread_self(), SIGPIPE) == 0 else { exit(44) }
        var pendingBefore = sigset_t(), maskBefore = sigset_t()
        guard sigpending(&pendingBefore) == 0, sigismember(&pendingBefore, SIGPIPE) == 1,
              pthread_sigmask(SIG_SETMASK, nil, &maskBefore) == 0 else { exit(45) }
        let pipe = Pipe()
        let writer = try ControlPipeWriter(handle: pipe.fileHandleForWriting)
        defer { writer.close() }
        try pipe.fileHandleForReading.close()
        let result = ControlPipeWriter.writeAll(pipe.fileHandleForWriting.fileDescriptor, data: Data("fixture".utf8))
        var pendingAfter = sigset_t(), maskAfter = sigset_t()
        guard result == EPIPE, sigpending(&pendingAfter) == 0, sigismember(&pendingAfter, SIGPIPE) == 1,
              pthread_sigmask(SIG_SETMASK, nil, &maskAfter) == 0,
              (1..<NSIG).allSatisfy({ sigismember(&maskBefore, $0) == sigismember(&maskAfter, $0) }) else { exit(46) }
        print("PENDING_SIGNAL_PRESERVED MASK_RESTORED")
    }
    #endif
}
