import XCTest
@testable import PerchSupport

final class ConnectionDiagnosticsTests: XCTestCase {
    func testRouteErrorPreservesOriginalAndSuggestsBothChecks() {
        let original = "SSH exited with status 255: ssh: connect to host example port 22: No route to host"
        let message = ConnectionDiagnostics.message(for: original)
        XCTAssertTrue(message.hasPrefix(original + "\n\n"))
        XCTAssertTrue(message.contains("machine address and network connection"))
        XCTAssertTrue(message.contains("Privacy & Security → Local Network"))
        XCTAssertFalse(message.contains("permission denied"))
    }

    func testRouteMatchIsCaseInsensitive() {
        XCTAssertTrue(ConnectionDiagnostics.message(for: "NO ROUTE TO HOST").contains("then retry"))
    }

    func testOtherErrorsAreUnchanged() {
        for error in ["Permission denied (publickey).", "Host key verification failed.", "Connection timed out", ""] {
            XCTAssertEqual(ConnectionDiagnostics.message(for: error), error)
        }
    }
}
