# Validation status

## Automated checks

Run:

```sh
python3 -m unittest discover -s tests -v
python3 -m compileall -q perch tests
swift test --package-path mac
swift build --package-path mac
```

The 14 Python tests were executed on Linux with Python 3.12. They cover SSH argument validation, safe quoting, identity parsing, default workspace, file listing/preview/download, no-overwrite behavior, binary/missing files, subprocess output limits/timeouts, shell input/output/close and cancelled-connection stale-state rejection, and SIGTERM cleanup of the local shell subprocess.

The explicit local SSH fixture uses a clean POSIX shell and simulates the exact requested GNU find record format on client platforms. Its GNU-find records were separately compared with real GNU find on Linux for regular files, quotes/Unicode, hidden directories and symlinks. It does **not** establish real SSH authentication, a remote PTY or an Omarchy connection. The Swift package built and its 7 support tests passed on macOS arm64 with Swift 6.4. UI and real SSH acceptance remain separate checks. No real machine credential is included in this repository.

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

The revised fixture explicitly models the GNU-find wire format, uses resolved temporary paths, and selects a clean `/bin/sh` independent of the user's shell/startup files. Tests launch it through the current Python executable rather than requiring a restored executable bit. The real SSH terminal still requests `-tt` and uses the remote user's shell. All 14 tests pass on Linux after this change; revised macOS Python results await rerun. No tests were removed or skipped.
