import XCTest

final class GhosttyVTBridgeTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private func bundledCLIPath() throws -> String {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = fileManager.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux",
                  item.path.contains(".app/Contents/Resources/bin/cmux") else {
                continue
            }
            return item.path
        }

        throw XCTSkip("Bundled cmux CLI not found in \(appBundleURL.path)")
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(
                status: -1,
                stdout: "",
                stderr: String(describing: error),
                timedOut: false
            )
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    func testBundledCLIDebugVTLinkProbe() throws {
        let cliPath = try bundledCLIPath()
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["debug-vt-link-probe"],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
    }

    func testBundledCLIDebugVTCaptureFormatsAlternateScreen() throws {
        let cliPath = try bundledCLIPath()
        let inputBase64 = Data("\u{001B}[?1049hALT-SCREEN\r\n".utf8).base64EncodedString()
        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "debug-vt-capture",
                "--input-base64", inputBase64,
                "--cols", "80",
                "--rows", "24",
                "--sequence", "42",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        guard let data = result.stdout.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected JSON payload, got: \(result.stdout)")
            return
        }

        XCTAssertEqual(payload["sequence"] as? UInt64 ?? UInt64((payload["sequence"] as? NSNumber)?.uint64Value ?? 0), 42)
        XCTAssertEqual(payload["active_screen"] as? String, "alternate")
        XCTAssertEqual(payload["cols"] as? Int ?? (payload["cols"] as? NSNumber)?.intValue, 80)
        XCTAssertEqual(payload["rows"] as? Int ?? (payload["rows"] as? NSNumber)?.intValue, 24)

        let vtText = payload["vt_text"] as? String ?? ""
        XCTAssertTrue(vtText.contains("\u{001B}[?1049h"), vtText)
        XCTAssertTrue(vtText.contains("ALT-SCREEN"), vtText)
    }
}
