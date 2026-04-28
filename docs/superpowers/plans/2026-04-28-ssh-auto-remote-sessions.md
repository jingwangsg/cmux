# SSH Auto Remote Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make SSH a per-terminal capability: passive `ssh host` detection enhances ordinary SSH panes by default, while a default-off shell hook can upgrade simple interactive SSH commands into daemon-managed recoverable remote sessions.

**Architecture:** Extract SSH command parsing into a reusable parser, add surface-level remote attachment state, route passive detection through a debounced coordinator, then add an opt-in shell hook and CLI helper for pre-execution upgrades. Existing `cmux ssh ...` and `workspace.remote.*` remain compatible while new code moves browser/file-drop decisions toward surface attachments.

**Tech Stack:** Swift/AppKit/SwiftUI, Ghostty shell integration wrappers, existing cmux socket JSON-RPC, `WorkspaceRemoteSessionController`, `TerminalSSHSessionDetector`, `CmuxSettingsFileStore`, GitHub Actions or VM-based tests, tagged `scripts/reload.sh` builds.

---

## Repository Rules For This Plan

- Do not run e2e, UI, or Python socket tests locally.
- Do not launch an untagged `cmux DEV.app`.
- After code changes, run `./scripts/reload.sh --tag ssh-auto-remote-sessions` and provide the printed app path if handing the build to the user.
- For regression tests, use the two-commit policy when practical: first commit adds the failing test, second commit adds the fix.
- All user-facing Swift strings must use `String(localized:defaultValue:)` and be added to `Resources/Localizable.xcstrings` for English and Japanese.

## File Structure

- Create `Sources/SSHCommandParsing.swift`: reusable SSH argv parser and classification for passive detection and shell auto-upgrade.
- Modify `Sources/TerminalSSHSessionDetector.swift`: delegate existing foreground-process parsing to `SSHCommandParser`.
- Create `Sources/TerminalRemoteAttachment.swift`: value types for per-surface remote attachment state and payload generation.
- Modify `Sources/Workspace.swift`: store surface attachments, debounce passive SSH detection, bridge detected attachments to remote daemon bootstrap/proxy state, and route file drop/browser proxy decisions from source surface.
- Modify `Sources/TerminalController.swift`: expose surface remote attachment payloads and add the `surface.ssh_upgrade` socket method used by the shell hook.
- Modify `CLI/cmux.swift`: add `ssh-upgrade` helper command and shared command-line help.
- Modify `Sources/GhosttyTerminalView.swift`: export SSH auto-remote env flags and load shell hook support in managed terminal environments.
- Modify shell integration resources under `Resources/shell-integration/`: add zsh and bash pre-exec hooks for default-off SSH upgrade.
- Modify `Sources/cmuxApp.swift`: add settings model and Settings UI toggles.
- Modify `Sources/KeyboardShortcutSettingsFileStore.swift`: support `terminal.passiveSSHEnhancement` and `terminal.upgradeInteractiveSSHCommands` in `~/.config/cmux/settings.json`.
- Modify `web/data/cmux-settings.schema.json`: document the new terminal settings for editor completion and validation.
- Modify `Resources/Localizable.xcstrings`: add UI/status strings.
- Add tests in `cmuxTests/WorkspaceRemoteConnectionTests.swift`, `cmuxTests/GhosttyConfigTests.swift`, and `tests_v2/test_ssh_auto_remote_sessions.py`.

---

### Task 1: Extract Reusable SSH Command Parsing

**Files:**
- Create: `Sources/SSHCommandParsing.swift`
- Modify: `Sources/TerminalSSHSessionDetector.swift`
- Test: `cmuxTests/WorkspaceRemoteConnectionTests.swift`

- [ ] **Step 1: Add failing parser coverage**

Append tests to `WorkspaceRemoteConnectionTests` near the existing `TerminalSSHSessionDetector.detectForTesting` tests:

```swift
func testSSHCommandParserClassifiesPlainInteractiveSSHForUpgrade() throws {
    let parsed = try XCTUnwrap(SSHCommandParser.parse(arguments: ["ssh", "-p", "2222", "-i", "~/.ssh/id_ed25519", "devbox"]))
    XCTAssertEqual(parsed.destination, "devbox")
    XCTAssertEqual(parsed.port, 2222)
    XCTAssertEqual(parsed.identityFile, "~/.ssh/id_ed25519")
    XCTAssertTrue(parsed.isPlainInteractive)
    XCTAssertTrue(parsed.isEligibleForAutoUpgrade)
}

func testSSHCommandParserRejectsRemoteCommandsForUpgrade() throws {
    let parsed = try XCTUnwrap(SSHCommandParser.parse(arguments: ["ssh", "devbox", "uname", "-a"]))
    XCTAssertEqual(parsed.destination, "devbox")
    XCTAssertFalse(parsed.isPlainInteractive)
    XCTAssertFalse(parsed.isEligibleForAutoUpgrade)
}

func testSSHCommandParserRejectsForwardingAndStdioModesForUpgrade() throws {
    for args in [
        ["ssh", "-N", "devbox"],
        ["ssh", "-L", "8080:localhost:80", "devbox"],
        ["ssh", "-R", "9000:localhost:9000", "devbox"],
        ["ssh", "-D", "1080", "devbox"],
        ["ssh", "-W", "localhost:22", "jumpbox"],
    ] {
        let parsed = try XCTUnwrap(SSHCommandParser.parse(arguments: args), "args=\(args)")
        XCTAssertFalse(parsed.isEligibleForAutoUpgrade, "args=\(args)")
    }
}

func testTerminalSSHSessionDetectorUsesSharedParser() throws {
    let session = TerminalSSHSessionDetector.detectForTesting(
        ttyName: "ttys010",
        processes: [
            .init(pid: 200, pgid: 200, tpgid: 200, tty: "ttys010", executableName: "ssh"),
        ],
        argumentsByPID: [
            200: ["/usr/bin/ssh", "-J", "jump", "-o", "ControlPath=/tmp/cmux-%C", "devbox"],
        ]
    )
    XCTAssertEqual(session?.destination, "devbox")
    XCTAssertEqual(session?.jumpHost, "jump")
    XCTAssertEqual(session?.controlPath, "/tmp/cmux-%C")
}
```

- [ ] **Step 2: Do not run local tests**

Record expected validation path in the PR notes:

```bash
gh workflow run test-unit.yml
```

Expected: the parser tests fail on CI or VM because `SSHCommandParser` is not defined.

- [ ] **Step 3: Create `Sources/SSHCommandParsing.swift`**

Add this file:

```swift
import Foundation

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
        "remotecommand",
        "sessiontype",
        "stdioforward",
        "localforward",
        "remoteforward",
        "dynamicforward",
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

        func consumeValue(_ value: String, for option: Character) -> Bool {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return false }
            switch option {
            case "p":
                guard let parsedPort = Int(trimmedValue) else { return false }
                port = parsedPort
            case "i":
                identityFile = trimmedValue
            case "F":
                configFile = trimmedValue
            case "J":
                jumpHost = trimmedValue
            case "S":
                controlPath = trimmedValue
            case "l":
                loginName = trimmedValue
            case "W", "L", "R", "D":
                hasForwardingOrStdioMode = true
            case "o":
                consumeSSHOption(
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
                break
            }
            return true
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
               let option = argument.dropFirst().first,
               valueArgumentFlags.contains(option) {
                let nextIndex = index + 1
                guard nextIndex < arguments.count,
                      consumeValue(arguments[nextIndex], for: option) else { return nil }
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
                case "N":
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
    ) {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = sshOptionKey(trimmed)
        let value = sshOptionValue(trimmed)
        if autoUpgradeBlockingOptionKeys.contains(key) {
            hasForwardingOrStdioMode = true
        }
        switch key {
        case "port":
            if let value, let parsedPort = Int(value) { port = parsedPort }
        case "identityfile":
            if let value, !value.isEmpty { identityFile = value }
        case "controlpath":
            if let value, !value.isEmpty { controlPath = value }
        case "proxyjump":
            if let value, !value.isEmpty { jumpHost = value }
        case "user":
            if let value, !value.isEmpty { loginName = value }
        default:
            if !filteredSSHOptionKeys.contains(key) {
                sshOptions.append(trimmed)
            }
        }
    }

    private static func sshOptionKey(_ option: String) -> String {
        option.split(whereSeparator: { $0 == "=" || $0.isWhitespace }).first.map(String.init)?.lowercased() ?? ""
    }

    private static func sshOptionValue(_ option: String) -> String? {
        if let equals = option.firstIndex(of: "=") {
            return String(option[option.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let parts = option.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2 else { return nil }
        return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveDestination(_ destination: String, loginName: String?) -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let loginName, !loginName.isEmpty, !trimmed.contains("@") else { return trimmed }
        return "\(loginName)@\(trimmed)"
    }
}
```

- [ ] **Step 4: Delegate `TerminalSSHSessionDetector` to the shared parser**

Replace the private parser body in `TerminalSSHSessionDetector.parseSSHCommandLine(_:)` with:

```swift
private static func parseSSHCommandLine(_ arguments: [String]) -> DetectedSSHSession? {
    guard let parsed = SSHCommandParser.parse(arguments: arguments) else { return nil }
    return DetectedSSHSession(
        destination: parsed.destination,
        port: parsed.port,
        identityFile: parsed.identityFile,
        configFile: parsed.configFile,
        jumpHost: parsed.jumpHost,
        controlPath: parsed.controlPath,
        useIPv4: parsed.useIPv4,
        useIPv6: parsed.useIPv6,
        forwardAgent: parsed.forwardAgent,
        compressionEnabled: parsed.compressionEnabled,
        sshOptions: parsed.sshOptions
    )
}
```

Delete the duplicated private parser constants and helper methods that are no longer used in `TerminalSSHSessionDetector`.

- [ ] **Step 5: Commit parser extraction**

```bash
git add Sources/SSHCommandParsing.swift Sources/TerminalSSHSessionDetector.swift cmuxTests/WorkspaceRemoteConnectionTests.swift
git commit -m "refactor: share ssh command parsing"
```

---

### Task 2: Add SSH Auto-Remote Settings

**Files:**
- Modify: `Sources/cmuxApp.swift`
- Modify: `Sources/KeyboardShortcutSettingsFileStore.swift`
- Modify: `web/data/cmux-settings.schema.json`
- Modify: `Resources/Localizable.xcstrings`
- Test: `cmuxTests/GhosttyConfigTests.swift`

- [ ] **Step 1: Add failing settings tests**

Append to `GhosttyConfigTests` near other settings tests:

```swift
func testSSHAutoRemoteSettingsDefaults() {
    let defaults = UserDefaults(suiteName: "SSHAutoRemoteSettings.Defaults.\(UUID().uuidString)")!
    defaults.removeObject(forKey: SSHAutoRemoteSettings.passiveEnhancementKey)
    defaults.removeObject(forKey: SSHAutoRemoteSettings.upgradeInteractiveCommandsKey)
    XCTAssertTrue(SSHAutoRemoteSettings.passiveEnhancementEnabled(defaults: defaults))
    XCTAssertFalse(SSHAutoRemoteSettings.upgradeInteractiveCommandsEnabled(defaults: defaults))
}

func testSSHAutoRemoteSettingsReadStoredValues() {
    let defaults = UserDefaults(suiteName: "SSHAutoRemoteSettings.Stored.\(UUID().uuidString)")!
    defaults.set(false, forKey: SSHAutoRemoteSettings.passiveEnhancementKey)
    defaults.set(true, forKey: SSHAutoRemoteSettings.upgradeInteractiveCommandsKey)
    XCTAssertFalse(SSHAutoRemoteSettings.passiveEnhancementEnabled(defaults: defaults))
    XCTAssertTrue(SSHAutoRemoteSettings.upgradeInteractiveCommandsEnabled(defaults: defaults))
}
```

- [ ] **Step 2: Add settings model**

In `Sources/cmuxApp.swift`, after `TerminalScrollBarSettings`, add:

```swift
enum SSHAutoRemoteSettings {
    static let passiveEnhancementKey = "sshAutoRemote.passiveEnhancement"
    static let defaultPassiveEnhancement = true
    static let upgradeInteractiveCommandsKey = "sshAutoRemote.upgradeInteractiveCommands"
    static let defaultUpgradeInteractiveCommands = false

    static func passiveEnhancementEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: passiveEnhancementKey) == nil
            ? defaultPassiveEnhancement
            : defaults.bool(forKey: passiveEnhancementKey)
    }

    static func upgradeInteractiveCommandsEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: upgradeInteractiveCommandsKey) == nil
            ? defaultUpgradeInteractiveCommands
            : defaults.bool(forKey: upgradeInteractiveCommandsKey)
    }
}
```

- [ ] **Step 3: Add Settings UI state**

In `SettingsView`, add properties next to terminal settings:

```swift
@AppStorage(SSHAutoRemoteSettings.passiveEnhancementKey)
private var sshPassiveEnhancement = SSHAutoRemoteSettings.defaultPassiveEnhancement
@AppStorage(SSHAutoRemoteSettings.upgradeInteractiveCommandsKey)
private var sshUpgradeInteractiveCommands = SSHAutoRemoteSettings.defaultUpgradeInteractiveCommands
```

In the Terminal settings card, add two localized rows:

```swift
SettingsCardRow(
    configurationReview: .toggle,
    String(localized: "settings.terminal.sshPassiveEnhancement", defaultValue: "Detect SSH sessions"),
    subtitle: String(localized: "settings.terminal.sshPassiveEnhancement.subtitle", defaultValue: "When a terminal runs ssh, cmux can attach remote browser and file-transfer support without changing the SSH shell.")
) {
    Toggle("", isOn: $sshPassiveEnhancement)
        .labelsHidden()
}

SettingsCardDivider()

SettingsCardRow(
    configurationReview: .toggle,
    String(localized: "settings.terminal.sshUpgradeInteractiveCommands", defaultValue: "Upgrade interactive SSH commands"),
    subtitle: String(localized: "settings.terminal.sshUpgradeInteractiveCommands.subtitle", defaultValue: "When enabled, simple interactive ssh commands can become recoverable remote sessions before OpenSSH starts.")
) {
    Toggle("", isOn: $sshUpgradeInteractiveCommands)
        .labelsHidden()
}
```

- [ ] **Step 4: Add settings.json support**

In `CmuxSettingsFileStore.supportedSettingsJSONPaths`, add:

```swift
"terminal.passiveSSHEnhancement",
"terminal.upgradeInteractiveSSHCommands",
```

In `resolveTerminalSection(_:)`, add:

```swift
if let value = jsonBool(section["passiveSSHEnhancement"]) {
    snapshot.managedUserDefaults[SSHAutoRemoteSettings.passiveEnhancementKey] = .bool(value)
}
if let value = jsonBool(section["upgradeInteractiveSSHCommands"]) {
    snapshot.managedUserDefaults[SSHAutoRemoteSettings.upgradeInteractiveCommandsKey] = .bool(value)
}
```

In the default template terminal section, add:

```swift
"passiveSSHEnhancement": SSHAutoRemoteSettings.defaultPassiveEnhancement,
"upgradeInteractiveSSHCommands": SSHAutoRemoteSettings.defaultUpgradeInteractiveCommands,
```

In `web/data/cmux-settings.schema.json`, add these properties under `properties.terminal.properties`:

```json
"passiveSSHEnhancement": {
  "type": "boolean",
  "default": true,
  "description": "Detect ordinary ssh sessions in terminal panes and attach remote browser/file-transfer support without changing the SSH shell."
},
"upgradeInteractiveSSHCommands": {
  "type": "boolean",
  "default": false,
  "description": "Upgrade simple interactive ssh commands into recoverable daemon-managed remote sessions before OpenSSH starts."
}
```

- [ ] **Step 5: Add localization entries**

Add these keys to `Resources/Localizable.xcstrings`:

```json
"settings.terminal.sshPassiveEnhancement" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Detect SSH sessions" } },
    "ja" : { "stringUnit" : { "state" : "translated", "value" : "SSH セッションを検出" } }
  }
},
"settings.terminal.sshPassiveEnhancement.subtitle" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "When a terminal runs ssh, cmux can attach remote browser and file-transfer support without changing the SSH shell." } },
    "ja" : { "stringUnit" : { "state" : "translated", "value" : "ターミナルで ssh を実行すると、SSH シェルを変更せずにリモートブラウザとファイル転送のサポートを追加できます。" } }
  }
},
"settings.terminal.sshUpgradeInteractiveCommands" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Upgrade interactive SSH commands" } },
    "ja" : { "stringUnit" : { "state" : "translated", "value" : "対話的な SSH コマンドをアップグレード" } }
  }
},
"settings.terminal.sshUpgradeInteractiveCommands.subtitle" : {
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "When enabled, simple interactive ssh commands can become recoverable remote sessions before OpenSSH starts." } },
    "ja" : { "stringUnit" : { "state" : "translated", "value" : "有効にすると、単純な対話的 ssh コマンドを OpenSSH 起動前に復元可能なリモートセッションにできます。" } }
  }
}
```

- [ ] **Step 6: Commit settings**

```bash
git add Sources/cmuxApp.swift Sources/KeyboardShortcutSettingsFileStore.swift web/data/cmux-settings.schema.json Resources/Localizable.xcstrings cmuxTests/GhosttyConfigTests.swift
git commit -m "feat: add ssh auto remote settings"
```

---

### Task 3: Add Surface Remote Attachment State

**Files:**
- Create: `Sources/TerminalRemoteAttachment.swift`
- Modify: `Sources/Workspace.swift`
- Modify: `Sources/TerminalController.swift`
- Test: `cmuxTests/WorkspaceRemoteConnectionTests.swift`

- [ ] **Step 1: Add failing attachment payload tests**

Append to `WorkspaceRemoteConnectionTests`:

```swift
func testDetectedSSHAttachmentPayloadIsNotRecoverable() throws {
    let attachment = TerminalRemoteAttachment.detectedSSH(.init(
        destination: "devbox",
        displayTarget: "devbox",
        port: 2222,
        identityFile: "/Users/me/.ssh/id",
        sshOptions: ["ProxyJump=jump"],
        transportKey: "ssh:devbox:2222",
        daemonState: .unavailable
    ))
    let payload = attachment.payload()
    XCTAssertEqual(payload["kind"] as? String, "detected_ssh")
    XCTAssertEqual(payload["destination"] as? String, "devbox")
    XCTAssertEqual(payload["recoverable"] as? Bool, false)
}

func testWorkspaceStoresSurfaceRemoteAttachment() throws {
    let workspace = Workspace(name: "Test")
    let panel = TerminalPanel()
    workspace.panels[panel.id] = panel
    workspace.setRemoteAttachment(
        .detectedSSH(.init(
            destination: "devbox",
            displayTarget: "devbox",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            transportKey: "ssh:devbox",
            daemonState: .unavailable
        )),
        for: panel.id
    )
    XCTAssertEqual(workspace.remoteAttachment(for: panel.id)?.payload()["kind"] as? String, "detected_ssh")
}
```

- [ ] **Step 2: Create attachment types**

Add `Sources/TerminalRemoteAttachment.swift`:

```swift
import Foundation

enum TerminalRemoteDaemonState: Equatable {
    case unavailable
    case bootstrapping(detail: String?)
    case ready(version: String?, remotePath: String?)
    case error(detail: String)

    func payload() -> [String: Any] {
        switch self {
        case .unavailable:
            return ["state": "unavailable"]
        case .bootstrapping(let detail):
            return ["state": "bootstrapping", "detail": detail ?? NSNull()]
        case .ready(let version, let remotePath):
            return ["state": "ready", "version": version ?? NSNull(), "remote_path": remotePath ?? NSNull()]
        case .error(let detail):
            return ["state": "error", "detail": detail]
        }
    }
}

struct DetectedSSHAttachment: Equatable {
    let destination: String
    let displayTarget: String
    let port: Int?
    let identityFile: String?
    let sshOptions: [String]
    let transportKey: String
    var daemonState: TerminalRemoteDaemonState
}

struct ManagedRemoteAttachment: Equatable {
    let destination: String
    let displayTarget: String
    let transportKey: String
    let sessionID: String?
    let relayPort: Int?
    var daemonState: TerminalRemoteDaemonState
}

enum TerminalRemoteAttachment: Equatable {
    case detectedSSH(DetectedSSHAttachment)
    case managedRemote(ManagedRemoteAttachment)

    var recoverable: Bool {
        switch self {
        case .detectedSSH:
            return false
        case .managedRemote:
            return true
        }
    }

    var transportKey: String {
        switch self {
        case .detectedSSH(let attachment):
            return attachment.transportKey
        case .managedRemote(let attachment):
            return attachment.transportKey
        }
    }

    func payload() -> [String: Any] {
        switch self {
        case .detectedSSH(let attachment):
            return [
                "kind": "detected_ssh",
                "destination": attachment.destination,
                "display_target": attachment.displayTarget,
                "port": attachment.port ?? NSNull(),
                "has_identity_file": attachment.identityFile != nil,
                "has_ssh_options": !attachment.sshOptions.isEmpty,
                "transport_key": attachment.transportKey,
                "recoverable": false,
                "daemon": attachment.daemonState.payload(),
            ]
        case .managedRemote(let attachment):
            return [
                "kind": "managed_remote",
                "destination": attachment.destination,
                "display_target": attachment.displayTarget,
                "session_id": attachment.sessionID ?? NSNull(),
                "relay_port": attachment.relayPort ?? NSNull(),
                "transport_key": attachment.transportKey,
                "recoverable": true,
                "daemon": attachment.daemonState.payload(),
            ]
        }
    }
}
```

- [ ] **Step 3: Store attachments in `Workspace`**

Add to `Workspace` near other per-panel state:

```swift
@Published private(set) var remoteAttachmentsByPanelId: [UUID: TerminalRemoteAttachment] = [:]
```

Add methods:

```swift
func remoteAttachment(for panelId: UUID) -> TerminalRemoteAttachment? {
    remoteAttachmentsByPanelId[panelId]
}

func setRemoteAttachment(_ attachment: TerminalRemoteAttachment?, for panelId: UUID) {
    if let attachment {
        remoteAttachmentsByPanelId[panelId] = attachment
    } else {
        remoteAttachmentsByPanelId.removeValue(forKey: panelId)
    }
}

func remoteAttachmentPayload(for panelId: UUID) -> [String: Any]? {
    remoteAttachmentsByPanelId[panelId]?.payload()
}
```

When removing a panel in close/detach paths, also remove `remoteAttachmentsByPanelId[panelId]`.

- [ ] **Step 4: Add socket payload field**

Where terminal surface payloads are assembled in `TerminalController`, include:

```swift
if let remoteAttachment = workspace.remoteAttachmentPayload(for: panel.id) {
    payload["remote_attachment"] = remoteAttachment
}
```

- [ ] **Step 5: Commit attachment model**

```bash
git add Sources/TerminalRemoteAttachment.swift Sources/Workspace.swift Sources/TerminalController.swift cmuxTests/WorkspaceRemoteConnectionTests.swift
git commit -m "feat: add terminal remote attachment state"
```

---

### Task 4: Implement Passive SSH Detection

**Files:**
- Modify: `Sources/Workspace.swift`
- Modify: `Sources/TerminalSSHSessionDetector.swift`
- Modify: `Sources/TerminalImageTransfer.swift`
- Test: `cmuxTests/WorkspaceRemoteConnectionTests.swift`

- [ ] **Step 1: Add failing passive detection test**

Add a test with an override hook so it does not inspect real system processes:

```swift
func testWorkspaceUpdatesDetectedSSHAttachmentFromSurfaceTTY() throws {
    let workspace = Workspace(name: "Test")
    let panel = TerminalPanel()
    workspace.panels[panel.id] = panel
    workspace.surfaceTTYNames[panel.id] = "ttys123"

    TerminalSSHSessionDetector.detectOverrideForTesting = { tty in
        XCTAssertEqual(tty, "ttys123")
        return DetectedSSHSession(
            destination: "devbox",
            port: 2222,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )
    }
    defer { TerminalSSHSessionDetector.detectOverrideForTesting = nil }

    workspace.refreshDetectedSSHAttachmentNow(panelId: panel.id, reason: "test")
    let payload = try XCTUnwrap(workspace.remoteAttachmentPayload(for: panel.id))
    XCTAssertEqual(payload["kind"] as? String, "detected_ssh")
    XCTAssertEqual(payload["destination"] as? String, "devbox")
    XCTAssertEqual(payload["recoverable"] as? Bool, false)
}
```

- [ ] **Step 2: Add detector test hook**

In `TerminalSSHSessionDetector`, add:

```swift
#if DEBUG
static var detectOverrideForTesting: ((String) -> DetectedSSHSession?)?
#endif
```

At the top of `detect(forTTY:)`, add:

```swift
#if DEBUG
if let detectOverrideForTesting {
    return detectOverrideForTesting(ttyName)
}
#endif
```

- [ ] **Step 3: Add refresh API**

In `Workspace`, add:

```swift
func refreshDetectedSSHAttachmentNow(panelId: UUID, reason: String) {
    guard SSHAutoRemoteSettings.passiveEnhancementEnabled() else {
        setRemoteAttachment(nil, for: panelId)
        return
    }
    guard panels[panelId] is TerminalPanel,
          !isRemoteTerminalSurface(panelId),
          let ttyName = surfaceTTYNames[panelId],
          let session = TerminalSSHSessionDetector.detect(forTTY: ttyName) else {
        if case .detectedSSH = remoteAttachmentsByPanelId[panelId] {
            setRemoteAttachment(nil, for: panelId)
        }
        return
    }

    let transportKey = Self.detectedSSHTransportKey(session)
    setRemoteAttachment(
        .detectedSSH(.init(
            destination: session.destination,
            displayTarget: session.destination,
            port: session.port,
            identityFile: session.identityFile,
            sshOptions: session.sshOptions,
            transportKey: transportKey,
            daemonState: .unavailable
        )),
        for: panelId
    )
    startDetectedSSHRemoteSupportIfNeeded(session: session, panelId: panelId, transportKey: transportKey)
}
```

Add key helper:

```swift
private static func detectedSSHTransportKey(_ session: DetectedSSHSession) -> String {
    [
        session.destination,
        session.port.map(String.init) ?? "",
        session.identityFile ?? "",
        session.configFile ?? "",
        session.jumpHost ?? "",
        session.sshOptions.joined(separator: "\u{1f}"),
    ].joined(separator: "\u{1e}")
}
```

- [ ] **Step 4: Debounce refreshes**

Add a per-panel pending work dictionary:

```swift
private var pendingSSHDetectionWorkItems: [UUID: DispatchWorkItem] = [:]
```

Add:

```swift
func scheduleDetectedSSHAttachmentRefresh(panelId: UUID, reason: String) {
    pendingSSHDetectionWorkItems[panelId]?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
        Task { @MainActor in
            self?.refreshDetectedSSHAttachmentNow(panelId: panelId, reason: reason)
        }
    }
    pendingSSHDetectionWorkItems[panelId] = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
}
```

Call it after `surfaceTTYNames[panelId]` changes and after runtime metadata refresh points that already update foreground process or TTY state. Keep this off typing hot paths.

- [ ] **Step 5: Preserve file drop behavior**

Update `TerminalImageTransfer.resolvedImageTransferTarget()` so it first checks:

```swift
if let attachment = workspace.remoteAttachment(for: id) {
    switch attachment {
    case .managedRemote:
        return .remote(.workspaceRemote)
    case .detectedSSH:
        if let ttyName = workspace.surfaceTTYNames[id],
           let session = TerminalSSHSessionDetector.detect(forTTY: ttyName) {
            return .remote(.detectedSSH(session))
        }
    }
}
```

Keep the existing fallback detector so file drop still works before the passive refresh runs.

- [ ] **Step 6: Commit passive detection**

```bash
git add Sources/Workspace.swift Sources/TerminalSSHSessionDetector.swift Sources/TerminalImageTransfer.swift cmuxTests/WorkspaceRemoteConnectionTests.swift
git commit -m "feat: detect ssh sessions per terminal surface"
```

---

### Task 5: Bridge Detected Attachments To Remote Daemon Support

**Files:**
- Modify: `Sources/Workspace.swift`
- Modify: `Sources/Panels/BrowserPanel.swift`
- Modify: `Sources/TerminalController.swift`
- Test: `cmuxTests/WorkspaceRemoteConnectionTests.swift`

- [ ] **Step 1: Add failing daemon support state test**

Add a test using a controller factory override:

```swift
func testDetectedSSHAttachmentStartsRemoteSupportWithoutMarkingWorkspaceRemote() throws {
    let workspace = Workspace(name: "Test")
    let panel = TerminalPanel()
    workspace.panels[panel.id] = panel

    var startedConfiguration: WorkspaceRemoteConfiguration?
    WorkspaceRemoteSessionController.startOverrideForTesting = { configuration, _ in
        startedConfiguration = configuration
        return .ready(version: "test", remotePath: ".cmux/bin/cmuxd-remote/test/linux-amd64/cmuxd-remote")
    }
    defer { WorkspaceRemoteSessionController.startOverrideForTesting = nil }

    let session = DetectedSSHSession(
        destination: "devbox",
        port: 2222,
        identityFile: nil,
        configFile: nil,
        jumpHost: nil,
        controlPath: nil,
        useIPv4: false,
        useIPv6: false,
        forwardAgent: false,
        compressionEnabled: false,
        sshOptions: []
    )
    workspace.startDetectedSSHRemoteSupportIfNeeded(session: session, panelId: panel.id, transportKey: "ssh:devbox")

    XCTAssertEqual(startedConfiguration?.destination, "devbox")
    XCTAssertNil(workspace.remoteConfiguration)
    XCTAssertEqual(workspace.remoteAttachment(for: panel.id)?.payload()["recoverable"] as? Bool, false)
}
```

- [ ] **Step 2: Add detected remote support controller shim**

Do not fully extract `WorkspaceRemoteSessionController` in this task. Add a small compatibility path that can start daemon/proxy support for a detected surface while leaving `remoteConfiguration` nil.

Add storage:

```swift
private var detectedSSHControllersByTransportKey: [String: WorkspaceRemoteSessionController] = [:]
private var detectedSSHSourcePanelByTransportKey: [String: UUID] = [:]
```

Add:

```swift
func startDetectedSSHRemoteSupportIfNeeded(
    session: DetectedSSHSession,
    panelId: UUID,
    transportKey: String
) {
    guard detectedSSHControllersByTransportKey[transportKey] == nil else { return }
    let configuration = WorkspaceRemoteConfiguration(
        destination: session.destination,
        port: session.port,
        identityFile: session.identityFile,
        sshOptions: session.sshOptions,
        localProxyPort: nil,
        relayPort: nil,
        relayID: nil,
        relayToken: nil,
        localSocketPath: nil,
        terminalStartupCommand: nil,
        foregroundAuthToken: nil
    )
    let controllerID = UUID()
    let controller = WorkspaceRemoteSessionController(
        workspace: self,
        configuration: configuration,
        controllerID: controllerID,
        mode: .surfaceAttachment(transportKey: transportKey, sourcePanelId: panelId)
    )
    detectedSSHControllersByTransportKey[transportKey] = controller
    detectedSSHSourcePanelByTransportKey[transportKey] = panelId
    controller.start()
}
```

Add an initializer overload or mode enum to `WorkspaceRemoteSessionController`:

```swift
enum WorkspaceRemoteSessionControllerMode: Equatable {
    case workspaceRemote
    case surfaceAttachment(transportKey: String, sourcePanelId: UUID)
}
```

Default existing callers to `.workspaceRemote`.

- [ ] **Step 3: Route controller callbacks by mode**

When the controller publishes daemon status or proxy endpoint:

```swift
switch mode {
case .workspaceRemote:
    workspace.applyRemoteDaemonStatusUpdate(status, target: configuration.displayTarget)
    workspace.applyRemoteProxyEndpointUpdate(endpoint)
case .surfaceAttachment(let transportKey, let sourcePanelId):
    workspace.applyDetectedSSHRemoteStatus(
        transportKey: transportKey,
        sourcePanelId: sourcePanelId,
        daemonStatus: status,
        proxyEndpoint: endpoint
    )
}
```

Add `Workspace.applyDetectedSSHRemoteStatus(...)` to update the matching attachment daemon state and store proxy endpoints by source panel:

```swift
private var remoteProxyEndpointsBySourcePanelId: [UUID: BrowserProxyEndpoint] = [:]

func applyDetectedSSHRemoteStatus(
    transportKey: String,
    sourcePanelId: UUID,
    daemonStatus: WorkspaceRemoteDaemonStatus,
    proxyEndpoint: BrowserProxyEndpoint?
) {
    guard case .detectedSSH(var attachment) = remoteAttachmentsByPanelId[sourcePanelId],
          attachment.transportKey == transportKey else { return }
    attachment.daemonState = Self.attachmentDaemonState(from: daemonStatus)
    remoteAttachmentsByPanelId[sourcePanelId] = .detectedSSH(attachment)
    if let proxyEndpoint {
        remoteProxyEndpointsBySourcePanelId[sourcePanelId] = proxyEndpoint
    } else {
        remoteProxyEndpointsBySourcePanelId.removeValue(forKey: sourcePanelId)
    }
}
```

- [ ] **Step 4: Resolve browser proxy by source surface**

Add:

```swift
func remoteProxyEndpoint(forSourcePanelId panelId: UUID?) -> BrowserProxyEndpoint? {
    guard let panelId else { return remoteProxyEndpoint }
    if let endpoint = remoteProxyEndpointsBySourcePanelId[panelId] {
        return endpoint
    }
    return remoteProxyEndpoint
}
```

Update `newBrowserSplit`, `newBrowserSurface`, and detached browser attach paths to pass:

```swift
proxyEndpoint: remoteProxyEndpoint(forSourcePanelId: sourcePanelId)
```

instead of always `remoteProxyEndpoint`.

- [ ] **Step 5: Commit daemon support bridge**

```bash
git add Sources/Workspace.swift Sources/Panels/BrowserPanel.swift Sources/TerminalController.swift cmuxTests/WorkspaceRemoteConnectionTests.swift
git commit -m "feat: start remote support for detected ssh surfaces"
```

---

### Task 6: Add `ssh-upgrade` CLI And Socket Helper

**Files:**
- Modify: `CLI/cmux.swift`
- Modify: `Sources/TerminalController.swift`
- Modify: `Sources/Workspace.swift`
- Test: `cmuxTests/WorkspaceRemoteConnectionTests.swift`

- [ ] **Step 1: Add failing CLI/socket command tests**

Add tests that call the CLI parser helpers directly:

```swift
func testSSHUpgradeRejectsRemoteCommandArguments() throws {
    let parsed = try XCTUnwrap(SSHCommandParser.parse(arguments: ["ssh", "devbox", "uname", "-a"]))
    XCTAssertFalse(parsed.isEligibleForAutoUpgrade)
}

func testSurfaceSSHUpgradeRequiresEligibleCommand() throws {
    let result = SurfaceSSHUpgradeValidator.validateForTesting(
        workspaceID: UUID(),
        surfaceID: UUID(),
        originalArgv: ["ssh", "devbox", "uname", "-a"],
        originalCommand: "ssh devbox uname -a"
    )
    XCTAssertEqual(result.errorCodeForTesting, "invalid_params")
}
```

- [ ] **Step 2: Add socket method**

Register `surface.ssh_upgrade` in `TerminalController` command dispatch. It accepts:

```json
{
  "workspace_id": "uuid",
  "surface_id": "uuid",
  "original_argv": ["ssh", "devbox"],
  "original_command": "ssh devbox"
}
```

Validation:

```swift
let validation = SurfaceSSHUpgradeValidator.validate(
    workspaceID: workspaceID,
    surfaceID: surfaceID,
    originalArgv: originalArgv,
    originalCommand: originalCommand
)
guard case .success(let request) = validation else {
    return validation.jsonRPCError()
}
```

First implementation behavior:

- Configure a managed remote attachment on the target surface.
- Start remote support.
- If managed PTY attach is not available in the current slice, return `fallback_required` so the shell hook executes the original command.

The response shape:

```swift
[
    "upgraded": true,
    "fallback_required": false,
    "workspace_id": workspace.id.uuidString,
    "surface_id": surfaceId.uuidString,
    "remote": workspace.remoteAttachmentPayload(for: surfaceId) ?? NSNull(),
]
```

- [ ] **Step 3: Add CLI helper**

In `CLI/cmux.swift`, add command routing:

```swift
case "ssh-upgrade":
    try runSSHUpgrade(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput)
```

Implement:

```swift
private func runSSHUpgrade(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
    let originalCommandIndex = commandArgs.firstIndex(of: "--original-command")
    let surfaceIndex = commandArgs.firstIndex(of: "--surface")
    guard let surfaceIndex, surfaceIndex + 1 < commandArgs.count else {
        throw CLIError(message: "ssh-upgrade requires --surface <id>")
    }
    guard let originalCommandIndex, originalCommandIndex + 1 < commandArgs.count else {
        throw CLIError(message: "ssh-upgrade requires --original-command <command>")
    }
    let surface = commandArgs[surfaceIndex + 1]
    let originalCommand = commandArgs[originalCommandIndex + 1]
    let originalArgv = shellSplitForSSHUpgrade(originalCommand)
    let payload = try client.sendV2(method: "surface.ssh_upgrade", params: [
        "surface_id": surface,
        "original_argv": originalArgv,
        "original_command": originalCommand,
    ])
    if jsonOutput {
        printJSON(payload)
    } else if payload["fallback_required"] as? Bool == true {
        print("fallback")
    } else {
        print("upgraded")
    }
}
```

Use a conservative shell splitter for this helper. If parsing quotes fails, return `fallback_required` through the socket path.

- [ ] **Step 4: Commit helper path**

```bash
git add CLI/cmux.swift Sources/TerminalController.swift Sources/Workspace.swift cmuxTests/WorkspaceRemoteConnectionTests.swift
git commit -m "feat: add ssh upgrade command path"
```

---

### Task 7: Add Shell Auto-Upgrade Hooks

**Files:**
- Modify: `Sources/GhosttyTerminalView.swift`
- Modify: `Resources/shell-integration/cmux-zsh-integration.zsh`
- Modify: `Resources/shell-integration/cmux-bash-integration.bash`
- Test: `cmuxTests/GhosttyConfigTests.swift`

- [ ] **Step 1: Add failing shell hook tests**

Add tests that source the shell integration scripts in a subprocess with `CMUX_SSH_UPGRADE_INTERACTIVE=1` and a fake `cmux` executable on PATH. Assertions:

```swift
func testZshSSHUpgradeHookInterceptsPlainSSH() throws {
    let output = try runShellIntegrationProbe(
        shell: "/bin/zsh",
        script: """
        source "$CMUX_SHELL_INTEGRATION_DIR/cmux-zsh-integration.zsh"
        BUFFER="ssh devbox"
        _cmux_ssh_auto_upgrade_preexec "$BUFFER"
        """
    )
    XCTAssertTrue(output.contains("ssh-upgrade"))
    XCTAssertTrue(output.contains("--original-command"))
}

func testZshSSHUpgradeHookSkipsRemoteCommand() throws {
    let output = try runShellIntegrationProbe(
        shell: "/bin/zsh",
        script: """
        source "$CMUX_SHELL_INTEGRATION_DIR/cmux-zsh-integration.zsh"
        BUFFER="ssh devbox uname -a"
        _cmux_ssh_auto_upgrade_preexec "$BUFFER"
        """
    )
    XCTAssertFalse(output.contains("ssh-upgrade"))
}
```

Use the existing shell integration test helpers in `GhosttyConfigTests` so the test exercises shell script behavior, not source text.

- [ ] **Step 2: Export shell setting flags**

In `GhosttyTerminalView`, when building terminal env, add:

```swift
if SSHAutoRemoteSettings.passiveEnhancementEnabled() {
    setManagedEnvironmentValue("CMUX_SSH_PASSIVE_ENHANCEMENT", "1")
}
if SSHAutoRemoteSettings.upgradeInteractiveCommandsEnabled() {
    setManagedEnvironmentValue("CMUX_SSH_UPGRADE_INTERACTIVE", "1")
}
```

- [ ] **Step 3: Add zsh preexec hook**

In `cmux-zsh-integration.zsh`, add:

```zsh
_cmux_ssh_auto_upgrade_preexec() {
  emulate -L zsh
  [[ "${CMUX_SSH_UPGRADE_INTERACTIVE:-0}" == "1" ]] || return 0
  [[ -n "${CMUX_SURFACE_ID:-}" ]] || return 0
  [[ -n "${CMUX_BUNDLED_CLI_PATH:-}" && -x "${CMUX_BUNDLED_CLI_PATH:-}" ]] || return 0
  local command_line="$1"
  [[ "$command_line" == ssh\ * ]] || return 0
  case "$command_line" in
    *"|"*|*">"*|*"<"*|*" -N "*|*" -L "*|*" -R "*|*" -D "*|*" -W "*) return 0 ;;
  esac
  "$CMUX_BUNDLED_CLI_PATH" ssh-upgrade --surface "$CMUX_SURFACE_ID" --original-command "$command_line" >/dev/null 2>&1
  local status=$?
  [[ $status -eq 0 ]] || return 0
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _cmux_ssh_auto_upgrade_preexec
```

The first implementation may only preflight and mark attachment. Replacing the command line with a managed session should happen through the socket helper once Task 6 returns `upgraded`.

- [ ] **Step 4: Add bash DEBUG trap hook**

In `cmux-bash-integration.bash`, add:

```bash
_cmux_ssh_auto_upgrade_debug_trap() {
  [[ "${CMUX_SSH_UPGRADE_INTERACTIVE:-0}" == "1" ]] || return 0
  [[ -n "${CMUX_SURFACE_ID:-}" ]] || return 0
  [[ -n "${CMUX_BUNDLED_CLI_PATH:-}" && -x "${CMUX_BUNDLED_CLI_PATH:-}" ]] || return 0
  local command_line="${BASH_COMMAND:-}"
  [[ "$command_line" == ssh\ * ]] || return 0
  case "$command_line" in
    *"|"*|*">"*|*"<"*|*" -N "*|*" -L "*|*" -R "*|*" -D "*|*" -W "*) return 0 ;;
  esac
  "$CMUX_BUNDLED_CLI_PATH" ssh-upgrade --surface "$CMUX_SURFACE_ID" --original-command "$command_line" >/dev/null 2>&1 || true
}

if [[ "${CMUX_SSH_UPGRADE_INTERACTIVE:-0}" == "1" ]]; then
  trap _cmux_ssh_auto_upgrade_debug_trap DEBUG
fi
```

- [ ] **Step 5: Commit shell hooks**

```bash
git add Sources/GhosttyTerminalView.swift Resources/shell-integration/cmux-zsh-integration.zsh Resources/shell-integration/cmux-bash-integration.bash cmuxTests/GhosttyConfigTests.swift
git commit -m "feat: add opt-in ssh upgrade shell hooks"
```

---

### Task 8: Preserve `cmux ssh` Compatibility Through Managed Attachments

**Files:**
- Modify: `CLI/cmux.swift`
- Modify: `Sources/Workspace.swift`
- Modify: `Sources/TerminalController.swift`
- Test: `tests_v2/test_ssh_remote_cli_metadata.py`

- [ ] **Step 1: Add compatibility assertion**

Extend `test_ssh_remote_cli_metadata.py` after `cmux ssh` creates a workspace:

```python
surface = listed_row.get("current_surface") or {}
remote_attachment = surface.get("remote_attachment") or {}
_must(
    remote_attachment.get("kind") in ("managed_remote", None),
    f"cmux ssh should expose managed remote attachment when supported: {remote_attachment}",
)
```

Keep the assertion tolerant during migration by allowing `None` until the managed attachment payload is wired into `surface.list`.

- [ ] **Step 2: Seed managed attachment for `cmux ssh` terminal**

When `Workspace.configureRemoteConnection` receives a `terminalStartupCommand`, keep existing `remoteConfiguration` behavior and also call:

```swift
setRemoteAttachment(
    .managedRemote(.init(
        destination: configuration.destination,
        displayTarget: configuration.displayTarget,
        transportKey: configuration.transportKey,
        sessionID: nil,
        relayPort: configuration.relayPort,
        daemonState: Self.attachmentDaemonState(from: remoteDaemonStatus)
    )),
    for: initialPanelId
)
```

Use the same initial panel ID logic as `seedInitialRemoteTerminalSessionIfNeeded`.

- [ ] **Step 3: Keep workspace APIs compatible**

Ensure these still return the existing shape:

- `workspace.remote.status`
- `workspace.remote.reconnect`
- `workspace.remote.disconnect`
- `workspace.remote.terminal_session_end`

Add `remote_attachment` to surface payloads without removing the existing workspace `remote` payload.

- [ ] **Step 4: Commit compatibility layer**

```bash
git add CLI/cmux.swift Sources/Workspace.swift Sources/TerminalController.swift tests_v2/test_ssh_remote_cli_metadata.py
git commit -m "feat: expose managed remote attachments for cmux ssh"
```

---

### Task 9: Add End-To-End Coverage And Build Verification

**Files:**
- Create: `tests_v2/test_ssh_auto_remote_sessions.py`
- Modify: `CHANGELOG.md` if product behavior is user-visible in the target release branch.

- [ ] **Step 1: Add e2e passive enhancement coverage**

Create `tests_v2/test_ssh_auto_remote_sessions.py`:

```python
"""E2E: ordinary ssh in a cmux terminal gets remote attachment metadata."""

from __future__ import annotations

import secrets
import shutil
import tempfile
import time
from pathlib import Path

from cmux import cmux, cmuxError
from test_ssh_remote_port_detection import (
    DOCKER_PUBLISH_ADDR,
    DOCKER_SSH_HOST,
    _docker_available,
    _parse_host_port,
    _run,
    _wait_for_ssh,
)


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise cmuxError(message)


def test_plain_ssh_surface_gets_detected_remote_attachment() -> None:
    if not _docker_available():
        print("SKIP: docker is not available")
        return

    repo_root = Path(__file__).resolve().parents[1]
    fixture_dir = repo_root / "tests" / "fixtures" / "ssh-remote"
    _must(fixture_dir.is_dir(), f"Missing docker fixture directory: {fixture_dir}")

    temp_dir = Path(tempfile.mkdtemp(prefix="cmux-ssh-auto-remote-"))
    image_tag = f"cmux-ssh-auto-remote:{secrets.token_hex(4)}"
    container_name = f"cmux-ssh-auto-remote-{secrets.token_hex(4)}"

    try:
        key_path = temp_dir / "id_ed25519"
        _run(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path)])
        pubkey = key_path.with_suffix(".pub").read_text(encoding="utf-8").strip()
        _must(bool(pubkey), "Generated SSH public key was empty")

        _run(["docker", "build", "-t", image_tag, str(fixture_dir)])
        _run([
            "docker",
            "run",
            "-d",
            "--rm",
            "--name",
            container_name,
            "-e",
            f"AUTHORIZED_KEY={pubkey}",
            "-p",
            f"{DOCKER_PUBLISH_ADDR}::22",
            image_tag,
        ])
        host_ssh_port = _parse_host_port(_run(["docker", "port", container_name, "22/tcp"]).stdout)
        host = f"root@{DOCKER_SSH_HOST}"
        _wait_for_ssh(host, host_ssh_port, key_path)

        with cmux() as client:
            workspace = client._call("workspace.create", {}) or {}
            workspace_id = str(workspace.get("workspace_id") or "")
            _must(bool(workspace_id), f"workspace.create returned no workspace_id: {workspace}")

            tree = client._call("workspace.tree", {"workspace_id": workspace_id}) or {}
            surfaces = tree.get("surfaces") or []
            _must(bool(surfaces), f"workspace.tree returned no surfaces: {tree}")
            surface_id = str(surfaces[0].get("id") or surfaces[0].get("surface_id") or "")
            _must(bool(surface_id), f"surface missing id: {surfaces[0]}")

            ssh_command = (
                f"ssh -p {host_ssh_port} "
                f"-i {key_path} "
                "-o UserKnownHostsFile=/dev/null "
                "-o StrictHostKeyChecking=no "
                f"{host}\n"
            )
            client._call("surface.send_text", {"surface_id": surface_id, "text": ssh_command})

            deadline = time.time() + 20
            last = {}
            while time.time() < deadline:
                tree = client._call("workspace.tree", {"workspace_id": workspace_id}) or {}
                surfaces = tree.get("surfaces") or []
                current = next((s for s in surfaces if str(s.get("id") or s.get("surface_id") or "") == surface_id), {})
                last = current
                remote_attachment = current.get("remote_attachment") or {}
                if remote_attachment.get("kind") == "detected_ssh":
                    _must(remote_attachment.get("recoverable") is False, f"detected ssh must not be recoverable: {remote_attachment}")
                    return
                time.sleep(0.5)
            raise cmuxError(f"surface did not receive detected ssh attachment: {last}")
    finally:
        _run(["docker", "rm", "-f", container_name], check=False)
        _run(["docker", "rmi", "-f", image_tag], check=False)
        shutil.rmtree(temp_dir, ignore_errors=True)
```

- [ ] **Step 2: Verify via tagged build**

Run:

```bash
./scripts/reload.sh --tag ssh-auto-remote-sessions
```

Expected: build succeeds and prints `App path:`. Do not launch unless manually requested.

- [ ] **Step 3: Trigger CI/VM tests**

Use GitHub Actions or the VM test runner:

```bash
gh workflow run test-e2e.yml
```

Expected: workflow starts. Watch from GitHub UI or `gh run watch` if appropriate for the branch.

- [ ] **Step 4: Commit final coverage/docs**

```bash
git add tests_v2/test_ssh_auto_remote_sessions.py CHANGELOG.md
git commit -m "test: cover ssh auto remote sessions"
```

---

## Self-Review Checklist

- Spec coverage:
  - Passive enhancement: Tasks 1, 3, 4, 5, 9.
  - Optional auto-upgrade: Tasks 1, 2, 6, 7.
  - Surface-level model: Tasks 3, 5, 8.
  - Browser proxy by source surface: Task 5.
  - `cmux ssh` compatibility: Task 8.
  - Settings and localization: Task 2.
  - Testing and rollout: Task 9 plus per-task test steps.
- Type consistency:
  - `TerminalRemoteAttachment`, `DetectedSSHAttachment`, and `ManagedRemoteAttachment` are introduced in Task 3 and used later.
  - `SSHAutoRemoteSettings` is introduced in Task 2 and used later.
  - `SSHCommandParser` is introduced in Task 1 and used by detector, CLI, and socket validation.
- Local policy:
  - Plan avoids local e2e/UI/socket test runs.
  - Plan includes required tagged reload build after code changes.
