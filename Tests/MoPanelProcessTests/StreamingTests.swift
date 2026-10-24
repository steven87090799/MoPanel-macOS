import XCTest
import Foundation
@testable import MoPanelProcess

final class StreamingTests: XCTestCase {
    private func helper() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["MOPANEL_GUARDIAN"],
              FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("Set MOPANEL_GUARDIAN to the built helper for real streaming acceptance.")
        }
        return URL(fileURLWithPath: path)
    }

    @MainActor func testSmallStdoutAndStderrArriveWhileChildRemainsRunning() async throws {
        let session = ManagedProcess(helperURL: try helper())
        var output = Data(), errors = Data()
        session.onOutput = { output.append($0) }
        session.onError = { errors.append($0) }
        try session.start(request: ProcessRequest(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '{\"frame\":1}\\n'; printf diagnostic >&2; sleep 8"], timeout: 12, retainsOutput: false))
        let deadline = Date().addingTimeInterval(2)
        while (output.isEmpty || errors.isEmpty) && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "{\"frame\":1}\n", "A watch frame must arrive before EOF or a full 64 KiB buffer.")
        XCTAssertEqual(String(decoding: errors, as: UTF8.self), "diagnostic")
        XCTAssertTrue(session.running, "This must prove streaming, not completed-process capture.")
        session.cancel()
        let result = await session.wait()
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.stdout.isEmpty, "Streaming mode must not retain unbounded history.")
    }

    @MainActor func testPTYPromptWithoutNewlineArrivesBeforeExit() async throws {
        let session = ManagedProcess(helperURL: try helper())
        var output = Data()
        session.onOutput = { output.append($0) }
        try session.start(request: ProcessRequest(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'fixture-prompt> '; sleep 8"], timeout: 12), interactive: true)
        let deadline = Date().addingTimeInterval(2)
        while output.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("fixture-prompt> "), "Interactive prompts cannot wait for newline, EOF or 64 KiB.")
        XCTAssertTrue(session.running)
        session.cancel()
        let result = await session.wait()
        XCTAssertTrue(result.cancelled)
    }
}
