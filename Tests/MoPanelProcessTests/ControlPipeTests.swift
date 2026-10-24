// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import MoPanelProcess

final class ControlPipeTests: XCTestCase {
    private enum Message { case resize, input, cancel }

    @MainActor private func checkClosedInput(_ message: Message) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MoPanelClosedPipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("fixture-guardian")
        // This private helper never invokes the requested CLI. It proves the
        // read end is already closed while the Process is still alive.
        try Data("#!/bin/sh\nexec 0<&-\nprintf 'CLOSED_READY\\n'\n/bin/sleep 0.3\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let session = ManagedProcess(helperURL: helper)
        var observed = Data(), triggered = false
        defer { session.onOutput = nil; session.cancel() }
        session.onOutput = { bytes in
            observed.append(bytes)
            guard !triggered, String(decoding: observed, as: UTF8.self).contains("CLOSED_READY") else { return }
            triggered = true
            XCTAssertTrue(session.running, "The regression must write before termination is delivered, not after running becomes false")
            switch message {
            case .resize: session.resize(columns: 100, rows: 40)
            case .input: session.send(Data("fixture input\r".utf8))
            case .cancel: session.cancel()
            }
        }
        try session.start(request: .init(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], timeout: 2), interactive: true)
        let result = await session.wait()
        XCTAssertTrue(triggered)
        XCTAssertFalse(session.running)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.cancelled, message == .cancel)
        XCTAssertTrue(result.stdout.isEmpty, "PTY output remains ephemeral")
    }

    @MainActor func testResizeSurvivesClosedPeerWhileSessionStillRunning() async throws { try await checkClosedInput(.resize) }
    @MainActor func testInputSurvivesClosedPeerWhileSessionStillRunning() async throws { try await checkClosedInput(.input) }
    @MainActor func testCancelSurvivesClosedPeerWhileSessionStillRunning() async throws { try await checkClosedInput(.cancel) }

    func testWriterPreservesQueuedOrderAndClosesBeforeLaterWrites() async throws {
        let pipe = Pipe()
        let writer = try ControlPipeWriter(handle: pipe.fileHandleForWriting)
        let reader = Task.detached {
            defer { try? pipe.fileHandleForReading.close() }
            var observed = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = bytes.withUnsafeMutableBytes { read(pipe.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) }
                if count == 0 { return observed }
                if count < 0, errno == EINTR { continue }
                guard count > 0, observed.count + count <= 128 * 1024 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                observed.append(contentsOf: bytes.prefix(count))
            }
        }
        let first = Data(repeating: 0x41, count: 24_000), second = Data(repeating: 0x42, count: 24_000)
        writer.send(first); writer.send(second); writer.close()
        writer.send(Data("must not be delivered".utf8)); writer.close()
        let observed = try await reader.value
        XCTAssertEqual(observed, first + second)
    }

    func testEPIPEPreservesCallingThreadSignalMaskAndPendingState() throws {
        let pipe = Pipe()
        let writer = try ControlPipeWriter(handle: pipe.fileHandleForWriting)
        defer { writer.close() }
        try pipe.fileHandleForReading.close()
        var before = sigset_t(), after = sigset_t(), pendingBefore = sigset_t(), pendingAfter = sigset_t()
        XCTAssertEqual(pthread_sigmask(SIG_SETMASK, nil, &before), 0)
        XCTAssertEqual(sigpending(&pendingBefore), 0)
        XCTAssertEqual(ControlPipeWriter.writeAll(pipe.fileHandleForWriting.fileDescriptor, data: Data("fixture".utf8)), EPIPE)
        XCTAssertEqual(pthread_sigmask(SIG_SETMASK, nil, &after), 0)
        XCTAssertEqual(sigpending(&pendingAfter), 0)
        for number in 1..<NSIG { XCTAssertEqual(sigismember(&before, number), sigismember(&after, number)) }
        XCTAssertEqual(sigismember(&pendingBefore, SIGPIPE), sigismember(&pendingAfter, SIGPIPE))
    }

    #if canImport(Darwin)
    func testDarwinPrivatePipeHasVerifiedDescriptorProtection() throws {
        let pipe = Pipe()
        let writer = try ControlPipeWriter(handle: pipe.fileHandleForWriting)
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        XCTAssertEqual(fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE), 1)
    }
    #endif
}
