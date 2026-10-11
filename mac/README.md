# Perch for macOS — machine-first prototype

A dependency-free SwiftUI client for verified SSH identity, workspace file browsing, read-only text previews, explicit downloads, and a real interactive SSH shell shown in a basic text console. Machine connection does not require an AI agent.

The UI starts disconnected and uses no simulated machine identity or output. The native Swift package built and 7 support tests passed on macOS arm64 (Swift 6.4). See [the validation record](../docs/VALIDATION.md) for completed live SSH and native UI checks, along with the checks still outstanding.

## Build on a Mac

Requires macOS 13+, an existing Swift 5.9+ toolchain, an existing Python 3.9+ interpreter, and the complete Perch source folder. No third-party Swift packages are used.

From the top-level project folder:

```sh
swift build --package-path mac
swift test --package-path mac
PERCH_ROOT="$PWD" swift run --package-path mac PerchMac
```

Or, after building:

```sh
PERCH_ROOT="$PWD" ./mac/.build/debug/PerchMac
```

This produces a development executable, not a signed/notarized distributable `.app` bundle. Packaging, signing, sandboxing, icons, and automatic updates remain outside this prototype.

## Connect

- Set **Perch project root** using `PERCH_ROOT` or **Choose folder…**; it must contain `perch/bridge.py`.
- Set an existing Python 3.9+ executable. `/usr/bin/python3` is only the default and may not exist on every Mac. The app never installs a runtime.
- Enter your SSH host/alias. Leave **Remote workspace** empty to use the actual SSH login directory, or supply an absolute path. The username is never guessed.
- Configure SSH host keys and noninteractive authentication outside the app first. The connection form never asks for a password, private key, port, or SSH options. Use your existing SSH configuration.
- Click **Connect**. Files and terminal controls remain unavailable until `machineConnect` returns verified machine identity. Setup has a 60-second UI deadline; failures remain visible.

The main screen displays hostname, user, kernel, architecture, workspace, and transport returned by the machine. It does not infer these from the form. A successful handshake fills the canonical workspace for later SSH-command copying.

## Files

Directories open on click. Selecting a file requests a read-only text preview; binary or otherwise unsupported previews may fail visibly. A truncated preview is labeled. **Save…** downloads a regular file to an explicitly selected path. **Existing local files are never replaced**, even if the native save dialog offers an overwrite confirmation. Choose a new filename instead. A download is reported successful only after the destination exists locally. Downloads are not opened automatically.

The UI hides parent navigation at the connected workspace root. This is a navigation convenience, not a workspace jail. Remote account permissions govern file access. There are no file-upload, remote-edit, or remote-delete controls in this prototype.

## Terminal

**Start shell** starts a real interactive SSH shell. The view is a basic text console, not a full VT/xterm emulator. ANSI decorations are stripped for readability; cursor positioning, screen redraws, terminal resizing, local echo emulation, and full-screen applications are not supported.

Typing a line and pressing Return/**Send line** sends that user-entered text plus a newline. **Ctrl-C** sends the interrupt control character. Perch never generates shell commands for this channel. User-entered commands can modify the machine. Use a normal terminal for passwords, editors, and full-screen tools. **Copy SSH command** copies a POSIX-shell-quoted command and never runs it or launches another app. The copied command requires known host keys, disables agent forwarding, and clears configured forwardings while allowing normal interactive authentication.

**Stop shell** requests terminal shutdown. Disconnecting does not prove that remote processes already started have stopped. Terminal output is bounded in memory and not saved; configuration, previews, and sessions are also not persisted.

## Desktop

The main UI states that **network desktop access is not connected**. Use an existing virtual-machine console or desktop client outside Perch. No VNC/RDP address box or fake remote-control success is presented. No desktop service is installed and no ports or tunnels are configured.

Agent execution may be added as a separate layer later; it is not part of this interface.

## Bridge protocol

The client launches the selected Python executable directly with `-u -m perch.bridge`, using the project root as its working directory. It never constructs a local shell launch command. stdin and stdout use newline-delimited JSON, with request IDs and `result`/`error`; stderr is displayed separately under **Bridge diagnostics**.

- `machineConnect {host,workspace}` → machine identity
- `machineDisconnect {}`
- `listFiles {path}` → `{path,entries:[{name,path,type,size}]}`
- `readFile {path}` → `{path,text,truncated}`
- `downloadFile {remotePath,localPath}` → `{localPath,bytes}`
- `terminalStart {}`, `terminalWrite {text}`, `terminalStop {}`
- Events: `machineState`, `terminalOutput`, `terminalState`, and `error`

The byte-oriented framer preserves UTF-8 across read boundaries and limits JSON lines to 32 MiB, accommodating JSON-escaped previews and directory lists. Typed terminal lines are capped at 64 KiB. Unknown/malformed stdout data never becomes machine output. Protocol failures and subprocess exit are visible. Reconnect invalidates stale file reads, listing callbacks, downloads, and old save panels.

## Native acceptance checklist

- Build and run `swift test`; no external Swift dependencies should download.
- Verify missing Python, missing bridge, failed SSH authentication, and an unknown SSH host key fail visibly without showing a connected state.
- Confirm identity comes from a successful real machine handshake and does not require Codex.
- Browse directories, refresh, click multiple files quickly, inspect empty/large/binary files, and verify stale reads do not replace newer selections.
- Cancel a save dialog and verify no download; download to a new path; attempt an existing filename and verify refusal.
- Start the actual SSH shell; type a harmless explicit command; verify output, Ctrl-C, stopping, restarting, and disconnecting during startup.
- Copy an SSH command with spaces/apostrophes in its workspace and verify quoting.
- Test resizing, long text, diagnostics, quitting, repeated clicks, and reconnecting while a save panel is open.
- Confirm the desktop card remains honest about its incomplete integration.

Included unit-test sources cover input validation, safe shell quoting, fragmented Unicode JSON, multiple/oversized frames, and text-only terminal formatting. All 7 tests passed in the native macOS check.
