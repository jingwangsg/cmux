import XCTest

final class LocalDaemonSessionsCLITests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-sessions-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func bundledCLIPath() throws -> String {
        let appBundleURL = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(
            at: appBundleURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            if item.lastPathComponent == "cmux",
               item.path.contains(".app/Contents/Resources/bin/cmux") {
                return item.path
            }
        }
        throw XCTSkip("Bundled cmux CLI not found in \(appBundleURL.path)")
    }

    private func writeAuthTokenFile() throws -> URL {
        let url = tempDir.appendingPathComponent("locald.auth", isDirectory: false)
        try "test-auth-token\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
        return url
    }

    private func writeOrphan(id: String) throws {
        let base = tempDir.appendingPathComponent(id, isDirectory: false)
        try JSONSerialization.data(withJSONObject: [
            "session_id": id,
            "process_id": 0,
            "created_at": "2026-03-29T00:00:00Z",
            "checkpoint_seq": 0,
            "retained_start_seq": 0,
            "next_seq": 131072,
            "requested_working_directory": "/tmp",
        ]).write(to: base.appendingPathExtension("manifest.json"))
        try Data("orphan".utf8).write(to: base.appendingPathExtension("vtlog"))
        try Data().write(to: base.appendingPathExtension("checkpoint.vt"))
        try Data("{}".utf8).write(to: base.appendingPathExtension("checkpoint.json"))
    }

    private func waitForSocket(_ socket: String) {
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socket), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func rpc(cli: String, socket: String, authTokenFile: URL, method: String, params: [String: Any]) throws -> [String: Any] {
        let jsonData = try JSONSerialization.data(withJSONObject: params)
        let json = String(data: jsonData, encoding: .utf8) ?? "{}"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = [
            "local-daemon", "rpc",
            "--socket", socket,
            "--auth-token-file", authTokenFile.path,
            method,
            json,
        ]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "rpc \(method) failed")
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func runSessionsCommand(cli: String, socket: String, authTokenFile: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = [
            "local-daemon", "sessions",
            "--socket", socket,
            "--auth-token-file", authTokenFile.path,
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func runReplayCommand(cli: String, socket: String, authTokenFile: URL, sessionID: String) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = [
            "local-daemon", "replay",
            "--socket", socket,
            "--auth-token-file", authTokenFile.path,
            "--session", sessionID,
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_sessionsTable_rendersShellSafeReplayHint() {
        let rendered = CMUXCLI.renderLocalDaemonSessionsTableForTesting(payload: [
            "sessions": [
                [
                    "session_id": "orphan-'quoted'",
                    "state": "orphaned",
                    "attachments": [],
                    "next_seq": 4,
                    "working_directory": "/tmp",
                ]
            ]
        ], replaySocketPath: "/tmp/socket-'quoted'.sock", replayAuthTokenFilePath: "/tmp/auth-'quoted'.txt")

        XCTAssertTrue(rendered.contains(
            "cmux local-daemon replay --socket '/tmp/socket-'\\''quoted'\\''.sock' --auth-token-file '/tmp/auth-'\\''quoted'\\''.txt' --session 'orphan-'\\''quoted'\\'''"
        ))
        XCTAssertFalse(rendered.contains("rpc session.replay"))
    }

    func test_sessionsSubcommand_rendersHeaderAndRows() throws {
        let cli = try bundledCLIPath()
        let authTokenFile = try writeAuthTokenFile()
        try writeOrphan(id: "orphan-1")

        let socket = tempDir.appendingPathComponent("daemon.sock").path
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: cli)
        daemon.arguments = [
            "local-daemon", "serve",
            "--socket", socket,
            "--auth-token-file", authTokenFile.path,
            "--session-log-dir", tempDir.path,
        ]
        try daemon.run()
        defer {
            daemon.terminate()
            daemon.waitUntilExit()
        }

        waitForSocket(socket)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket))

        let open = try rpc(
            cli: cli,
            socket: socket,
            authTokenFile: authTokenFile,
            method: "session.open",
            params: [
                "command": "printf ready; sleep 30",
                "cols": 120,
                "rows": 40,
            ]
        )
        XCTAssertNotNil(open["session_id"] as? String)

        let rendered = try runSessionsCommand(cli: cli, socket: socket, authTokenFile: authTokenFile)
        XCTAssertTrue(rendered.contains("SESSION ID"), "header row must be present")
        XCTAssertTrue(rendered.contains("STATE"))
        XCTAssertTrue(rendered.contains("ATTACHED"))
        XCTAssertTrue(rendered.contains("BYTES"))
        XCTAssertTrue(rendered.contains("orphan-1"))
        XCTAssertTrue(rendered.contains("orphaned"))
        XCTAssertTrue(rendered.contains("running"))
        XCTAssertTrue(
            rendered.contains("cmux local-daemon replay --socket '\(socket)' --auth-token-file '\(authTokenFile.path)' --session 'orphan-1'"),
            "orphaned sessions should point at the first-class replay command"
        )
    }

    func test_replaySubcommand_returnsOrphanReplayPayload() throws {
        let cli = try bundledCLIPath()
        let authTokenFile = try writeAuthTokenFile()
        try writeOrphan(id: "orphan-replay")

        let socket = tempDir.appendingPathComponent("daemon.sock").path
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: cli)
        daemon.arguments = [
            "local-daemon", "serve",
            "--socket", socket,
            "--auth-token-file", authTokenFile.path,
            "--session-log-dir", tempDir.path,
        ]
        try daemon.run()
        defer {
            daemon.terminate()
            daemon.waitUntilExit()
        }

        waitForSocket(socket)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket))

        let payload = try runReplayCommand(
            cli: cli,
            socket: socket,
            authTokenFile: authTokenFile,
            sessionID: "orphan-replay"
        )
        XCTAssertEqual(payload["session_id"] as? String, "orphan-replay")
        XCTAssertEqual(payload["eof"] as? Bool, true)
        let tailBase64 = try XCTUnwrap(payload["tail_base64"] as? String)
        XCTAssertEqual(Data(base64Encoded: tailBase64), Data("orphan".utf8))
    }

    func test_sessionsSubcommand_emptyPayloadPrintsPlaceholder() throws {
        let cli = try bundledCLIPath()
        let authTokenFile = try writeAuthTokenFile()
        let socket = tempDir.appendingPathComponent("daemon.sock").path

        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: cli)
        daemon.arguments = [
            "local-daemon", "serve",
            "--socket", socket,
            "--auth-token-file", authTokenFile.path,
            "--session-log-dir", tempDir.path,
        ]
        try daemon.run()
        defer {
            daemon.terminate()
            daemon.waitUntilExit()
        }

        waitForSocket(socket)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket))

        let rendered = try runSessionsCommand(cli: cli, socket: socket, authTokenFile: authTokenFile)
        XCTAssertTrue(rendered.contains("no sessions"))
    }
}
