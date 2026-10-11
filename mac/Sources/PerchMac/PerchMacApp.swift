import AppKit
import PerchSupport
import SwiftUI

@main
@MainActor
struct PerchMacApp: App {
    @StateObject private var model = MachineModel()
    var body: some Scene {
        WindowGroup("Perch") {
            MachineView(model: model)
                .frame(minWidth: 980, minHeight: 690)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
        }
        .defaultSize(width: 1140, height: 800)
        .commands { CommandGroup(replacing: .newItem) { } }
    }
}

@MainActor
struct MachineView: View {
    @ObservedObject var model: MachineModel
    @State private var section = "Machine"
    @State private var showDiagnostics = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if let message = model.errorMessage { banner(message, error: true, dismiss: model.dismissError) }
                if let message = model.notice { banner(message, error: false, dismiss: model.dismissNotice) }
                switch section {
                case "Files": files
                case "Terminal": terminal
                default: machine
                }
                Divider()
                DisclosureGroup(isExpanded: $showDiagnostics) {
                    ScrollView {
                        Text(model.diagnostics.isEmpty ? "No bridge stderr output." : model.diagnostics)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 110)
                } label: {
                    Text("Bridge diagnostics · stderr").font(.caption).foregroundStyle(.secondary)
                }.padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 11) {
                    Image(systemName: "server.rack").font(.system(size: 27)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Perch").font(.system(size: 26, weight: .semibold, design: .rounded))
                        Text("Your machine, within reach").font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("NATIVE PROTOTYPE").font(.system(size: 10, weight: .bold, design: .monospaced))
                    Text("Live access is shown only after a real SSH handshake.").font(.caption).foregroundStyle(.secondary)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 12) {
                    heading("MACHINE CONNECTION", "network")
                    field("SSH host or alias", "my-machine", $model.host)
                    field("Remote workspace (optional)", "Leave empty for the SSH login directory", $model.workspace)
                    Text("Uses your existing SSH configuration and authentication. No agent is required.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(!model.editable)
                HStack {
                    Button(model.state == .error ? "Retry connection" : "Connect") { model.connect() }
                        .buttonStyle(.borderedProminent).disabled(!model.editable)
                    if model.state != .disconnected { Button("Disconnect") { model.disconnect() } }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    heading("LOCAL BRIDGE", "externaldrive")
                    field("Existing Python 3.9+", "/usr/bin/python3", $model.pythonPath)
                    field("Perch project root", "Folder containing perch/bridge.py", $model.projectRoot)
                    Button("Choose folder…") { model.chooseRoot() }
                    Text("Set PERCH_ROOT at launch, or choose the project folder. No runtime is installed automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(!model.editable)
                Divider()
                VStack(alignment: .leading, spacing: 11) {
                    heading("SYSTEM TERMINAL", "arrow.up.forward.app")
                    Button { model.copySSH() } label: { Label("Copy SSH command", systemImage: "terminal") }
                        .disabled(model.terminalCommand == nil)
                    Text("Paste into your terminal for interactive login or full-screen tools. Perch only copies this command.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20)
        }.frame(width: 300).background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Circle().fill(model.state == .ready && !model.verified ? Color.orange : model.state.color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.state == .ready && !model.verified ? "Verifying" : model.state.rawValue.capitalized).font(.headline)
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if model.state == .connecting { ProgressView().controlSize(.small) }
                Text("MACHINE · SSH").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
            Picker("Workspace section", selection: $section) {
                Text("Machine").tag("Machine")
                Text("Files").tag("Files")
                Text("Terminal").tag("Terminal")
            }.pickerStyle(.segmented)
        }.padding(20)
    }

    private var machine: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "desktopcomputer").font(.system(size: 42, weight: .light)).foregroundStyle(Color.accentColor)
                Text(model.connected ? "One machine. A few useful doors." : "Connect to the system itself.")
                    .font(.system(size: 29, weight: .semibold, design: .rounded))
                Text("See the machine's identity, browse its files, and open a real SSH shell. An AI agent is optional and is not part of this connection.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.connected {
                    VStack(spacing: 0) {
                        identityRow("Hostname", model.identity["hostname"] ?? "Unknown")
                        identityRow("User", model.identity["user"] ?? "Unknown")
                        identityRow("Kernel", model.identity["kernel"] ?? "Not reported")
                        identityRow("Architecture", model.identity["architecture"] ?? "Not reported")
                        identityRow("Workspace", model.identity["workspace"] ?? "Unknown")
                        identityRow("Transport", model.identity["transport"] ?? "ssh")
                    }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    Label("No verified machine identity yet.", systemImage: "link.badge.plus").foregroundStyle(.secondary)
                    Text("Choose the local Perch folder and Python interpreter, then connect. Leave the workspace empty to use the SSH login directory. Authentication failures remain visible; there is no demo session.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button { section = "Files" } label: { Label("Browse files", systemImage: "folder") }
                    Button { section = "Terminal" } label: { Label("Open terminal view", systemImage: "terminal") }
                }
                VStack(alignment: .leading, spacing: 9) {
                    Label("Desktop · not connected", systemImage: "display").font(.headline)
                    Text("Network desktop access is not connected. Use your existing virtual-machine console or desktop client outside Perch. Perch has not installed a desktop service or opened any ports.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                Text("Native prototype. Real connection and build verification must be recorded separately; this screen never substitutes sample output for a live machine.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: 630, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading).padding(32)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var files: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.goUp() } label: { Image(systemName: "arrow.up") }.disabled(!model.canGoUp || model.filesLoading)
                Text(model.browsingPath.isEmpty ? "Connect to browse the remote workspace" : model.browsingPath)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                Spacer()
                if model.filesLoading { ProgressView().controlSize(.small) }
                Button { model.listFiles() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!model.connected || model.filesLoading).help("Refresh remote directory")
            }.padding(14)
            Divider()
            HSplitView {
                List(model.entries) { file in
                    Button { model.open(file) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: file.icon).foregroundStyle(file.type == "directory" ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.name).lineLimit(1)
                                Text(file.type == "file" ? ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file) : file.type)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if file.type == "directory" { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                        }.padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!model.connected)
                        .listRowBackground(model.selectedFile?.id == file.id ? Color.accentColor.opacity(0.10) : Color.clear)
                }.frame(minWidth: 210, idealWidth: 260)
                VStack(alignment: .leading, spacing: 12) {
                    if let file = model.selectedFile {
                        HStack {
                            Text(file.name).font(.headline).textSelection(.enabled)
                            Spacer()
                            if model.downloading { ProgressView().controlSize(.small) }
                            Button("Save…") { model.download(file) }
                                .disabled(!model.connected || model.downloading || file.type != "file")
                        }
                        Text(file.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        if model.previewTruncated { Label("Preview truncated; download for the complete file.", systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
                        Divider()
                        if model.previewLoading { ProgressView("Reading remote file…") }
                        ScrollView([.vertical, .horizontal]) {
                            Text(model.preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        Label("Select a file to preview it", systemImage: "doc.text.magnifyingglass").foregroundStyle(.secondary)
                        Text("Directories open on click. Text previews are read-only; Save… downloads a regular file to a new local filename.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }.padding(18).frame(minWidth: 290, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SSH text console").font(.headline)
                    Text(model.terminalStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.terminalState == "running" || model.terminalState == "starting" {
                    Button("Stop shell") { model.stopTerminal() }
                } else {
                    Button("Start shell") { model.startTerminal() }.buttonStyle(.borderedProminent)
                        .disabled(!model.connected || model.terminalState == "stopping")
                }
            }
            Text("Basic text view of a real interactive SSH shell, not a full terminal emulator. Use your terminal app for passwords, editors, cursor-based tools, and full-screen programs.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.terminalOutput.isEmpty ? "No terminal output. Start shell to connect." : TerminalText.display(model.terminalOutput))
                            .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        Color.clear.frame(height: 1).id("terminal-bottom")
                    }.padding(14)
                }
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: model.terminalOutput) { _ in proxy.scrollTo("terminal-bottom", anchor: .bottom) }
            }
            HStack {
                TextField("Type a shell command; Return sends the line", text: $model.terminalInput)
                    .font(.system(.body, design: .monospaced)).textFieldStyle(.roundedBorder)
                    .onSubmit { model.sendTerminalLine() }.disabled(model.terminalState != "running")
                Button("Send line") { model.sendTerminalLine() }
                    .disabled(model.terminalState != "running" || model.terminalInput.utf8.count > 65_535)
                Button("Ctrl-C") { model.interruptTerminal() }.disabled(model.terminalState != "running")
            }
            Text("Commands run only when you send them. A shell command can change the remote machine. Perch does not auto-run commands or request passwords.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func identityRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 9)
    }
    private func field(_ label: String, _ hint: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(hint, text: binding).textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced)).accessibilityLabel(label)
        }
    }
    private func heading(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
    }
    private func banner(_ text: String, error: Bool, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: error ? "exclamationmark.triangle.fill" : "info.circle").foregroundStyle(error ? Color.orange : Color.accentColor)
            Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss")
        }.padding(12).background((error ? Color.orange : Color.accentColor).opacity(0.08))
    }
}
