import Foundation
import Combine
import Bonsplit

struct ParsedSSHCommand: Equatable {
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
    let remoteCommandArguments: [String]
    let hasForwardingOrStdioMode: Bool

    var isPlainInteractive: Bool {
        remoteCommandArguments.isEmpty && !hasForwardingOrStdioMode
    }

    var isEligibleForAutoUpgrade: Bool {
        isPlainInteractive
    }
}

enum SSHCommandParser {
    private static let noArgumentFlags = Set("46AaCfGgKkMNnqsTtVvXxYy")
    private static let valueArgumentFlags = Set("BbcDEeFIiJLlmOopQRSWw")
    private static let autoUpgradeBlockingOptionKeys: Set<String> = [
        "dynamicforward",
        "localforward",
        "remoteforward",
        "remotecommand",
        "requesttty",
        "sessiontype",
        "stdioforward",
    ]
    private static let filteredSSHOptionKeys: Set<String> = [
        "batchmode",
        "controlmaster",
        "controlpersist",
        "forkafterauthentication",
        "localcommand",
        "permitlocalcommand",
        "remotecommand",
        "requesttty",
        "sendenv",
        "sessiontype",
        "setenv",
        "stdioforward",
    ]

    static func parse(arguments: [String]) -> ParsedSSHCommand? {
        guard !arguments.isEmpty else { return nil }

        var index = 0
        if let executable = arguments.first?.split(separator: "/").last,
           executable == "ssh" {
            index = 1
        }

        var destination: String?
        var port: Int?
        var identityFile: String?
        var configFile: String?
        var jumpHost: String?
        var controlPath: String?
        var loginName: String?
        var useIPv4 = false
        var useIPv6 = false
        var forwardAgent = false
        var compressionEnabled = false
        var sshOptions: [String] = []
        var remoteCommandArguments: [String] = []
        var hasForwardingOrStdioMode = false

        func markOptionAsBlockingIfNeeded(_ option: Character) {
            switch option {
            case "D", "L", "N", "R", "T", "W", "w":
                hasForwardingOrStdioMode = true
            default:
                break
            }
        }

        func consumeValue(_ value: String, for option: Character) -> Bool {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return false }
            markOptionAsBlockingIfNeeded(option)

            switch option {
            case "p":
                guard let parsedPort = Int(trimmedValue) else { return false }
                port = parsedPort
                return true
            case "i":
                identityFile = trimmedValue
                return true
            case "F":
                configFile = trimmedValue
                return true
            case "J":
                jumpHost = trimmedValue
                return true
            case "S":
                controlPath = trimmedValue
                return true
            case "l":
                loginName = trimmedValue
                return true
            case "o":
                return consumeSSHOption(
                    trimmedValue,
                    port: &port,
                    identityFile: &identityFile,
                    controlPath: &controlPath,
                    jumpHost: &jumpHost,
                    loginName: &loginName,
                    sshOptions: &sshOptions,
                    hasForwardingOrStdioMode: &hasForwardingOrStdioMode
                )
            default:
                return valueArgumentFlags.contains(option)
            }
        }

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                if index < arguments.count {
                    destination = arguments[index]
                    remoteCommandArguments = Array(arguments.dropFirst(index + 1))
                }
                break
            }
            if !argument.hasPrefix("-") || argument == "-" {
                destination = argument
                remoteCommandArguments = Array(arguments.dropFirst(index + 1))
                break
            }

            if argument.count > 2,
               let option = argument.dropFirst().first,
               valueArgumentFlags.contains(option) {
                guard consumeValue(String(argument.dropFirst(2)), for: option) else { return nil }
                index += 1
                continue
            }

            if argument.count == 2,
               let optionCharacter = argument.dropFirst().first,
               valueArgumentFlags.contains(optionCharacter) {
                let nextIndex = index + 1
                guard nextIndex < arguments.count,
                      consumeValue(arguments[nextIndex], for: optionCharacter) else {
                    return nil
                }
                index += 2
                continue
            }

            let flags = Array(argument.dropFirst())
            guard !flags.isEmpty, flags.allSatisfy({ noArgumentFlags.contains($0) }) else {
                return nil
            }
            for flag in flags {
                switch flag {
                case "4":
                    useIPv4 = true
                    useIPv6 = false
                case "6":
                    useIPv6 = true
                    useIPv4 = false
                case "A":
                    forwardAgent = true
                case "C":
                    compressionEnabled = true
                case "N", "T":
                    hasForwardingOrStdioMode = true
                default:
                    break
                }
            }
            index += 1
        }

        guard let destination else { return nil }
        let finalDestination = resolveDestination(destination, loginName: loginName)
        guard !finalDestination.isEmpty else { return nil }

        return ParsedSSHCommand(
            destination: finalDestination,
            port: port,
            identityFile: identityFile,
            configFile: configFile,
            jumpHost: jumpHost,
            controlPath: controlPath,
            useIPv4: useIPv4,
            useIPv6: useIPv6,
            forwardAgent: forwardAgent,
            compressionEnabled: compressionEnabled,
            sshOptions: sshOptions,
            remoteCommandArguments: remoteCommandArguments,
            hasForwardingOrStdioMode: hasForwardingOrStdioMode
        )
    }

    private static func consumeSSHOption(
        _ option: String,
        port: inout Int?,
        identityFile: inout String?,
        controlPath: inout String?,
        jumpHost: inout String?,
        loginName: inout String?,
        sshOptions: inout [String],
        hasForwardingOrStdioMode: inout Bool
    ) -> Bool {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let key = sshOptionKey(trimmed)
        let value = sshOptionValue(trimmed)

        if let key, autoUpgradeBlockingOptionKeys.contains(key) {
            switch key {
            case "requesttty":
                if let value, value.lowercased() == "yes" || value.lowercased() == "force" {
                    break
                } else {
                    hasForwardingOrStdioMode = true
                }
            default:
                hasForwardingOrStdioMode = true
            }
        }

        switch key {
        case "port":
            if let value, let parsedPort = Int(value) {
                port = parsedPort
                return true
            }
            return false
        case "identityfile":
            if let value, !value.isEmpty {
                identityFile = value
                return true
            }
            return false
        case "controlpath":
            if let value, !value.isEmpty {
                controlPath = value
                return true
            }
            return false
        case "proxyjump":
            if let value, !value.isEmpty {
                jumpHost = value
                return true
            }
            return false
        case "user":
            if let value, !value.isEmpty {
                loginName = value
                return true
            }
            return false
        case let key? where filteredSSHOptionKeys.contains(key):
            return true
        case .some, .none:
            sshOptions.append(trimmed)
            return true
        }
    }

    private static func resolveDestination(_ destination: String, loginName: String?) -> String {
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestination.isEmpty else { return "" }
        guard let loginName = loginName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !loginName.isEmpty,
              !trimmedDestination.contains("@") else {
            return trimmedDestination
        }
        return "\(loginName)@\(trimmedDestination)"
    }

    private static func sshOptionKey(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    private static func sshOptionValue(_ option: String) -> String? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let equalIndex = trimmed.firstIndex(of: "=") {
            let value = trimmed[trimmed.index(after: equalIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2 else { return nil }
        let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct RegisteredSSHHost: Codable, Equatable, Identifiable {
    let host: String
    var autoPrepare: Bool

    var id: String { host }
}

enum SSHRegisteredHostSettings {
    static let hostsKey = "sshAutoRemote.registeredHosts"

    static func load(defaults: UserDefaults = .standard) -> [RegisteredSSHHost] {
        guard let data = defaults.data(forKey: hostsKey) else { return [] }
        do {
            let decoded = try JSONDecoder().decode([RegisteredSSHHost].self, from: data)
            return normalized(decoded)
        } catch {
            return []
        }
    }

    static func save(_ hosts: [RegisteredSSHHost], defaults: UserDefaults = .standard) {
        let normalizedHosts = normalized(hosts)
        guard let data = try? JSONEncoder().encode(normalizedHosts) else { return }
        defaults.set(data, forKey: hostsKey)
    }

    static func autoPrepareHosts(defaults: UserDefaults = .standard) -> [RegisteredSSHHost] {
        load(defaults: defaults).filter(\.autoPrepare)
    }

    static func normalizeHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ hosts: [RegisteredSSHHost]) -> [RegisteredSSHHost] {
        var seen = Set<String>()
        var result: [RegisteredSSHHost] = []
        for host in hosts {
            let normalizedHost = normalizeHost(host.host)
            guard !normalizedHost.isEmpty else { continue }
            let key = normalizedHost.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(RegisteredSSHHost(host: normalizedHost, autoPrepare: host.autoPrepare))
        }
        return result
    }
}

enum SSHConfigHostScanner {
    static func hostAliases(configPath: String = NSString(string: "~/.ssh/config").expandingTildeInPath) -> [String] {
        guard let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else { return [] }
        return hostAliases(from: contents)
    }

    static func hostAliases(from config: String) -> [String] {
        var aliases = Set<String>()
        for rawLine in config.split(whereSeparator: \.isNewline) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let keyword = parts.first, keyword.lowercased() == "host" else { continue }
            for alias in parts.dropFirst() {
                let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isExplicitHostAlias(trimmed) else { continue }
                aliases.insert(trimmed)
            }
        }
        return aliases.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func stripComment(_ line: String) -> String {
        guard let index = line.firstIndex(of: "#") else { return line }
        return String(line[..<index])
    }

    private static func isExplicitHostAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty else { return false }
        guard !alias.hasPrefix("!") else { return false }
        return alias.rangeOfCharacter(from: CharacterSet(charactersIn: "*?")) == nil
    }
}

struct SSHHostPreparationStatus: Equatable {
    var state: WorkspaceRemoteDaemonState
    var detail: String?
    var version: String?
    var name: String?
    var capabilities: [String]
    var remotePath: String?
    var proxyEndpoint: BrowserProxyEndpoint?
    var updatedAt: Date

    init(
        state: WorkspaceRemoteDaemonState = .unavailable,
        detail: String? = nil,
        version: String? = nil,
        name: String? = nil,
        capabilities: [String] = [],
        remotePath: String? = nil,
        proxyEndpoint: BrowserProxyEndpoint? = nil,
        updatedAt: Date = Date()
    ) {
        self.state = state
        self.detail = detail
        self.version = version
        self.name = name
        self.capabilities = capabilities
        self.remotePath = remotePath
        self.proxyEndpoint = proxyEndpoint
        self.updatedAt = updatedAt
    }

    init(daemonStatus: WorkspaceRemoteDaemonStatus, proxyEndpoint: BrowserProxyEndpoint? = nil) {
        self.init(
            state: daemonStatus.state,
            detail: daemonStatus.detail,
            version: daemonStatus.version,
            name: daemonStatus.name,
            capabilities: daemonStatus.capabilities,
            remotePath: daemonStatus.remotePath,
            proxyEndpoint: proxyEndpoint
        )
    }

    var daemonStatus: WorkspaceRemoteDaemonStatus {
        WorkspaceRemoteDaemonStatus(
            state: state,
            detail: detail,
            version: version,
            name: name,
            capabilities: capabilities,
            remotePath: remotePath
        )
    }
}

struct PreparedSSHRemote {
    let host: String
    let status: SSHHostPreparationStatus
    let proxyEndpoint: BrowserProxyEndpoint
}

@MainActor
final class SSHHostPreparationStore: ObservableObject {
    static let shared = SSHHostPreparationStore()

    @Published private(set) var registeredHosts: [RegisteredSSHHost]
    @Published private(set) var statuses: [String: SSHHostPreparationStatus] = [:]

    #if DEBUG
    var onStatusChangeForTesting: ((String, SSHHostPreparationStatus) -> Void)?
    #endif

    private let defaults: UserDefaults
    private var controllersByHost: [String: WorkspaceRemoteSessionController] = [:]
    private var didPrepareAutoHostsOnLaunch = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.registeredHosts = SSHRegisteredHostSettings.load(defaults: defaults)
    }

    func reloadRegisteredHostsFromDisk() {
        registeredHosts = SSHRegisteredHostSettings.load(defaults: defaults)
    }

    func status(for host: String) -> SSHHostPreparationStatus? {
        statuses[normalizedHost(host)]
    }

    func addHost(_ host: String, autoPrepare: Bool = false) {
        let normalized = normalizedHost(host)
        guard !normalized.isEmpty else { return }
        if let index = registeredHosts.firstIndex(where: { normalizedHost($0.host).caseInsensitiveCompare(normalized) == .orderedSame }) {
            registeredHosts[index] = RegisteredSSHHost(
                host: registeredHosts[index].host,
                autoPrepare: registeredHosts[index].autoPrepare || autoPrepare
            )
        } else {
            registeredHosts.append(RegisteredSSHHost(host: normalized, autoPrepare: autoPrepare))
        }
        saveRegisteredHosts()
        if autoPrepare {
            prepare(host: normalized)
        }
    }

    func removeHost(_ host: String) {
        let normalized = normalizedHost(host)
        registeredHosts.removeAll { normalizedHost($0.host).caseInsensitiveCompare(normalized) == .orderedSame }
        saveRegisteredHosts()
        statuses.removeValue(forKey: normalized)
        controllersByHost.removeValue(forKey: normalized)?.stop()
    }

    func setAutoPrepare(host: String, enabled: Bool) {
        let normalized = normalizedHost(host)
        guard let index = registeredHosts.firstIndex(where: { normalizedHost($0.host).caseInsensitiveCompare(normalized) == .orderedSame }) else {
            return
        }
        registeredHosts[index] = RegisteredSSHHost(host: registeredHosts[index].host, autoPrepare: enabled)
        saveRegisteredHosts()
        if enabled {
            prepare(host: registeredHosts[index].host)
        }
    }

    func clearRegisteredHosts() {
        for controller in controllersByHost.values {
            controller.stop()
        }
        controllersByHost.removeAll()
        statuses.removeAll()
        registeredHosts = []
        SSHRegisteredHostSettings.save([], defaults: defaults)
    }

    func prepareAutoRegisteredHostsOnAppLaunch() {
        guard !didPrepareAutoHostsOnLaunch else { return }
        didPrepareAutoHostsOnLaunch = true
        reloadRegisteredHostsFromDisk()
        for host in SSHRegisteredHostSettings.autoPrepareHosts(defaults: defaults) {
            prepare(host: host.host)
        }
    }

    func prepare(host: String) {
        let normalized = normalizedHost(host)
        guard !normalized.isEmpty else { return }
        if registeredHosts.contains(where: { normalizedHost($0.host).caseInsensitiveCompare(normalized) == .orderedSame }) == false {
            registeredHosts.append(RegisteredSSHHost(host: normalized, autoPrepare: false))
            saveRegisteredHosts()
        }

        if let existing = statuses[normalized],
           (existing.state == .bootstrapping || existing.state == .ready),
           controllersByHost[normalized] != nil {
            return
        }

        controllersByHost.removeValue(forKey: normalized)?.stop()
        updateStatus(
            SSHHostPreparationStatus(
                state: .bootstrapping,
                detail: "Bootstrapping remote daemon on \(normalized)"
            ),
            for: normalized
        )

        let configuration = WorkspaceRemoteConfiguration(
            destination: normalized,
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            foregroundAuthToken: nil
        )
        let controller = WorkspaceRemoteSessionController(
            workspace: nil,
            configuration: configuration,
            controllerID: UUID(),
            mode: .prewarm(host: normalized)
        ) { [weak self] event in
            Task { @MainActor in
                self?.handleControllerEvent(event, host: normalized)
            }
        }
        controllersByHost[normalized] = controller
        #if DEBUG
        dlog("ssh.prewarm.start host=\(normalized)")
        #endif
        controller.start()
    }

    func preparedRemote(for host: String) -> PreparedSSHRemote? {
        let normalized = normalizedHost(host)
        guard let status = statuses[normalized],
              status.state == .ready,
              let proxyEndpoint = status.proxyEndpoint else {
            return nil
        }
        return PreparedSSHRemote(host: normalized, status: status, proxyEndpoint: proxyEndpoint)
    }

    private func handleControllerEvent(_ event: WorkspaceRemoteSessionControllerEvent, host: String) {
        switch event {
        case .connectionState(let state, let detail):
            guard state == .error else { return }
            var next = statuses[host] ?? SSHHostPreparationStatus()
            next.state = .error
            next.detail = detail
            next.updatedAt = Date()
            updateStatus(next, for: host)
        case .daemonStatus(let daemonStatus):
            let existingEndpoint = statuses[host]?.proxyEndpoint
            updateStatus(
                SSHHostPreparationStatus(daemonStatus: daemonStatus, proxyEndpoint: existingEndpoint),
                for: host
            )
        case .proxyEndpoint(let endpoint):
            var next = statuses[host] ?? SSHHostPreparationStatus()
            next.proxyEndpoint = endpoint
            next.updatedAt = Date()
            updateStatus(next, for: host)
        }
    }

    private func updateStatus(_ status: SSHHostPreparationStatus, for host: String) {
        var next = status
        next.updatedAt = Date()
        statuses[host] = next
        #if DEBUG
        dlog("ssh.prewarm.status host=\(host) state=\(next.state.rawValue) detail=\(next.detail ?? "nil") proxy=\(next.proxyEndpoint.map { "\($0.host):\($0.port)" } ?? "nil")")
        onStatusChangeForTesting?(host, next)
        #endif
    }

    private func saveRegisteredHosts() {
        SSHRegisteredHostSettings.save(registeredHosts, defaults: defaults)
        registeredHosts = SSHRegisteredHostSettings.load(defaults: defaults)
    }

    private func normalizedHost(_ host: String) -> String {
        SSHRegisteredHostSettings.normalizeHost(host)
    }
}
