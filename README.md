# Perch

A machine-first macOS client prototype for an existing Omarchy system.

Perch connects to the machine itself. No coding agent needs to be installed. The current scope is machine identity, file access and a basic interactive shell. It does not modify operating-system settings or provision remote services.

## Implemented

- SwiftUI macOS interface with machine connection and identity status.
- Existing SSH alias/host connection with strict host-key verification.
- Remote hostname, login user, OS, architecture and working directory.
- Directory browsing, text preview and explicit file download.
- Interactive SSH shell channel with streamed text, line input, Ctrl-C and close.
- Copy an SSH command for use in an existing system terminal.

## Important limits

This is source for an early prototype, not a production-ready remote desktop application.

- **No desktop viewing/control yet.** There is no bundled VNC/RDP client and no automatically installed guest service.
- The terminal is a basic text transcript, not a VT emulator. Full-screen editors, cursor positioning, resize and rich colors are not supported.
- Downloads are implemented; uploads, rename and deletion are not.
- Agent execution is a potential later layer on the same machine, not part of this initial prototype.
- Authentication uses existing SSH credentials in noninteractive batch mode. If those do not work, connection fails visibly. Perch does not ask for or save passwords, enroll host keys or generate keys. Use your established SSH setup process or an existing system terminal for interactive sign-in.

## Requirements

**Mac**

- macOS 13 or newer
- Xcode or an existing Swift 5.9+ toolchain
- An existing Python 3.9+ interpreter (a real runtime dependency; not guaranteed on a stock Mac)
- `/usr/bin/ssh` and existing user-managed SSH configuration

**Omarchy machine**

- Already configured and authorized SSH access and trusted host key
- Standard GNU utilities (`id`, `uname`, `find`, `head`, `cat`) and a shell
- No agent application or agent account required

No dependency installer runs. The Python code uses only the standard library; the Swift package has no third-party dependencies.

## Run

Keep the whole repository on the Mac, since the Python bridge is part of the app runtime.

```sh
cd /absolute/path/to/Perch
python3 -m unittest discover -s tests -v
swift test --package-path mac
swift build --package-path mac
PERCH_ROOT="$PWD" swift run --package-path mac
```

In the app, choose your existing Python executable and the project folder containing `perch/bridge.py`. Enter an existing SSH host/alias. Leave the workspace blank to use the SSH login directory, or specify an absolute remote directory.

See [mac/README.md](mac/README.md) for the native UI workflow and [docs/VALIDATION.md](docs/VALIDATION.md) for test boundaries.

## Connection behavior

- Uses system OpenSSH with `BatchMode=yes`, `StrictHostKeyChecking=yes`, `ClearAllForwardings=yes`, and `ForwardAgent=no`.
- Does not create listeners, change firewall/network settings, accept unknown host keys, save credentials or install guest software.
- The initial check runs fixed read-only identity commands. “Ready” means the last identity probe succeeded, not continuous uptime monitoring.
- Each file operation makes its own bounded SSH request. Interactive shell output/exit tracks its separate SSH channel.
- Typed terminal input runs under the remote user's normal permissions and can change remote state. Perch does not automatically replay it after a failure.
- Closing a channel is not proof that remote background jobs stopped.
- Downloads are explicit, capped at 100 MiB and 120 seconds, and never overwrite existing local files. Text previews are limited to 1 MiB. Binary files are downloaded rather than previewed. Files are not auto-opened.
- Directory browsing includes hidden files. Names that cannot round-trip as UTF-8 are omitted. Remote account filesystem permissions apply.
- Machine profiles, credentials and command history are not persisted by Perch. SSH/the remote shell can maintain their own normal logs/history.

## Local bridge interface

Run `python3 -m perch.bridge` and send newline-delimited JSON commands with unique IDs. This is local subprocess IPC, not a network listener.

```json
{"id":1,"method":"machineConnect","params":{"host":"my-existing-alias","workspace":""}}
{"id":2,"method":"listFiles","params":{"path":"/home/example"}}
{"id":3,"method":"readFile","params":{"path":"/home/example/README.txt"}}
{"id":4,"method":"terminalStart","params":{}}
{"id":5,"method":"terminalWrite","params":{"text":"pwd\n"}}
{"id":6,"method":"terminalWrite","params":{"text":"\u0003"}}
{"id":7,"method":"terminalStop","params":{}}
{"id":8,"method":"machineDisconnect","params":{}}
```

Wait for each required result. `machineConnect` returns actual identity and the canonical workspace. Other methods: `downloadFile {remotePath,localPath}`. Events include `machineState`, `terminalState` and `terminalOutput`. A terminal-start result only means the SSH process was launched: wait for a real remote shell prompt.

## Development

- `perch/machine.py`: machine identity, files and terminal channels
- `perch/transport.py`: SSH argument validation
- `perch/bridge.py`: local JSON-line IPC
- `mac/`: SwiftUI app and Swift support tests
- `tests/`: Python tests and explicitly labeled local SSH fixture

The portable fixture explicitly simulates the requested GNU find record format and executes other commands in a clean local POSIX shell. It does not perform SSH authentication or allocate a remote PTY. The client tests do not require GNU find on macOS and do not claim support for macOS remote hosts. Passing fixture tests is not an end-to-end Omarchy or native UI result. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) covers Perch's own source. OpenSSH, Python, Swift and Omarchy remain under their respective licenses.
