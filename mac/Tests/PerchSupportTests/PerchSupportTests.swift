import Foundation
import XCTest
@testable import PerchSupport

final class PerchSupportTests: XCTestCase {
    func testAliasRejectsOptionsAndShellSyntax() {
        for valid in ["work", "my-workbench", "dev_2", "host.example"] {
            XCTAssertTrue(InputValidation.sshAlias(valid), valid)
        }
        for invalid in ["", "-oProxyCommand=bad", "user@host", "host;touch /tmp/x", "host\nother", "host other"] {
            XCTAssertFalse(InputValidation.sshAlias(invalid), invalid)
        }
    }

    func testShellEscaping() {
        XCTAssertEqual(ShellCommand.quote("a'b"), "'a'\\''b'")
        XCTAssertEqual(ShellCommand.quote("$(touch /tmp/x)"), "'$(touch /tmp/x)'")
        XCTAssertNil(ShellCommand.ssh(alias: "-oBad", workspace: "/tmp"))
        XCTAssertNil(ShellCommand.ssh(alias: "work", workspace: "relative"))
        let command = ShellCommand.ssh(alias: "work", workspace: "/home/me/project's folder")
        XCTAssertNotNil(command)
        XCTAssertTrue(command?.contains("StrictHostKeyChecking=yes") == true)
        XCTAssertTrue(command?.contains("ForwardAgent=no") == true)
        XCTAssertTrue(command?.contains("ClearAllForwardings=yes -- 'work' ") == true)
        XCTAssertNotNil(ShellCommand.ssh(alias: "work", workspace: ""))
    }

    func testPathValidation() {
        XCTAssertTrue(InputValidation.absolutePath("/home/me/project with spaces"))
        XCTAssertFalse(InputValidation.absolutePath("~/project"))
        XCTAssertFalse(InputValidation.absolutePath("/home/me\nproject"))
        XCTAssertFalse(InputValidation.absolutePath("/home/me\0project"))
    }

    func testFragmentedMultibyteJSONLine() throws {
        var framer = JSONLineFramer()
        let data = Data("{\"event\":\"text\",\"payload\":{\"text\":\"你好\"}}\n".utf8)
        var frames: [Data] = []
        for byte in data { frames += try framer.append(Data([byte])) }
        XCTAssertEqual(frames.count, 1)
        let object = try JSONSerialization.jsonObject(with: frames[0]) as? [String: Any]
        XCTAssertEqual((object?["payload"] as? [String: String])?["text"], "你好")
        XCTAssertFalse(framer.hasPartialLine)
    }

    func testMultipleFramesAndPartialTail() throws {
        var framer = JSONLineFramer()
        XCTAssertEqual(try framer.append(Data("{}\n\n{\"a\":1}\n{".utf8)).count, 2)
        XCTAssertTrue(framer.hasPartialLine)
        XCTAssertEqual(try framer.append(Data("}\n".utf8)), [Data("{}".utf8)])
        XCTAssertFalse(framer.hasPartialLine)
    }

    func testOversizedFrameRejectedWithOrWithoutNewline() {
        var partial = JSONLineFramer(maximumLineBytes: 4)
        XCTAssertThrowsError(try partial.append(Data("12345".utf8)))
        var complete = JSONLineFramer(maximumLineBytes: 4)
        XCTAssertThrowsError(try complete.append(Data("12345\n".utf8)))
    }

    func testTerminalPresentationIsTextOnly() {
        XCTAssertEqual(TerminalText.display("\u{001B}[31mred\u{001B}[0m\r\nnext"), "red\nnext")
        XCTAssertEqual(TerminalText.display("\u{001B}]0;window title\u{0007}hello"), "hello")
        XCTAssertEqual(TerminalText.display("one\u{0003}two"), "onetwo")
    }
}
