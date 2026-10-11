# Validation status

## Automated checks

Run:

```sh
python3 -m unittest discover -s tests -v
python3 -m compileall -q perch tests
swift test --package-path mac
swift build --package-path mac
```

The initial 14 Python tests were executed on Linux with Python 3.12. They cover SSH argument validation, safe quoting, identity parsing, default workspace, file listing/preview/download, no-overwrite behavior, binary/missing files, subprocess output limits/timeouts, shell input/output/close and cancelled-connection stale-state rejection, and SIGTERM cleanup of the local shell subprocess. A fifteenth test verifies that the identity probe works without a separate `hostname` executable.

On 2026-10-11, the current source passed all 15 Python tests with Python 3.13.5 on macOS 26.6.2 arm64. Python bytecode compilation passed. The macOS Swift 6.4 run passed all 7 support tests and built the `PerchMac` product.

The explicit local SSH fixture uses a clean POSIX shell and simulates the exact requested GNU find record format on client platforms. Its GNU-find records were separately compared with real GNU find on Linux for regular files, quotes/Unicode, hidden directories and symlinks. It does **not** establish real SSH authentication, a remote PTY or an Omarchy connection. The live checks below provide separate evidence. No real machine credential is included in this repository.

## Live acceptance on 2026-10-11

With an existing authorized SSH identity and strict host-key verification, the Python bridge confirmed a Linux guest's identity and absolute workspace. It listed 22 workspace entries, previewed the public `/etc/os-release` text, downloaded it to a new temporary Mac file and compared the bytes, then received `pwd` output from a real SSH shell and stopped the shell. The temporary download was removed.

The native macOS window started disconnected, displayed a real SSH probe failure without showing a verified identity, then reached **Ready** with the guest identity after the probe switched from `hostname` to `uname -n`. Its Files tab listed the real workspace; its Terminal tab showed a real remote prompt and stopped the shell. The desktop card correctly remained disconnected.

Native GUI text preview, Save-dialog download, and terminal line input were not confirmed: accessibility-based text assignment did not update the app's input bindings during this run. Their underlying bridge operations passed the live checks above. Unknown-host and missing-credential GUI behavior, Ctrl-C, network interruption, and repeated UI stress tests remain on the manual checklist. This was a Mac-to-Linux guest check, not Windows acceptance. Local connection details, credentials, screenshots and logs are excluded from the repository.

## Manual acceptance checklist

1. Build and run the native app; inspect the machine-centered main window.
2. Try invalid host input, unknown host keys and missing credentials. Each must fail clearly; no simulated connected state.
3. With an already authorized working SSH identity, connect and compare hostname/user/architecture/workspace with the intended guest.
4. Browse a disposable folder; preview text; cancel the Save dialog, then download to a new filename and compare bytes. Existing local files must remain unchanged.
5. Start the shell, wait for the actual remote prompt, explicitly enter `pwd`, and compare the directory. Interrupt a harmless long-running command with Ctrl-C; close and reopen.
6. Interrupt the network link and verify a terminal error/exit, with no automatic command replay.
7. Exercise repeated connect/disconnect, fast navigation, stale file callbacks, canceled dialogs and app exit during an active terminal.
8. Capture real Mac screenshots. Desktop viewing/control must not be marked passed: it is not implemented in this prototype.

Do not publish screenshots, machine identities, IP addresses, SSH configuration, host keys, credentials or local runtime logs from acceptance testing.

## Client-platform fixture correction

The first native test pass found 3 Python fixture issues: macOS BSD find does not implement GNU `-printf`; macOS temporary paths may resolve through a canonical filesystem alias; and an interactive zsh without a PTY can wait during startup. The production target remains an Omarchy/Linux guest.

The revised fixture explicitly models the GNU-find wire format, uses resolved temporary paths, and selects a clean `/bin/sh` independent of the user's shell/startup files. Tests launch it through the current Python executable rather than requiring a restored executable bit. The real SSH terminal still requests `-tt` and uses the remote user's shell. The current 15-test suite passes on Linux and macOS. No tests were removed or skipped.
