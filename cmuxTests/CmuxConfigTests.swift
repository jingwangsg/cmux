import XCTest
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - JSON Decoding

final class CmuxConfigDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> CmuxConfigFile {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(CmuxConfigFile.self, from: data)
    }

    // MARK: Simple commands

    func testDecodeSimpleCommand() throws {
        let json = """
        {
          "commands": [{
            "name": "Run tests",
            "command": "npm test"
          }]
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.commands.count, 1)
        XCTAssertEqual(config.commands[0].name, "Run tests")
        XCTAssertEqual(config.commands[0].command, "npm test")
        XCTAssertNil(config.commands[0].workspace)
    }

    func testDecodeSimpleCommandWithAllFields() throws {
        let json = """
        {
          "commands": [{
            "name": "Deploy",
            "description": "Deploy to production",
            "keywords": ["ship", "release"],
            "command": "make deploy",
            "confirm": true
          }]
        }
        """
        let config = try decode(json)
        let cmd = config.commands[0]
        XCTAssertEqual(cmd.name, "Deploy")
        XCTAssertEqual(cmd.description, "Deploy to production")
        XCTAssertEqual(cmd.keywords, ["ship", "release"])
        XCTAssertEqual(cmd.command, "make deploy")
        XCTAssertEqual(cmd.confirm, true)
    }

    func testDecodeMultipleCommands() throws {
        let json = """
        {
          "commands": [
            { "name": "Build", "command": "make build" },
            { "name": "Test", "command": "make test" },
            { "name": "Lint", "command": "make lint" }
          ]
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.commands.count, 3)
        XCTAssertEqual(config.commands.map(\.name), ["Build", "Test", "Lint"])
    }

    func testDecodeEmptyCommandsArray() throws {
        let json = """
        { "commands": [] }
        """
        let config = try decode(json)
        XCTAssertTrue(config.commands.isEmpty)
    }

    func testDecodeTopLevelRemoteHost() throws {
        let json = """
        {
          "remote": {
            "host": "tether"
          },
          "commands": []
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.remote?.host, "tether")
    }

    func testRejectsBlankTopLevelRemoteHost() {
        let json = """
        {
          "remote": {
            "host": "   "
          },
          "commands": []
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    // MARK: Workspace commands

    func testDecodeWorkspaceCommand() throws {
        let json = """
        {
          "commands": [{
            "name": "Dev env",
            "workspace": {
              "name": "Development",
              "cwd": "~/projects/app",
              "color": "#FF5733"
            }
          }]
        }
        """
        let config = try decode(json)
        let ws = config.commands[0].workspace
        XCTAssertNotNil(ws)
        XCTAssertEqual(ws?.name, "Development")
        XCTAssertEqual(ws?.cwd, "~/projects/app")
        XCTAssertEqual(ws?.color, "#FF5733")
    }

    func testDecodeRestartBehaviors() throws {
        for behavior in ["recreate", "ignore", "confirm"] {
            let json = """
            {
              "commands": [{
                "name": "test",
                "restart": "\(behavior)",
                "workspace": { "name": "ws" }
              }]
            }
            """
            let config = try decode(json)
            XCTAssertEqual(config.commands[0].restart?.rawValue, behavior)
        }
    }

    // MARK: Layout tree

    func testDecodePaneNode() throws {
        let json = """
        {
          "commands": [{
            "name": "layout",
            "workspace": {
              "layout": {
                "pane": {
                  "surfaces": [
                    { "type": "terminal", "name": "shell" }
                  ]
                }
              }
            }
          }]
        }
        """
        let config = try decode(json)
        let layout = config.commands[0].workspace!.layout!
        if case .pane(let pane) = layout {
            XCTAssertEqual(pane.surfaces.count, 1)
            XCTAssertEqual(pane.surfaces[0].type, .terminal)
            XCTAssertEqual(pane.surfaces[0].name, "shell")
        } else {
            XCTFail("Expected pane node")
        }
    }

    func testDecodeSplitNode() throws {
        let json = """
        {
          "commands": [{
            "name": "layout",
            "workspace": {
              "layout": {
                "direction": "horizontal",
                "split": 0.3,
                "children": [
                  { "pane": { "surfaces": [{ "type": "terminal" }] } },
                  { "pane": { "surfaces": [{ "type": "terminal" }] } }
                ]
              }
            }
          }]
        }
        """
        let config = try decode(json)
        let layout = config.commands[0].workspace!.layout!
        if case .split(let split) = layout {
            XCTAssertEqual(split.direction, .horizontal)
            XCTAssertEqual(split.split, 0.3)
            XCTAssertEqual(split.children.count, 2)
        } else {
            XCTFail("Expected split node")
        }
    }

    func testDecodeNestedSplits() throws {
        let json = """
        {
          "commands": [{
            "name": "nested",
            "workspace": {
              "layout": {
                "direction": "horizontal",
                "children": [
                  { "pane": { "surfaces": [{ "type": "terminal" }] } },
                  {
                    "direction": "vertical",
                    "children": [
                      { "pane": { "surfaces": [{ "type": "terminal" }] } },
                      { "pane": { "surfaces": [{ "type": "browser", "url": "http://localhost:3000" }] } }
                    ]
                  }
                ]
              }
            }
          }]
        }
        """
        let config = try decode(json)
        let layout = config.commands[0].workspace!.layout!
        if case .split(let outer) = layout {
            XCTAssertEqual(outer.direction, .horizontal)
            if case .split(let inner) = outer.children[1] {
                XCTAssertEqual(inner.direction, .vertical)
                if case .pane(let browserPane) = inner.children[1] {
                    XCTAssertEqual(browserPane.surfaces[0].type, .browser)
                    XCTAssertEqual(browserPane.surfaces[0].url, "http://localhost:3000")
                } else {
                    XCTFail("Expected pane node for inner second child")
                }
            } else {
                XCTFail("Expected split node for outer second child")
            }
        } else {
            XCTFail("Expected split node")
        }
    }

    // MARK: Surface definitions

    func testDecodeTerminalSurfaceAllFields() throws {
        let json = """
        {
          "commands": [{
            "name": "test",
            "workspace": {
              "layout": {
                "pane": {
                  "surfaces": [{
                    "type": "terminal",
                    "name": "server",
                    "command": "npm start",
                    "cwd": "./backend",
                    "env": { "NODE_ENV": "development", "PORT": "3000" },
                    "focus": true
                  }]
                }
              }
            }
          }]
        }
        """
        let config = try decode(json)
        let surface = config.commands[0].workspace!.layout!
        if case .pane(let pane) = surface {
            let s = pane.surfaces[0]
            XCTAssertEqual(s.type, .terminal)
            XCTAssertEqual(s.name, "server")
            XCTAssertEqual(s.command, "npm start")
            XCTAssertEqual(s.cwd, "./backend")
            XCTAssertEqual(s.env, ["NODE_ENV": "development", "PORT": "3000"])
            XCTAssertEqual(s.focus, true)
            XCTAssertNil(s.url)
        } else {
            XCTFail("Expected pane node")
        }
    }

    func testDecodeBrowserSurface() throws {
        let json = """
        {
          "commands": [{
            "name": "test",
            "workspace": {
              "layout": {
                "pane": {
                  "surfaces": [{
                    "type": "browser",
                    "name": "Preview",
                    "url": "http://localhost:8080"
                  }]
                }
              }
            }
          }]
        }
        """
        let config = try decode(json)
        if case .pane(let pane) = config.commands[0].workspace!.layout! {
            let s = pane.surfaces[0]
            XCTAssertEqual(s.type, .browser)
            XCTAssertEqual(s.url, "http://localhost:8080")
        } else {
            XCTFail("Expected pane node")
        }
    }

    func testDecodeMultipleSurfacesInPane() throws {
        let json = """
        {
          "commands": [{
            "name": "test",
            "workspace": {
              "layout": {
                "pane": {
                  "surfaces": [
                    { "type": "terminal", "name": "shell1" },
                    { "type": "terminal", "name": "shell2" },
                    { "type": "browser", "name": "web" }
                  ]
                }
              }
            }
          }]
        }
        """
        let config = try decode(json)
        if case .pane(let pane) = config.commands[0].workspace!.layout! {
            XCTAssertEqual(pane.surfaces.count, 3)
            XCTAssertEqual(pane.surfaces.map(\.name), ["shell1", "shell2", "web"])
        } else {
            XCTFail("Expected pane node")
        }
    }

    // MARK: Decoding errors

    func testDecodeInvalidLayoutNodeThrows() {
        let json = """
        {
          "commands": [{
            "name": "bad",
            "workspace": {
              "layout": { "invalid": true }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeMissingCommandsKeyThrows() {
        let json = """
        { "notCommands": [] }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeInvalidSurfaceTypeThrows() {
        let json = """
        {
          "commands": [{
            "name": "test",
            "workspace": {
              "layout": {
                "pane": {
                  "surfaces": [{ "type": "invalidType" }]
                }
              }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    // MARK: Command validation

    func testDecodeCommandWithNeitherWorkspaceNorCommandThrows() {
        let json = """
        {
          "commands": [{
            "name": "empty"
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeCommandWithBothWorkspaceAndCommandThrows() {
        let json = """
        {
          "commands": [{
            "name": "hybrid",
            "command": "echo hi",
            "workspace": { "name": "ws" }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    // MARK: Layout validation

    func testDecodeLayoutNodeWithBothPaneAndDirectionThrows() {
        let json = """
        {
          "commands": [{
            "name": "ambiguous",
            "workspace": {
              "layout": {
                "pane": { "surfaces": [{ "type": "terminal" }] },
                "direction": "horizontal",
                "children": [
                  { "pane": { "surfaces": [{ "type": "terminal" }] } },
                  { "pane": { "surfaces": [{ "type": "terminal" }] } }
                ]
              }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeSplitWithWrongChildrenCountThrows() {
        let json = """
        {
          "commands": [{
            "name": "bad-split",
            "workspace": {
              "layout": {
                "direction": "horizontal",
                "children": [
                  { "pane": { "surfaces": [{ "type": "terminal" }] } }
                ]
              }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeSplitWithThreeChildrenThrows() {
        let json = """
        {
          "commands": [{
            "name": "bad-split",
            "workspace": {
              "layout": {
                "direction": "vertical",
                "children": [
                  { "pane": { "surfaces": [{ "type": "terminal" }] } },
                  { "pane": { "surfaces": [{ "type": "terminal" }] } },
                  { "pane": { "surfaces": [{ "type": "terminal" }] } }
                ]
              }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodePaneWithEmptySurfacesThrows() {
        let json = """
        {
          "commands": [{
            "name": "empty-pane",
            "workspace": {
              "layout": {
                "pane": { "surfaces": [] }
              }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeBlankNameThrows() {
        let json = """
        {
          "commands": [{
            "name": "",
            "command": "echo hi"
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeWhitespaceOnlyNameThrows() {
        let json = """
        {
          "commands": [{
            "name": "   ",
            "command": "echo hi"
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeBlankCommandThrows() {
        let json = """
        {
          "commands": [{
            "name": "test",
            "command": ""
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeWhitespaceOnlyCommandThrows() {
        let json = """
        {
          "commands": [{
            "name": "test",
            "command": "   "
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }
}

// MARK: - Command identity

final class CmuxCommandIdentityTests: XCTestCase {

    func testCommandIdIsDeterministic() {
        let cmd = CmuxCommandDefinition(name: "Run tests", command: "test")
        XCTAssertEqual(cmd.id, "cmux.config.command.Run%20tests")
    }

    func testCommandIdEncodesSpecialCharacters() {
        let cmd = CmuxCommandDefinition(name: "build & deploy", command: "make")
        XCTAssertTrue(cmd.id.hasPrefix("cmux.config.command."))
        XCTAssertFalse(cmd.id.contains("&"))
        XCTAssertFalse(cmd.id.contains(" "))
    }

    func testCommandIdIsUniqueForDifferentNames() {
        let cmd1 = CmuxCommandDefinition(name: "build", command: "make build")
        let cmd2 = CmuxCommandDefinition(name: "test", command: "make test")
        XCTAssertNotEqual(cmd1.id, cmd2.id)
    }

    func testCommandIdDoesNotCollideWithBuiltinPrefix() {
        let cmd = CmuxCommandDefinition(name: "palette.newWorkspace", command: "echo")
        XCTAssertTrue(cmd.id.hasPrefix("cmux.config.command."))
        XCTAssertNotEqual(cmd.id, "palette.newWorkspace")
    }
}

// MARK: - Split clamping

final class CmuxSplitDefinitionTests: XCTestCase {

    func testClampedSplitPositionDefaultsToHalf() {
        let split = CmuxSplitDefinition(direction: .horizontal, split: nil, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.5)
    }

    func testClampedSplitPositionPassesThroughValidValue() {
        let split = CmuxSplitDefinition(direction: .vertical, split: 0.3, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.3, accuracy: 0.001)
    }

    func testClampedSplitPositionClampsLow() {
        let split = CmuxSplitDefinition(direction: .horizontal, split: 0.01, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.1, accuracy: 0.001)
    }

    func testClampedSplitPositionClampsHigh() {
        let split = CmuxSplitDefinition(direction: .horizontal, split: 0.99, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.9, accuracy: 0.001)
    }

    func testClampedSplitPositionClampsNegative() {
        let split = CmuxSplitDefinition(direction: .horizontal, split: -1.0, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.1, accuracy: 0.001)
    }

    func testClampedSplitPositionClampsAboveOne() {
        let split = CmuxSplitDefinition(direction: .horizontal, split: 2.0, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.9, accuracy: 0.001)
    }

    func testSplitOrientationHorizontal() {
        let split = CmuxSplitDefinition(direction: .horizontal, split: nil, children: [])
        XCTAssertEqual(split.splitOrientation, .horizontal)
    }

    func testSplitOrientationVertical() {
        let split = CmuxSplitDefinition(direction: .vertical, split: nil, children: [])
        XCTAssertEqual(split.splitOrientation, .vertical)
    }
}

// MARK: - CWD resolution

@MainActor
final class CmuxConfigCwdResolutionTests: XCTestCase {

    private let baseCwd = "/Users/test/project"

    func testNilCwdReturnsBase() {
        XCTAssertEqual(
            CmuxConfigStore.resolveCwd(nil, relativeTo: baseCwd),
            baseCwd
        )
    }

    func testEmptyCwdReturnsBase() {
        XCTAssertEqual(
            CmuxConfigStore.resolveCwd("", relativeTo: baseCwd),
            baseCwd
        )
    }

    func testDotCwdReturnsBase() {
        XCTAssertEqual(
            CmuxConfigStore.resolveCwd(".", relativeTo: baseCwd),
            baseCwd
        )
    }

    func testAbsolutePathReturnedAsIs() {
        XCTAssertEqual(
            CmuxConfigStore.resolveCwd("/tmp/other", relativeTo: baseCwd),
            "/tmp/other"
        )
    }

    func testRelativePathJoinedToBase() {
        XCTAssertEqual(
            CmuxConfigStore.resolveCwd("backend/src", relativeTo: baseCwd),
            "/Users/test/project/backend/src"
        )
    }

    func testTildeExpandsToHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            CmuxConfigStore.resolveCwd("~", relativeTo: baseCwd),
            home
        )
    }

    func testTildeSlashExpandsToHomePlusPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            CmuxConfigStore.resolveCwd("~/Documents/work", relativeTo: baseCwd),
            (home as NSString).appendingPathComponent("Documents/work")
        )
    }

    func testSingleSubdirectory() {
        XCTAssertEqual(
            CmuxConfigStore.resolveCwd("src", relativeTo: baseCwd),
            "/Users/test/project/src"
        )
    }

    func testProjectRemoteHostResolvesFromNearestCmuxConfigWhenHostIsExplicitSSHAlias() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cmux-project-remote-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("subdir", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "remote": { "host": "tether" },
          "commands": []
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let remote = CmuxConfigStore.projectRemoteDefinition(
            startingFrom: nested.path,
            sshHostAliases: ["other", "tether"]
        )

        XCTAssertEqual(remote?.host, "tether")
        XCTAssertEqual(remote?.configPath, configURL.path)
    }

    func testProjectRemoteHostIgnoresHostsThatAreNotExplicitSSHAliases() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cmux-project-remote-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try """
        {
          "remote": { "host": "wildcard-only" },
          "commands": []
        }
        """.write(to: root.appendingPathComponent("cmux.json"), atomically: true, encoding: .utf8)

        let remote = CmuxConfigStore.projectRemoteDefinition(
            startingFrom: root.path,
            sshHostAliases: ["*.example.com"]
        )

        XCTAssertNil(remote)
    }
}

// MARK: - Project remote workspaces

@MainActor
final class CmuxConfigProjectRemoteWorkspaceTests: XCTestCase {
    override func tearDown() {
        CmuxConfigStore.sshHostAliasesOverrideForTesting = nil
        Workspace.localTerminalLaunchConfigurationOverrideForTesting = nil
        Workspace.terminalPanelCreationObserverForTesting = nil
        ProjectRemoteWorkspaceBootstrap.startupScriptWriterOverrideForTesting = nil
        super.tearDown()
    }

    func testWorkspaceCreatedInsideProjectRemoteConfigStartsAsManagedRemoteWorkspace() throws {
        CmuxConfigStore.sshHostAliasesOverrideForTesting = { ["tether"] }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cmux-project-remote-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("app", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try """
        {
          "remote": { "host": "tether" },
          "commands": []
        }
        """.write(to: root.appendingPathComponent("cmux.json"), atomically: true, encoding: .utf8)

        let manager = TabManager()
        let previousLaunchOverride = Workspace.localTerminalLaunchConfigurationOverrideForTesting
        Workspace.localTerminalLaunchConfigurationOverrideForTesting = { request in
            XCTFail("Initial project remote terminal must run its bootstrap directly, not via local daemon: \(request)")
            return nil
        }
        defer {
            Workspace.localTerminalLaunchConfigurationOverrideForTesting = previousLaunchOverride
        }

        let workspace = manager.addWorkspace(workingDirectory: nested.path, select: false)

        XCTAssertEqual(workspace.remoteConfiguration?.destination, "tether")
        XCTAssertNotNil(workspace.remoteConfiguration?.foregroundAuthToken)
        XCTAssertTrue(workspace.remoteConfiguration?.sshOptions.contains("ControlMaster=auto") == true)
        XCTAssertTrue(workspace.remoteConfiguration?.sshOptions.contains("ControlPersist=600") == true)
        XCTAssertTrue(workspace.remoteConfiguration?.sshOptions.contains("StrictHostKeyChecking=accept-new") == true)
        XCTAssertTrue(workspace.remoteConfiguration?.sshOptions.contains(where: { $0.hasPrefix("ControlPath=") }) == true)
        XCTAssertEqual(workspace.remoteConnectionState, .disconnected)
        XCTAssertTrue(workspace.isRemoteWorkspace)
        let terminalId = try XCTUnwrap(workspace.focusedTerminalPanel?.id)
        XCTAssertTrue(workspace.isRemoteTerminalSurface(terminalId))
        XCTAssertFalse(
            workspace.focusedTerminalPanel?.surface.debugInitialCommand()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true
        )
    }

    func testWorkspaceCreatedInsideProjectRemoteConfigRunsInitialCommandInRemoteShell() throws {
        CmuxConfigStore.sshHostAliasesOverrideForTesting = { ["tether"] }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cmux-project-remote-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("app", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try """
        {
          "remote": { "host": "tether" },
          "commands": []
        }
        """.write(to: root.appendingPathComponent("cmux.json"), atomically: true, encoding: .utf8)

        let manager = TabManager()
        let workspace = manager.addWorkspace(
            workingDirectory: nested.path,
            initialTerminalCommand: "echo remote-project",
            select: false
        )

        let terminal = try XCTUnwrap(workspace.focusedTerminalPanel)
        XCTAssertEqual(workspace.remoteConfiguration?.destination, "tether")
        XCTAssertTrue(workspace.isRemoteTerminalSurface(terminal.id))
        XCTAssertNotEqual(terminal.surface.debugInitialCommand(), "echo remote-project")
        XCTAssertEqual(terminal.surface.debugInitialInput(), "echo remote-project\n")
    }

    func testProjectRemoteCustomLayoutCreatesFinalTerminalsAsManagedRemote() throws {
        CmuxConfigStore.sshHostAliasesOverrideForTesting = { ["tether"] }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cmux-project-remote-layout-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try """
        {
          "remote": { "host": "tether" },
          "commands": []
        }
        """.write(to: root.appendingPathComponent("cmux.json"), atomically: true, encoding: .utf8)

        let manager = TabManager()
        let workspace = manager.addWorkspace(workingDirectory: root.path, select: false)
        let remoteStartupCommand = try XCTUnwrap(workspace.remoteConfiguration?.terminalStartupCommand)
        let layout = CmuxLayoutNode.split(CmuxSplitDefinition(
            direction: .horizontal,
            split: 0.5,
            children: [
                .pane(CmuxPaneDefinition(surfaces: [
                    CmuxSurfaceDefinition(type: .terminal, name: "shell")
                ])),
                .pane(CmuxPaneDefinition(surfaces: [
                    CmuxSurfaceDefinition(type: .terminal, name: "worker", command: "echo worker")
                ]))
            ]
        ))

        workspace.applyCustomLayout(layout, baseCwd: root.path)

        let terminalPanels = workspace.panels.values.compactMap { $0 as? TerminalPanel }
        XCTAssertEqual(terminalPanels.count, 2)
        XCTAssertEqual(workspace.activeRemoteTerminalSessionCount, 2)
        XCTAssertTrue(terminalPanels.allSatisfy { workspace.isRemoteTerminalSurface($0.id) })
        XCTAssertTrue(terminalPanels.allSatisfy { $0.surface.debugInitialCommand() == remoteStartupCommand })
    }

    func testProjectRemoteCustomLayoutDoesNotBootstrapScaffoldTerminalForReplacedPane() throws {
        CmuxConfigStore.sshHostAliasesOverrideForTesting = { ["tether"] }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cmux-project-remote-replaced-layout-\(UUID().uuidString)", isDirectory: true)
        let workerDirectory = root.appendingPathComponent("worker", isDirectory: true)
        try fm.createDirectory(at: workerDirectory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try """
        {
          "remote": { "host": "tether" },
          "commands": []
        }
        """.write(to: root.appendingPathComponent("cmux.json"), atomically: true, encoding: .utf8)

        var createdInitialCommands: [String?] = []
        Workspace.terminalPanelCreationObserverForTesting = { _, initialCommand in
            createdInitialCommands.append(initialCommand)
        }

        let manager = TabManager()
        let workspace = manager.addWorkspace(workingDirectory: root.path, select: false)
        let remoteStartupCommand = try XCTUnwrap(workspace.remoteConfiguration?.terminalStartupCommand)
        let layout = CmuxLayoutNode.split(CmuxSplitDefinition(
            direction: .horizontal,
            split: 0.5,
            children: [
                .pane(CmuxPaneDefinition(surfaces: [
                    CmuxSurfaceDefinition(type: .terminal, name: "shell")
                ])),
                .pane(CmuxPaneDefinition(surfaces: [
                    CmuxSurfaceDefinition(type: .terminal, name: "worker", cwd: "worker")
                ]))
            ]
        ))

        workspace.applyCustomLayout(layout, baseCwd: root.path)

        XCTAssertEqual(workspace.panels.values.compactMap { $0 as? TerminalPanel }.count, 2)
        XCTAssertEqual(
            createdInitialCommands.filter { $0 == remoteStartupCommand }.count,
            2,
            "Only the final terminal should run the managed remote bootstrap; layout scaffold terminals must not bootstrap SSH."
        )
    }

    func testExplicitSSHWorkspaceCreationCanOptOutOfAmbientProjectRemoteConfig() throws {
        CmuxConfigStore.sshHostAliasesOverrideForTesting = { ["tether"] }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cmux-project-remote-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("app", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try """
        {
          "remote": { "host": "tether" },
          "commands": []
        }
        """.write(to: root.appendingPathComponent("cmux.json"), atomically: true, encoding: .utf8)

        let previousLaunchOverride = Workspace.localTerminalLaunchConfigurationOverrideForTesting
        Workspace.localTerminalLaunchConfigurationOverrideForTesting = { _ in nil }
        defer {
            Workspace.localTerminalLaunchConfigurationOverrideForTesting = previousLaunchOverride
        }

        let manager = TabManager()
        let projectWorkspace = manager.addWorkspace(workingDirectory: nested.path, select: true)
        XCTAssertEqual(projectWorkspace.remoteConfiguration?.destination, "tether")

        let explicitSSHWorkspace = manager.addWorkspace(
            initialTerminalCommand: "ssh other-host",
            select: false,
            inferProjectRemote: false
        )
        let terminal = try XCTUnwrap(explicitSSHWorkspace.focusedTerminalPanel)

        XCTAssertEqual(explicitSSHWorkspace.currentDirectory, nested.path)
        XCTAssertNil(explicitSSHWorkspace.remoteConfiguration)
        XCTAssertFalse(explicitSSHWorkspace.isRemoteTerminalSurface(terminal.id))
        XCTAssertEqual(terminal.surface.debugInitialCommand(), "ssh other-host")
    }

    func testProjectRemoteBootstrapFailureKeepsWorkspaceLocalInsteadOfUnmanagedSSH() throws {
        CmuxConfigStore.sshHostAliasesOverrideForTesting = { ["tether"] }
        ProjectRemoteWorkspaceBootstrap.startupScriptWriterOverrideForTesting = { _, _ in nil }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "cmux-project-remote-bootstrap-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try """
        {
          "remote": { "host": "tether" },
          "commands": []
        }
        """.write(to: root.appendingPathComponent("cmux.json"), atomically: true, encoding: .utf8)

        let previousLaunchOverride = Workspace.localTerminalLaunchConfigurationOverrideForTesting
        Workspace.localTerminalLaunchConfigurationOverrideForTesting = { _ in nil }
        defer {
            Workspace.localTerminalLaunchConfigurationOverrideForTesting = previousLaunchOverride
        }

        let manager = TabManager()
        let workspace = manager.addWorkspace(workingDirectory: root.path, select: false)
        let terminal = try XCTUnwrap(workspace.focusedTerminalPanel)

        XCTAssertNil(workspace.remoteConfiguration)
        XCTAssertFalse(workspace.isRemoteWorkspace)
        XCTAssertFalse(workspace.isRemoteTerminalSurface(terminal.id))
        XCTAssertNotEqual(terminal.surface.debugInitialCommand(), "ssh -tt tether")
    }

    func testConfigRevisionReconcilesProjectRemoteStateForAllWorkspaces() throws {
        CmuxConfigStore.sshHostAliasesOverrideForTesting = { ["tether"] }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cmux-project-remote-\(UUID().uuidString)", isDirectory: true)
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try fm.createDirectory(at: first, withIntermediateDirectories: true)
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let configURL = root.appendingPathComponent("cmux.json", isDirectory: false)
        try """
        {
          "remote": { "host": "tether" },
          "commands": []
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let manager = TabManager()
        let firstWorkspace = manager.addWorkspace(workingDirectory: first.path, select: true)
        let secondWorkspace = manager.addWorkspace(workingDirectory: second.path, select: false)

        XCTAssertEqual(firstWorkspace.remoteConfiguration?.projectConfigPath, configURL.path)
        XCTAssertEqual(secondWorkspace.remoteConfiguration?.projectConfigPath, configURL.path)

        try """
        {
          "commands": []
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        manager.reconcileProjectRemoteWorkspacesWithProjectConfig()

        XCTAssertNil(firstWorkspace.remoteConfiguration)
        XCTAssertNil(secondWorkspace.remoteConfiguration)
        XCTAssertFalse(firstWorkspace.isRemoteWorkspace)
        XCTAssertFalse(secondWorkspace.isRemoteWorkspace)
    }

    func testUnselectedProjectRemoteConfigChangePublishesRevisionForReconcile() throws {
        CmuxConfigStore.sshHostAliasesOverrideForTesting = { ["tether"] }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cmux-project-remote-watch-\(UUID().uuidString)", isDirectory: true)
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try fm.createDirectory(at: first, withIntermediateDirectories: true)
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let firstConfigURL = first.appendingPathComponent("cmux.json", isDirectory: false)
        let secondConfigURL = second.appendingPathComponent("cmux.json", isDirectory: false)
        let remoteConfig = """
        {
          "remote": { "host": "tether" },
          "commands": []
        }
        """
        try remoteConfig.write(to: firstConfigURL, atomically: true, encoding: .utf8)
        try remoteConfig.write(to: secondConfigURL, atomically: true, encoding: .utf8)

        let manager = TabManager()
        let selectedWorkspace = manager.addWorkspace(workingDirectory: first.path, select: true)
        let unselectedWorkspace = manager.addWorkspace(workingDirectory: second.path, select: false)
        XCTAssertEqual(selectedWorkspace.remoteConfiguration?.projectConfigPath, firstConfigURL.path)
        XCTAssertEqual(unselectedWorkspace.remoteConfiguration?.projectConfigPath, secondConfigURL.path)

        let store = CmuxConfigStore()
        store.wireDirectoryTracking(tabManager: manager)
        store.loadAll()

        let baselineRevision = store.configRevision
        let revisionPublished = expectation(description: "unselected project config publishes revision")
        var didFulfill = false
        var cancellables = Set<AnyCancellable>()
        store.$configRevision
            .dropFirst()
            .sink { revision in
                guard !didFulfill, revision > baselineRevision else { return }
                didFulfill = true
                revisionPublished.fulfill()
            }
            .store(in: &cancellables)

        try """
        {
          "commands": []
        }
        """.write(to: secondConfigURL, atomically: true, encoding: .utf8)

        wait(for: [revisionPublished], timeout: 2.0)
        manager.reconcileProjectRemoteWorkspacesWithProjectConfig()

        XCTAssertEqual(selectedWorkspace.remoteConfiguration?.destination, "tether")
        XCTAssertNil(unselectedWorkspace.remoteConfiguration)
        XCTAssertTrue(selectedWorkspace.isRemoteWorkspace)
        XCTAssertFalse(unselectedWorkspace.isRemoteWorkspace)
    }
}

// MARK: - Layout encoding round-trip

final class CmuxLayoutEncodingTests: XCTestCase {

    func testPaneNodeRoundTrips() throws {
        let original = CmuxLayoutNode.pane(CmuxPaneDefinition(surfaces: [
            CmuxSurfaceDefinition(type: .terminal, name: "shell")
        ]))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CmuxLayoutNode.self, from: data)

        if case .pane(let pane) = decoded {
            XCTAssertEqual(pane.surfaces.count, 1)
            XCTAssertEqual(pane.surfaces[0].name, "shell")
        } else {
            XCTFail("Expected pane node after round-trip")
        }
    }

    func testSplitNodeRoundTrips() throws {
        let original = CmuxLayoutNode.split(CmuxSplitDefinition(
            direction: .vertical,
            split: 0.7,
            children: [
                .pane(CmuxPaneDefinition(surfaces: [CmuxSurfaceDefinition(type: .terminal)])),
                .pane(CmuxPaneDefinition(surfaces: [CmuxSurfaceDefinition(type: .browser, url: "http://localhost")]))
            ]
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CmuxLayoutNode.self, from: data)

        if case .split(let split) = decoded {
            XCTAssertEqual(split.direction, .vertical)
            XCTAssertEqual(split.split, 0.7)
            XCTAssertEqual(split.children.count, 2)
        } else {
            XCTFail("Expected split node after round-trip")
        }
    }
}
