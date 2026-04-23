import XCTest

final class LocalDaemonOrphanRecoveryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-ogc-\(UUID().uuidString.prefix(6))", isDirectory: true)
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

    private func writeAuthTokenFile(named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name, isDirectory: false)
        try "test-auth-token\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
        return url
    }

    private func writeFakeOrphan(
        id: String,
        age: TimeInterval
    ) throws -> (manifest: URL, log: URL, checkpointVT: URL, checkpointMeta: URL) {
        let base = tempDir.appendingPathComponent(id, isDirectory: false)
        let manifest = base.appendingPathExtension("manifest.json")
        let log = base.appendingPathExtension("vtlog")
        let checkpointVT = base.appendingPathExtension("checkpoint.vt")
        let checkpointMeta = base.appendingPathExtension("checkpoint.json")

        let json: [String: Any] = [
            "session_id": id,
            "process_id": 0,
            "created_at": "2026-01-01T00:00:00Z",
            "checkpoint_seq": 0,
            "retained_start_seq": 0,
            "next_seq": 0,
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        try Data("log".utf8).write(to: log)
        try Data().write(to: checkpointVT)
        try Data("{}".utf8).write(to: checkpointMeta)

        let ts = Date().addingTimeInterval(-age)
        for url in [manifest, log, checkpointVT, checkpointMeta] {
            try FileManager.default.setAttributes(
                [.modificationDate: ts],
                ofItemAtPath: url.path
            )
        }
        return (manifest, log, checkpointVT, checkpointMeta)
    }

    private func waitForSocket(_ socket: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socket), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "daemon socket must appear within 5s", file: file, line: line)
    }

    private func rpc(
        cli: String,
        socket: String,
        authTokenFile: URL,
        method: String,
        params: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
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
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            file: file,
            line: line
        )
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "RPC output must be a JSON object",
            file: file,
            line: line
        )
    }

    private func replayData(from payload: [String: Any]) -> Data {
        var data = Data()
        for key in ["checkpoint_vt_base64", "tail_base64"] {
            guard let encoded = payload[key] as? String,
                  let chunk = Data(base64Encoded: encoded) else {
                continue
            }
            data.append(chunk)
        }
        return data
    }

    private func runDaemonStartupOnly(cli: String, authTokenFile: URL, retentionDays: String) throws {
        let socket = tempDir.appendingPathComponent("daemon-\(UUID().uuidString.prefix(6)).sock").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = [
            "local-daemon", "serve",
            "--socket", socket,
            "--auth-token-file", authTokenFile.path,
            "--session-log-dir", tempDir.path,
            "--orphan-retention-days", retentionDays,
            "--exit-after-startup-for-testing",
        ]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "daemon should exit cleanly in startup-only mode: " +
                (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        )
    }

    func test_orphanGC_prunesFilesOlderThanRetention() throws {
        let cli = try bundledCLIPath()
        let authTokenFile = try writeAuthTokenFile(named: "locald.auth")
        let fresh = try writeFakeOrphan(id: "fresh-\(UUID().uuidString.prefix(6))", age: 60)
        let stale = try writeFakeOrphan(id: "stale-\(UUID().uuidString.prefix(6))", age: 14 * 24 * 3600)

        try runDaemonStartupOnly(cli: cli, authTokenFile: authTokenFile, retentionDays: "7")

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: fresh.manifest.path), "fresh manifest must survive")
        XCTAssertTrue(fm.fileExists(atPath: fresh.log.path), "fresh log must survive")
        XCTAssertFalse(fm.fileExists(atPath: stale.manifest.path), "stale manifest must be pruned")
        XCTAssertFalse(fm.fileExists(atPath: stale.log.path), "stale log must be pruned")
        XCTAssertFalse(fm.fileExists(atPath: stale.checkpointVT.path))
        XCTAssertFalse(fm.fileExists(atPath: stale.checkpointMeta.path))
    }

    func test_orphanGC_zeroRetentionPrunesImmediately() throws {
        let cli = try bundledCLIPath()
        let authTokenFile = try writeAuthTokenFile(named: "locald.auth")
        let orphan = try writeFakeOrphan(id: "zero-\(UUID().uuidString.prefix(6))", age: 0)

        try runDaemonStartupOnly(cli: cli, authTokenFile: authTokenFile, retentionDays: "0")

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.manifest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.log.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.checkpointVT.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.checkpointMeta.path))
    }

    func test_orphanGC_prunesStaleManifestlessSidecars() throws {
        let cli = try bundledCLIPath()
        let authTokenFile = try writeAuthTokenFile(named: "locald.auth")
        let base = tempDir.appendingPathComponent("sidecar-only-\(UUID().uuidString.prefix(6))", isDirectory: false)
        let log = base.appendingPathExtension("vtlog")
        let checkpointVT = base.appendingPathExtension("checkpoint.vt")
        let checkpointMeta = base.appendingPathExtension("checkpoint.json")
        for url in [log, checkpointVT, checkpointMeta] {
            try Data("stale".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-(14 * 24 * 3600))],
                ofItemAtPath: url.path
            )
        }

        try runDaemonStartupOnly(cli: cli, authTokenFile: authTokenFile, retentionDays: "7")

        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "manifestless stale log must be pruned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointVT.path), "manifestless stale checkpoint VT must be pruned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointMeta.path), "manifestless stale checkpoint metadata must be pruned")
    }

    func test_orphanGC_prunesStaleCorruptManifestArtifacts() throws {
        let cli = try bundledCLIPath()
        let authTokenFile = try writeAuthTokenFile(named: "locald.auth")
        let base = tempDir.appendingPathComponent("corrupt-\(UUID().uuidString.prefix(6))", isDirectory: false)
        let manifest = base.appendingPathExtension("manifest.json")
        let log = base.appendingPathExtension("vtlog")
        try Data("not json".utf8).write(to: manifest)
        try Data("stale".utf8).write(to: log)
        for url in [manifest, log] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-(14 * 24 * 3600))],
                ofItemAtPath: url.path
            )
        }

        try runDaemonStartupOnly(cli: cli, authTokenFile: authTokenFile, retentionDays: "7")

        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path), "stale corrupt manifest must be pruned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "stale corrupt-manifest log must be pruned")
    }

    func test_recoveredGeneratedSessionIdsAreSkippedWhenOpeningNewSession() throws {
        let cli = try bundledCLIPath()
        let authTokenFile = try writeAuthTokenFile(named: "locald.auth")
        _ = try writeFakeOrphan(id: "local-sess-1", age: 60)

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

        let opened = try rpc(
            cli: cli,
            socket: socket,
            authTokenFile: authTokenFile,
            method: "session.open",
            params: [
                "command": "sleep 30",
                "cols": 80,
                "rows": 24,
            ]
        )
        let sessionID = try XCTUnwrap(opened["session_id"] as? String)
        XCTAssertEqual(sessionID, "local-sess-2", "new generated sessions must not collide with recovered orphans")
        defer {
            _ = try? rpc(
                cli: cli,
                socket: socket,
                authTokenFile: authTokenFile,
                method: "session.close",
                params: ["session_id": sessionID]
            )
        }

        _ = try rpc(
            cli: cli,
            socket: socket,
            authTokenFile: authTokenFile,
            method: "session.attach",
            params: [
                "session_id": sessionID,
                "attachment_id": "test-attach",
                "cols": 80,
                "rows": 24,
            ]
        )
    }

    func test_sessionReplay_usesDaemonCreatedArtifactsAfterDaemonRestart() throws {
        let cli = try bundledCLIPath()
        let authTokenFile = try writeAuthTokenFile(named: "locald.auth")
        let firstSocket = tempDir.appendingPathComponent("daemon-first.sock").path
        let secondSocket = tempDir.appendingPathComponent("daemon-second.sock").path
        let token = "daemon-created-\(UUID().uuidString)"
        let tokenData = Data(token.utf8)

        func startDaemon(socket: String) throws -> Process {
            let daemon = Process()
            daemon.executableURL = URL(fileURLWithPath: cli)
            daemon.arguments = [
                "local-daemon", "serve",
                "--socket", socket,
                "--auth-token-file", authTokenFile.path,
                "--session-log-dir", tempDir.path,
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["CMUX_LOCAL_DAEMON_CHECKPOINT_DEBOUNCE_MS"] = "0"
            daemon.environment = environment
            try daemon.run()
            waitForSocket(socket)
            return daemon
        }

        var daemon = try startDaemon(socket: firstSocket)
        let opened = try rpc(
            cli: cli,
            socket: firstSocket,
            authTokenFile: authTokenFile,
            method: "session.open",
            params: [
                "command": "printf \(token); sleep 30",
                "cols": 80,
                "rows": 24,
            ]
        )
        let sessionID = try XCTUnwrap(opened["session_id"] as? String)

        let liveReplayDeadline = Date().addingTimeInterval(5)
        var sawLiveReplay = false
        while Date() < liveReplayDeadline {
            let replay = try rpc(
                cli: cli,
                socket: firstSocket,
                authTokenFile: authTokenFile,
                method: "session.replay",
                params: ["session_id": sessionID]
            )
            if replayData(from: replay).range(of: tokenData) != nil {
                sawLiveReplay = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(sawLiveReplay, "daemon-created replay artifacts must contain the session output before restart")

        daemon.terminate()
        daemon.waitUntilExit()

        daemon = try startDaemon(socket: secondSocket)
        defer {
            _ = try? rpc(
                cli: cli,
                socket: secondSocket,
                authTokenFile: authTokenFile,
                method: "session.close",
                params: ["session_id": sessionID]
            )
            daemon.terminate()
            daemon.waitUntilExit()
        }

        let recoveredReplay = try rpc(
            cli: cli,
            socket: secondSocket,
            authTokenFile: authTokenFile,
            method: "session.replay",
            params: ["session_id": sessionID]
        )
        XCTAssertEqual(recoveredReplay["eof"] as? Bool, true)
        XCTAssertNotNil(
            replayData(from: recoveredReplay).range(of: tokenData),
            "recovered replay should use daemon-created checkpoint/log artifacts, not handcrafted fixtures"
        )
    }

    func test_sessionClose_prunesRecoveredSidecarFiles() throws {
        let cli = try bundledCLIPath()
        let authTokenFile = try writeAuthTokenFile(named: "locald.auth")
        let orphanID = "close-\(UUID().uuidString.prefix(6))"
        let orphan = try writeFakeOrphan(id: orphanID, age: 60)

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

        _ = try rpc(
            cli: cli,
            socket: socket,
            authTokenFile: authTokenFile,
            method: "session.close",
            params: ["session_id": orphanID]
        )

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: orphan.manifest.path), "close must remove recovered manifest")
        XCTAssertFalse(fm.fileExists(atPath: orphan.log.path), "close must remove recovered VT log")
        XCTAssertFalse(fm.fileExists(atPath: orphan.checkpointVT.path), "close must remove recovered checkpoint VT")
        XCTAssertFalse(fm.fileExists(atPath: orphan.checkpointMeta.path), "close must remove recovered checkpoint metadata")
    }

    func test_sessionReplay_returnsCheckpointAndTailForOrphans() throws {
        let cli = try bundledCLIPath()
        let authTokenFile = try writeAuthTokenFile(named: "locald.auth")
        let id = "replay-\(UUID().uuidString.prefix(6))"
        let base = tempDir.appendingPathComponent(id, isDirectory: false)
        let manifest = base.appendingPathExtension("manifest.json")
        let log = base.appendingPathExtension("vtlog")
        let checkpointVT = base.appendingPathExtension("checkpoint.vt")
        let checkpointMeta = base.appendingPathExtension("checkpoint.json")

        let logBytes = Data("hello from the orphan\n".utf8)
        let checkpointBytes = Data("\u{1B}[2J\u{1B}[Hrestored".utf8)
        try JSONSerialization.data(withJSONObject: [
            "session_id": id,
            "process_id": 1234,
            "created_at": "2026-01-01T00:00:00Z",
            "checkpoint_seq": 3,
            "retained_start_seq": 3,
            "next_seq": UInt64(3 + logBytes.count),
            "requested_command": "/bin/zsh",
        ]).write(to: manifest)
        try logBytes.write(to: log)
        try checkpointBytes.write(to: checkpointVT)
        try JSONSerialization.data(withJSONObject: [
            "sequence": 3,
            "cols": 80,
            "rows": 24,
        ]).write(to: checkpointMeta)

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

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socket), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "daemon socket must appear within 5s")

        let rpc = Process()
        rpc.executableURL = URL(fileURLWithPath: cli)
        rpc.arguments = [
            "local-daemon", "rpc",
            "--socket", socket,
            "--auth-token-file", authTokenFile.path,
            "session.replay",
            "{\"session_id\":\"\(id)\"}",
        ]
        let out = Pipe()
        let err = Pipe()
        rpc.standardOutput = out
        rpc.standardError = err
        try rpc.run()
        rpc.waitUntilExit()
        XCTAssertEqual(
            rpc.terminationStatus,
            0,
            String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )

        let data = out.fileHandleForReading.readDataToEndOfFile()
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["session_id"] as? String, id)
        XCTAssertEqual(json["eof"] as? Bool, true)
        XCTAssertEqual(json["checkpoint_cols"] as? Int, 80)
        XCTAssertEqual(json["checkpoint_rows"] as? Int, 24)

        let checkpointB64 = try XCTUnwrap(json["checkpoint_vt_base64"] as? String)
        XCTAssertEqual(Data(base64Encoded: checkpointB64), checkpointBytes)

        let tailB64 = try XCTUnwrap(json["tail_base64"] as? String)
        XCTAssertEqual(Data(base64Encoded: tailB64), logBytes)
    }
}
