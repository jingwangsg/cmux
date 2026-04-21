import XCTest
import AppKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AppDelegateLocalTerminalDaemonTests: XCTestCase {
    private enum RestartError: LocalizedError {
        case failed

        var errorDescription: String? {
            switch self {
            case .failed:
                return "Expected restart failure"
            }
        }
    }

    override func tearDown() {
        AppDelegate.localTerminalDaemonRestartConfirmationOverrideForTesting = nil
        AppDelegate.localTerminalDaemonRestartOperationOverrideForTesting = nil
        AppDelegate.localTerminalDaemonRestartFailureHandlerOverrideForTesting = nil
        super.tearDown()
    }

    func testRestartLocalTerminalDaemonDoesNothingWhenConfirmationIsRejected() {
        let appDelegate = AppDelegate()
        var restartCalled = false

        AppDelegate.localTerminalDaemonRestartConfirmationOverrideForTesting = { false }
        AppDelegate.localTerminalDaemonRestartOperationOverrideForTesting = {
            restartCalled = true
            return "/tmp/should-not-run.sock"
        }

        appDelegate.restartLocalTerminalDaemon(nil)

        XCTAssertFalse(restartCalled)
    }

    func testRestartLocalTerminalDaemonRunsRestartOffMainThread() {
        let appDelegate = AppDelegate()
        let expectation = expectation(description: "restart operation executed")

        AppDelegate.localTerminalDaemonRestartConfirmationOverrideForTesting = { true }
        AppDelegate.localTerminalDaemonRestartOperationOverrideForTesting = {
            XCTAssertFalse(Thread.isMainThread)
            expectation.fulfill()
            return "/tmp/restarted.sock"
        }

        appDelegate.restartLocalTerminalDaemon(nil)

        wait(for: [expectation], timeout: 2.0)
    }

    func testRestartLocalTerminalDaemonReportsFailureOnMainThread() {
        let appDelegate = AppDelegate()
        let expectation = expectation(description: "restart failure reported")

        AppDelegate.localTerminalDaemonRestartConfirmationOverrideForTesting = { true }
        AppDelegate.localTerminalDaemonRestartOperationOverrideForTesting = {
            XCTAssertFalse(Thread.isMainThread)
            throw RestartError.failed
        }
        AppDelegate.localTerminalDaemonRestartFailureHandlerOverrideForTesting = { message in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(message, "Expected restart failure")
            expectation.fulfill()
        }

        appDelegate.restartLocalTerminalDaemon(nil)

        wait(for: [expectation], timeout: 2.0)
    }
}
