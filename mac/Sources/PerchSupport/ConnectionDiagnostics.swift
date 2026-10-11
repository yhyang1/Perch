import Foundation

public enum ConnectionDiagnostics {
    /// Keep SSH's original error; a route failure alone does not identify its cause.
    public static func message(for error: String) -> String {
        guard error.range(of: "No route to host", options: .caseInsensitive) != nil else { return error }
        return error + "\n\nCheck the machine address and network connection. If the machine is on your local network, also check Perch in System Settings → Privacy & Security → Local Network, then retry."
    }
}
