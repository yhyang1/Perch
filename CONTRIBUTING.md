# Contributing

Perch is an early machine-first macOS client for an existing Omarchy system.

1. Keep machine access independent of any agent. Agent execution is a second layer on the same machine.
2. Do not weaken SSH host verification, collect passwords, install services, open listeners or change system/network settings implicitly.
3. Distinguish unit fixtures, real transport checks and end-to-end machine/UI checks in every change summary.
4. Use a disposable workspace for manual terminal/file tests. Do not commit machine addresses, account identifiers, credentials, local logs or screenshots containing private information.
5. Run `python3 -m unittest discover -s tests -v` and `python3 -m compileall -q perch tests`.
6. On macOS, also run `swift test --package-path mac` and `swift build --package-path mac`, launch the app and exercise interrupted/repeated flows. Linux passing tests do not establish native UI correctness.

Python uses only the standard library. Swift has no third-party dependencies. No dependency installation is required by the repository itself.

Before adding desktop viewing/control, document the actual guest protocol and authorization requirements. An external URL button is not a remote desktop implementation.
