import Foundation
import Darwin

struct DetectedSSHSession: Equatable, Sendable {
    let destination: String
    let port: Int?
    let identityFile: String?
    let configFile: String?
    let jumpHost: String?
    let controlPath: String?
    let useIPv4: Bool
    let useIPv6: Bool
    let forwardAgent: Bool
    let compressionEnabled: Bool
    let sshOptions: [String]

    func uploadDroppedFiles(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        let session = self
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<[String], Error>
            do {
                let remotePaths = try session.uploadDroppedFilesSync(fileURLs, operation: operation)
                do {
                    try operation.throwIfCancelled()
                    result = .success(remotePaths)
                } catch {
                    session.cleanupUploadedRemotePathsAsync(remotePaths)
                    result = .failure(error)
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                if operation.isCancelled {
                    if case .success(let remotePaths) = result {
                        session.cleanupUploadedRemotePathsAsync(remotePaths)
                    }
                    completion(.failure(TerminalImageTransferExecutionError.cancelled))
                } else {
                    completion(result)
                }
            }
        }
    }

    func uploadDroppedFiles(
        _ fileURLs: [URL],
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        uploadDroppedFiles(
            fileURLs,
            operation: TerminalImageTransferOperation(),
            completion: completion
        )
    }

#if DEBUG
    typealias ProcessOverrideResultForTesting = (
        status: Int32,
        stdout: String,
        stderr: String
    )

    static var runProcessOverrideForTesting: ((
        String,
        [String],
        TimeInterval,
        TerminalImageTransferOperation?
    ) throws -> ProcessOverrideResultForTesting)?

    func uploadDroppedFilesSyncForTesting(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation = TerminalImageTransferOperation()
    ) throws -> [String] {
        try uploadDroppedFilesSync(fileURLs, operation: operation)
    }
#endif

    private func uploadDroppedFilesSync(
        _ fileURLs: [URL],
        operation: TerminalImageTransferOperation
    ) throws -> [String] {
        guard !fileURLs.isEmpty else { return [] }

        var uploadedRemotePaths: [String] = []
        do {
            for localURL in fileURLs {
                try operation.throwIfCancelled()
                let normalizedLocalURL = localURL.standardizedFileURL
                guard normalizedLocalURL.isFileURL else {
                    throw NSError(domain: "cmux.detected-ssh.drop", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "dropped item is not a file URL",
                    ])
                }

                let remotePath = WorkspaceRemoteSessionController.remoteDropPath(for: normalizedLocalURL)
                let result = try Self.runProcess(
                    executable: "/usr/bin/scp",
                    arguments: scpArguments(localPath: normalizedLocalURL.path, remotePath: remotePath),
                    timeout: 45,
                    operation: operation
                )
                guard result.status == 0 else {
                    let detail = Self.bestErrorLine(stderr: result.stderr, stdout: result.stdout) ??
                        "scp exited \(result.status)"
                    throw NSError(domain: "cmux.detected-ssh.drop", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "failed to upload dropped file: \(detail)",
                    ])
                }

                uploadedRemotePaths.append(remotePath)
            }

            return uploadedRemotePaths
        } catch {
            cleanupUploadedRemotePaths(uploadedRemotePaths)
            throw error
        }
    }

    private func scpArguments(localPath: String, remotePath: String) -> [String] {
        var args: [String] = [
            "-q",
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
        ]

        if useIPv4 {
            args.append("-4")
        } else if useIPv6 {
            args.append("-6")
        }
        if forwardAgent {
            args.append("-A")
        }
        if compressionEnabled {
            args.append("-C")
        }
        if let configFile, !configFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-F", configFile]
        }
        if let jumpHost, !jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-J", jumpHost]
        }
        if let port {
            args += ["-P", String(port)]
        }
        if let identityFile, !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        if let controlPath,
           !controlPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !Self.hasSSHOptionKey(sshOptions, key: "ControlPath") {
            args += ["-o", "ControlPath=\(controlPath)"]
        }
        if !Self.hasSSHOptionKey(sshOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        for option in sshOptions {
            args += ["-o", option]
        }

        args += [localPath, "\(Self.scpRemoteDestination(destination)):\(remotePath)"]
        return args
    }

    private func sshArguments(command: String) -> [String] {
        var args: [String] = [
            "-T",
            "-o", "ConnectTimeout=6",
            "-o", "ServerAliveInterval=20",
            "-o", "ServerAliveCountMax=2",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
        ]

        if useIPv4 {
            args.append("-4")
        } else if useIPv6 {
            args.append("-6")
        }
        if forwardAgent {
            args.append("-A")
        }
        if compressionEnabled {
            args.append("-C")
        }
        if let configFile, !configFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-F", configFile]
        }
        if let jumpHost, !jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-J", jumpHost]
        }
        if let port {
            args += ["-p", String(port)]
        }
        if let identityFile, !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-i", identityFile]
        }
        if let controlPath,
           !controlPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !Self.hasSSHOptionKey(sshOptions, key: "ControlPath") {
            args += ["-o", "ControlPath=\(controlPath)"]
        }
        if !Self.hasSSHOptionKey(sshOptions, key: "StrictHostKeyChecking") {
            args += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        for option in sshOptions {
            args += ["-o", option]
        }

        args += [destination, command]
        return args
    }

    private func cleanupUploadedRemotePaths(_ remotePaths: [String]) {
        guard !remotePaths.isEmpty else { return }
        let cleanupScript = "rm -f -- " + remotePaths.map(Self.shellSingleQuoted).joined(separator: " ")
        let cleanupCommand = "sh -c \(Self.shellSingleQuoted(cleanupScript))"
        _ = try? Self.runProcess(
            executable: "/usr/bin/ssh",
            arguments: sshArguments(command: cleanupCommand),
            timeout: 8
        )
    }

    private func cleanupUploadedRemotePathsAsync(_ remotePaths: [String]) {
        guard !remotePaths.isEmpty else { return }
        let session = self
        DispatchQueue.global(qos: .utility).async {
            session.cleanupUploadedRemotePaths(remotePaths)
        }
    }

    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        operation: TerminalImageTransferOperation? = nil
    ) throws -> CommandResult {
#if DEBUG
        if let runProcessOverrideForTesting {
            let result = try runProcessOverrideForTesting(executable, arguments, timeout, operation)
            return CommandResult(status: result.status, stdout: result.stdout, stderr: result.stderr)
        }
#endif

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try operation?.throwIfCancelled()
        try process.run()
        operation?.installCancellationHandler {
            if process.isRunning {
                process.terminate()
            }
        }
        defer { operation?.clearCancellationHandler() }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        func terminateProcessAndWait() {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        if exitSignal.wait(timeout: .now() + timeout) == .timedOut {
            if operation?.isCancelled == true {
                terminateProcessAndWait()
                throw TerminalImageTransferExecutionError.cancelled
            }
            terminateProcessAndWait()
            throw NSError(domain: "cmux.detected-ssh.drop", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "scp timed out",
            ])
        }

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        if operation?.isCancelled == true {
            throw TerminalImageTransferExecutionError.cancelled
        }
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private static func bestErrorLine(stderr: String, stdout: String) -> String? {
        let stderrLine = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        if let stderrLine {
            return stderrLine
        }

        return stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        return options.contains { optionKey($0) == loweredKey }
    }

    private static func optionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    private static func scpRemoteDestination(_ destination: String) -> String {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else { return destination }

        let parts = trimmedDestination.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let userPart: String?
        let hostPart: String
        if parts.count == 2 {
            userPart = String(parts[0])
            hostPart = String(parts[1])
        } else {
            userPart = nil
            hostPart = trimmedDestination
        }

        guard shouldBracketIPv6Literal(hostPart) else {
            return trimmedDestination
        }

        let bracketedHost = "[\(hostPart)]"
        if let userPart {
            return "\(userPart)@\(bracketedHost)"
        }
        return bracketedHost
    }

    private static func shouldBracketIPv6Literal(_ host: String) -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedHost.isEmpty &&
            trimmedHost.contains(":") &&
            !trimmedHost.hasPrefix("[") &&
            !trimmedHost.hasSuffix("]")
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

#if DEBUG
    func scpArgumentsForTesting(localPath: String, remotePath: String) -> [String] {
        scpArguments(localPath: localPath, remotePath: remotePath)
    }
#endif
}

extension DetectedSSHSession {
    init(parsedCommand: ParsedSSHCommand) {
        self.init(
            destination: parsedCommand.destination,
            port: parsedCommand.port,
            identityFile: parsedCommand.identityFile,
            configFile: parsedCommand.configFile,
            jumpHost: parsedCommand.jumpHost,
            controlPath: parsedCommand.controlPath,
            useIPv4: parsedCommand.useIPv4,
            useIPv6: parsedCommand.useIPv6,
            forwardAgent: parsedCommand.forwardAgent,
            compressionEnabled: parsedCommand.compressionEnabled,
            sshOptions: parsedCommand.sshOptions
        )
    }
}

enum TerminalSSHSessionDetector {
#if DEBUG
    static var detectOverrideForTesting: ((String) -> DetectedSSHSession?)?
#endif

    struct ProcessSnapshot: Equatable {
        let pid: Int32
        let pgid: Int32
        let tpgid: Int32
        let tty: String
        let executableName: String
    }

    static func detect(forTTY ttyName: String) -> DetectedSSHSession? {
#if DEBUG
        if let detectOverrideForTesting {
            return detectOverrideForTesting(ttyName)
        }
#endif
        let normalizedTTY = normalizeTTYName(ttyName)
        guard !normalizedTTY.isEmpty else { return nil }
        let processes = processSnapshots(forTTY: normalizedTTY)
        guard !processes.isEmpty else { return nil }

        var argumentsByPID: [Int32: [String]] = [:]
        for process in processes where isForegroundSSHProcess(process, ttyName: normalizedTTY) {
            if let args = commandLineArguments(forPID: process.pid) {
                argumentsByPID[process.pid] = args
            }
        }

        return detectForTesting(
            ttyName: normalizedTTY,
            processes: processes,
            argumentsByPID: argumentsByPID
        )
    }

    static func detectForTesting(
        ttyName: String,
        processes: [ProcessSnapshot],
        argumentsByPID: [Int32: [String]]
    ) -> DetectedSSHSession? {
        let normalizedTTY = normalizeTTYName(ttyName)
        guard !normalizedTTY.isEmpty else { return nil }

        let candidates = processes
            .filter { isForegroundSSHProcess($0, ttyName: normalizedTTY) }
            .sorted { lhs, rhs in
                if lhs.pid != rhs.pid { return lhs.pid > rhs.pid }
                return lhs.pgid > rhs.pgid
            }

        for candidate in candidates {
            guard let arguments = argumentsByPID[candidate.pid],
                  let parsedCommand = SSHCommandParser.parse(arguments: arguments) else {
                continue
            }
            return DetectedSSHSession(parsedCommand: parsedCommand)
        }

        return nil
    }

    private static let psPath = "/bin/ps"

    private static func normalizeTTYName(_ ttyName: String) -> String {
        let trimmed = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let lastComponent = trimmed.split(separator: "/").last {
            return String(lastComponent)
        }
        return trimmed
    }

    private static func isForegroundSSHProcess(_ process: ProcessSnapshot, ttyName: String) -> Bool {
        normalizeTTYName(process.tty) == normalizeTTYName(ttyName) &&
            process.executableName == "ssh" &&
            process.pgid > 0 &&
            process.tpgid > 0 &&
            process.pgid == process.tpgid
    }

    private static func processSnapshots(forTTY ttyName: String) -> [ProcessSnapshot] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: psPath)
        process.arguments = ["-ww", "-t", ttyName, "-o", "pid=,pgid=,tpgid=,tty=,ucomm="]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output
            .split(separator: "\n")
            .compactMap(parseProcessSnapshot)
    }

    private static func parseProcessSnapshot(_ line: Substring) -> ProcessSnapshot? {
        let parts = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
        guard parts.count == 5,
              let pid = Int32(parts[0]),
              let pgid = Int32(parts[1]),
              let tpgid = Int32(parts[2]) else {
            return nil
        }

        return ProcessSnapshot(
            pid: pid,
            pgid: pgid,
            tpgid: tpgid,
            tty: String(parts[3]),
            executableName: String(parts[4]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    private static func commandLineArguments(forPID pid: Int32) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let success = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &size, nil, 0) == 0
        }
        guard success else { return nil }

        return parseKernProcArgs(Array(buffer.prefix(Int(size))))
    }

    private static func parseKernProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }

        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { rawBuffer in
            rawBuffer.copyBytes(from: bytes.prefix(4))
        }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0 else { return nil }

        var index = 4
        while index < bytes.count, bytes[index] != 0 {
            index += 1
        }
        while index < bytes.count, bytes[index] == 0 {
            index += 1
        }

        var arguments: [String] = []
        while index < bytes.count, arguments.count < argc {
            let start = index
            while index < bytes.count, bytes[index] != 0 {
                index += 1
            }
            guard let argument = String(bytes: bytes[start..<index], encoding: .utf8) else {
                return nil
            }
            arguments.append(argument)
            while index < bytes.count, bytes[index] == 0 {
                index += 1
            }
        }

        return arguments.count == argc ? arguments : nil
    }

}
