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

    func test_orphanGC_prunesFilesOlderThanRetention() throws {
        let cli = try bundledCLIPath()
        let authTokenFile = try writeAuthTokenFile(named: "locald.auth")
        let fresh = try writeFakeOrphan(id: "fresh-\(UUID().uuidString.prefix(6))", age: 60)
        let stale = try writeFakeOrphan(id: "stale-\(UUID().uuidString.prefix(6))", age: 14 * 24 * 3600)

        let socket = tempDir.appendingPathComponent("daemon.sock").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = [
            "local-daemon", "serve",
            "--socket", socket,
            "--auth-token-file", authTokenFile.path,
            "--session-log-dir", tempDir.path,
            "--orphan-retention-days", "7",
            "--exit-after-startup-for-testing",
        ]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "daemon should exit cleanly in GC-only mode: " +
                (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        )

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: fresh.manifest.path), "fresh manifest must survive")
        XCTAssertTrue(fm.fileExists(atPath: fresh.log.path), "fresh log must survive")
        XCTAssertFalse(fm.fileExists(atPath: stale.manifest.path), "stale manifest must be pruned")
        XCTAssertFalse(fm.fileExists(atPath: stale.log.path), "stale log must be pruned")
        XCTAssertFalse(fm.fileExists(atPath: stale.checkpointVT.path))
        XCTAssertFalse(fm.fileExists(atPath: stale.checkpointMeta.path))
    }
}
