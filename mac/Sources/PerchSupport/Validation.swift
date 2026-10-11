import Foundation

public enum InputValidation {
    public static func sshAlias(_ value: String) -> Bool {
        guard let match = value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) else { return false }
        return match == (value.startIndex..<value.endIndex)
    }

    public static func absolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
    }


}

public enum ShellCommand {
    /// POSIX shell single-quoting, including quotes embedded in the input.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func ssh(alias: String, workspace: String) -> String? {
        guard InputValidation.sshAlias(alias), workspace.isEmpty || InputValidation.absolutePath(workspace) else { return nil }
        let prefix = "ssh -t -o StrictHostKeyChecking=yes -o ForwardAgent=no -o ClearAllForwardings=yes -- " + quote(alias)
        if workspace.isEmpty { return prefix }
        let remote = "cd " + quote(workspace) + " && exec \"${SHELL:-/bin/sh}\" -l"
        return prefix + " " + quote(remote)
    }
}

public struct JSONLineFramer {
    public enum FramingError: Error, LocalizedError {
        case frameTooLarge
        public var errorDescription: String? { "The bridge exceeded the maximum JSON-line size." }
    }

    private var buffer = Data()
    public let maximumLineBytes: Int
    public init(maximumLineBytes: Int = 33_554_432) { self.maximumLineBytes = maximumLineBytes }

    /// Buffers bytes rather than Strings so split UTF-8 code points are preserved.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 10) {
            let count = buffer.distance(from: buffer.startIndex, to: newline)
            guard count <= maximumLineBytes else { throw FramingError.frameTooLarge }
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        guard buffer.count <= maximumLineBytes else { throw FramingError.frameTooLarge }
        return lines
    }

    public var hasPartialLine: Bool { !buffer.isEmpty }
}

public enum TerminalText {
    /// Readable text only: deliberately does not implement cursor positioning or a VT emulator.
    public static func display(_ raw: String) -> String {
        let text = raw
            .replacingOccurrences(of: "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 || $0.value == 9 || $0.value == 10 }))
    }
}
