import Foundation

enum TerminalRemoteDaemonState: Equatable {
    case unavailable
    case bootstrapping(detail: String?)
    case ready(version: String?, remotePath: String?)
    case error(detail: String)

    init(status: WorkspaceRemoteDaemonStatus) {
        switch status.state {
        case .unavailable:
            self = .unavailable
        case .bootstrapping:
            self = .bootstrapping(detail: status.detail)
        case .ready:
            self = .ready(version: status.version, remotePath: status.remotePath)
        case .error:
            self = .error(detail: status.detail ?? "remote daemon error")
        }
    }

    func payload() -> [String: Any] {
        switch self {
        case .unavailable:
            return ["state": "unavailable"]
        case .bootstrapping(let detail):
            return [
                "state": "bootstrapping",
                "detail": detail ?? NSNull(),
            ]
        case .ready(let version, let remotePath):
            return [
                "state": "ready",
                "version": version ?? NSNull(),
                "remote_path": remotePath ?? NSNull(),
            ]
        case .error(let detail):
            return [
                "state": "error",
                "detail": detail,
            ]
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
