import AppKit
import Foundation
import PerchSupport
import SwiftUI

enum MachineState: String {
    case disconnected, connecting, ready, error
    var color: Color {
        switch self {
        case .ready: return .green
        case .connecting: return .orange
        case .error: return .red
        case .disconnected: return .secondary
        }
    }
}

struct RemoteFile: Identifiable {
    let name: String
    let path: String
    let type: String
    let size: Int64
    var id: String { path }
    var icon: String {
        switch type {
        case "directory": return "folder.fill"
        case "symlink": return "link"
        case "file": return "doc"
        default: return "questionmark.square"
        }
    }
}

@MainActor
final class MachineModel: ObservableObject {
    @Published var host = ""
    @Published var workspace = ""
    @Published var pythonPath = "/usr/bin/python3"
    @Published var projectRoot: String
    @Published var terminalInput = ""
    @Published private(set) var state: MachineState = .disconnected
    @Published private(set) var verified = false
    @Published private(set) var status = "No machine connection has been made."
    @Published private(set) var identity: [String: String] = [:]
    @Published private(set) var entries: [RemoteFile] = []
    @Published private(set) var browsingPath = ""
    @Published private(set) var filesLoading = false
    @Published private(set) var selectedFile: RemoteFile?
    @Published private(set) var preview = ""
    @Published private(set) var previewLoading = false
    @Published private(set) var previewTruncated = false
    @Published private(set) var downloading = false
    @Published private(set) var terminalState = "stopped"
    @Published private(set) var terminalOutput = ""
    @Published private(set) var terminalStatus = "Terminal has not been started."
    @Published private(set) var diagnostics = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    private let bridge = BridgeClient()
    private var sessionID = UUID()
    private var listingID = UUID()
    private var previewID = UUID()
    private var timeout: DispatchWorkItem?

    init() {
        let cwd = FileManager.default.currentDirectoryPath
        projectRoot = ProcessInfo.processInfo.environment["PERCH_ROOT"] ??
            (FileManager.default.fileExists(atPath: cwd + "/perch/bridge.py") ? cwd : "")
        bridge.onEvent = { [weak self] event, payload in self?.receive(event, payload) }
        bridge.onDiagnostic = { [weak self] text in
            guard let self else { return }
            self.diagnostics += text
            if self.diagnostics.count > 32_768 {
                self.diagnostics = "[Earlier diagnostics omitted]\n" + String(self.diagnostics.suffix(24_576))
            }
        }
        bridge.onExit = { [weak self] message in
            guard let self, self.state != .disconnected else { return }
            self.fail(message)
        }
    }

    var editable: Bool { state == .disconnected || state == .error }
    var connected: Bool { verified && state == .ready }
    var terminalCommand: String? { ShellCommand.ssh(alias: host, workspace: workspace) }
    var canGoUp: Bool {
        connected && !browsingPath.isEmpty && browsingPath != (identity["workspace"] ?? workspace) && browsingPath != "/"
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Perch project folder"
        panel.message = "Select the folder containing perch/bridge.py."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.projectRoot = url.path }
        }
    }

    func connect() {
        guard editable else { return }
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
        notice = nil
        guard InputValidation.sshAlias(host) else {
            errorMessage = "Enter an existing SSH host or alias. Keep usernames, keys, ports, and SSH options in your current SSH configuration."
            return
        }
        guard workspace.isEmpty || InputValidation.absolutePath(workspace) else {
            errorMessage = "Enter an absolute remote workspace path, or leave it empty to use the SSH login directory."
            return
        }
        sessionID = UUID()
        let token = sessionID
        resetSession()
        diagnostics = ""
        do {
            try bridge.start(pythonPath: pythonPath, projectRoot: projectRoot)
            state = .connecting
            status = "Checking the machine identity and workspace over SSH…"
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, self.sessionID == token, !self.verified else { return }
                self.fail("The machine handshake timed out. Check SSH and diagnostics, then retry.")
                self.bridge.stop()
            }
            timeout = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: deadline)
            bridge.request("machineConnect", params: ["host": host, "workspace": workspace]) { [weak self] result in
                guard let self, self.sessionID == token else { return }
                self.timeout?.cancel()
                switch result {
                case .success(let raw):
                    guard let info = raw as? [String: Any],
                          let remoteHost = info["hostname"] as? String,
                          let remoteUser = info["user"] as? String,
                          let remoteWorkspace = info["workspace"] as? String else {
                        self.fail("The machine handshake returned incomplete identity information.")
                        return
                    }
                    self.identity = info.compactMapValues { $0 as? String }
                    self.workspace = remoteWorkspace
                    self.verified = true
                    self.state = .ready
                    self.status = "\(remoteUser)@\(remoteHost) · SSH verified"
                    self.listFiles(remoteWorkspace)
                case .failure(let error): self.fail(error.localizedDescription)
                }
            }
        } catch { fail(error.localizedDescription) }
    }

    func disconnect() {
        timeout?.cancel()
        sessionID = UUID()
        let token = sessionID
        state = .disconnected
        status = "Disconnected. Remote processes already started may continue running."
        resetSession()
        bridge.request("machineDisconnect") { [weak self] _ in
            guard let self, self.sessionID == token else { return }
            self.bridge.stop()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.sessionID == token, self.state == .disconnected else { return }
            self.bridge.stop()
        }
    }

    func shutdown() {
        timeout?.cancel()
        sessionID = UUID()
        bridge.request("machineDisconnect")
        bridge.stop()
    }

    func listFiles(_ path: String? = nil) {
        guard connected else { return }
        let destination = path ?? browsingPath
        let token = sessionID
        listingID = UUID()
        let listing = listingID
        filesLoading = true
        bridge.request("listFiles", params: ["path": destination]) { [weak self] result in
            guard let self, self.sessionID == token, self.listingID == listing else { return }
            self.filesLoading = false
            switch result {
            case .success(let raw):
                guard let info = raw as? [String: Any], let path = info["path"] as? String,
                      let values = info["entries"] as? [[String: Any]] else {
                    self.errorMessage = "The file list response was malformed."
                    return
                }
                self.browsingPath = path
                self.entries = values.compactMap { value in
                    guard let name = value["name"] as? String, let path = value["path"] as? String,
                          let type = value["type"] as? String else { return nil }
                    return RemoteFile(name: name, path: path, type: type, size: (value["size"] as? NSNumber)?.int64Value ?? 0)
                }.sorted {
                    if ($0.type == "directory") != ($1.type == "directory") { return $0.type == "directory" }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                self.selectedFile = nil
                self.preview = ""
                self.previewID = UUID()
                self.previewLoading = false
            case .failure(let error): self.errorMessage = error.localizedDescription
            }
        }
    }

    func goUp() {
        guard canGoUp else { return }
        listFiles((browsingPath as NSString).deletingLastPathComponent)
    }

    func open(_ file: RemoteFile) {
        guard connected else { return }
        if file.type == "directory" { listFiles(file.path); return }
        selectedFile = file
        preview = ""
        previewTruncated = false
        previewLoading = true
        previewID = UUID()
        let selection = previewID, token = sessionID
        bridge.request("readFile", params: ["path": file.path]) { [weak self] result in
            guard let self, self.sessionID == token, self.previewID == selection else { return }
            self.previewLoading = false
            switch result {
            case .success(let raw):
                guard let info = raw as? [String: Any], let text = info["text"] as? String else {
                    self.errorMessage = "The file preview response was malformed."
                    return
                }
                self.preview = text
                self.previewTruncated = info["truncated"] as? Bool ?? false
            case .failure(let error):
                self.preview = "Preview unavailable. Use Save… to download a regular file."
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func download(_ file: RemoteFile) {
        guard connected, !downloading, file.type == "file" else { return }
        let panel = NSSavePanel()
        panel.title = "Download \(file.name)"
        panel.message = "Choose a new filename. Perch never replaces an existing local file."
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        let token = sessionID
        panel.begin { [weak self] response in
            guard let self, response == .OK, let target = panel.url,
                  self.sessionID == token, self.connected else { return }
            guard !FileManager.default.fileExists(atPath: target.path) else {
                self.errorMessage = "That file already exists. Choose Save… again and use a new filename; existing files are never replaced."
                return
            }
            self.downloading = true
            self.bridge.request("downloadFile", params: ["remotePath": file.path, "localPath": target.path]) { [weak self] result in
                guard let self, self.sessionID == token else { return }
                self.downloading = false
                switch result {
                case .success:
                    guard FileManager.default.fileExists(atPath: target.path) else {
                        self.errorMessage = "The download was acknowledged, but its destination file is missing."
                        return
                    }
                    self.notice = "Saved \(target.lastPathComponent) to \(target.deletingLastPathComponent().path)."
                case .failure(let error): self.errorMessage = "Download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func startTerminal() {
        guard connected, terminalState == "stopped" || terminalState == "error" else { return }
        terminalState = "starting"
        terminalStatus = "Opening an interactive SSH shell…"
        let token = sessionID
        bridge.request("terminalStart") { [weak self] result in
            guard let self, self.sessionID == token else { return }
            if case .failure(let error) = result {
                self.terminalState = "error"
                self.terminalStatus = error.localizedDescription
                self.errorMessage = "Terminal failed: \(error.localizedDescription)"
            }
        }
    }

    func sendTerminalLine() {
        guard connected, terminalState == "running", terminalInput.utf8.count <= 65_535 else { return }
        let input = terminalInput
        terminalInput = ""
        writeTerminal(input + "\n")
    }

    func interruptTerminal() { writeTerminal("\u{0003}") }

    private func writeTerminal(_ text: String) {
        guard connected, terminalState == "running" else { return }
        let token = sessionID
        bridge.request("terminalWrite", params: ["text": text]) { [weak self] result in
            guard let self, self.sessionID == token else { return }
            if case .failure(let error) = result { self.errorMessage = "Terminal input failed: \(error.localizedDescription)" }
        }
    }

    func stopTerminal() {
        guard terminalState == "running" || terminalState == "starting" else { return }
        terminalState = "stopping"
        let token = sessionID
        bridge.request("terminalStop") { [weak self] result in
            guard let self, self.sessionID == token else { return }
            switch result {
            case .success: self.terminalState = "stopped"; self.terminalStatus = "SSH terminal stopped."
            case .failure(let error): self.errorMessage = "Could not stop the terminal: \(error.localizedDescription)"
            }
        }
    }

    func copySSH() {
        guard let command = terminalCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        notice = "SSH command copied. Paste it into your terminal to open this workspace."
    }

    func dismissError() { errorMessage = nil }
    func dismissNotice() { notice = nil }

    private func receive(_ event: String, _ payload: [String: Any]) {
        guard state != .disconnected else { return }
        switch event {
        case "machineState":
            guard let raw = payload["state"] as? String, let value = MachineState(rawValue: raw) else { return }
            state = value
            if let text = payload["message"] as? String { status = text }
            if value == .error || value == .disconnected {
                verified = false
                terminalState = "stopped"
                filesLoading = false
                previewLoading = false
                downloading = false
            }
        case "terminalOutput":
            guard let text = payload["text"] as? String else { return }
            terminalOutput += text
            if terminalOutput.count > 200_000 { terminalOutput = "[Earlier terminal output omitted]\n" + String(terminalOutput.suffix(150_000)) }
        case "terminalState":
            if let value = payload["state"] as? String { terminalState = value }
            terminalStatus = payload["message"] as? String ?? "Terminal \(terminalState)."
        case "error": fail(payload["message"] as? String ?? "The bridge reported an error.")
        default: break
        }
    }

    private func resetSession() {
        verified = false
        identity = [:]
        entries = []
        selectedFile = nil
        preview = ""
        previewLoading = false
        filesLoading = false
        downloading = false
        browsingPath = ""
        terminalState = "stopped"
        terminalOutput = ""
        terminalInput = ""
        terminalStatus = "Terminal has not been started."
        listingID = UUID()
        previewID = UUID()
    }

    private func fail(_ message: String) {
        timeout?.cancel()
        state = .error
        verified = false
        status = "Machine connection needs attention."
        terminalState = "stopped"
        filesLoading = false
        previewLoading = false
        downloading = false
        errorMessage = message
    }
}
