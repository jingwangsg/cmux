import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class cmuxAppStartupTests: XCTestCase {
    override func tearDown() {
        cmuxApp.localTerminalDaemonWarmupOverrideForTesting = nil
        super.tearDown()
    }

    func testInitStartsLocalTerminalDaemonWarmup() {
        let expectation = expectation(description: "cmuxApp init triggers local terminal daemon warmup")
        cmuxApp.localTerminalDaemonWarmupOverrideForTesting = {
            expectation.fulfill()
        }

        _ = cmuxApp()

        wait(for: [expectation], timeout: 1.0)
    }
}
