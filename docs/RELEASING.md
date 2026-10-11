# Building and releasing the macOS preview

## Scope and trust

The initial distribution is **Apple Silicon arm64 only, macOS 13+**, with explicit preview versions such as `v0.1.0-alpha.1`. GitHub CI makes **ad-hoc-signed, unnotarized test artifacts**. It has no Developer ID identity and does not create or publish releases automatically. Ad-hoc signing does not establish an Apple-verified developer identity or guarantee Gatekeeper acceptance.

Final release assets may be signed and notarized on an authorized Mac using an already-installed Developer ID Application identity and an existing Keychain notarytool profile. No private keys are exported, no GitHub signing secrets are created, and no credentials are generated or saved by these scripts. A missing identity/profile is a setup gap for the owner to resolve through a safe existing Apple workflow, not permission to collect secrets in chat or weaken security.

Neither path removes quarantine, disables Gatekeeper or changes security settings. Do not describe a file as notarized until its Apple submission is Accepted, tickets are stapled/validated and Gatekeeper assessment passes. Final hashes must be computed **after** signing and stapling; they differ from CI's ad-hoc artifacts.

## Self-contained application

The DMG contains `Perch.app` and an Applications shortcut. The application includes its own CPython runtime and bridge. End users need no Python installation, source checkout, `PERCH_ROOT` or developer settings. Existing SSH access remains required.

The runtime is Astral's `python-build-standalone` CPython 3.13.16, release 20261009, `aarch64-apple-darwin-install_only`. It is an upstream Astral build, **not a PSF-provided binary**. The exact URL and SHA256 are committed in `packaging/runtime.env`; every build verifies the archive before extraction. There are no pip/build-package dependencies. Runtime updates require a reviewed URL/hash and matching license update.

The complete install-only runtime is retained, including its own license notices. Additional component license texts are vendored from the checksum-verified matching full distribution in `packaging/runtime-licenses/`; `PROVENANCE.json` identifies both archives, source commit and individual license hashes. The upstream metadata references a zlib-ng license absent from its full archive; the matching dependency-source notice is included conservatively with its separate verified source recorded. Perch's MIT license does not replace the runtime/component licenses.

The application launches its embedded interpreter with `-I -S -B -u` and an absolute bootstrap path. The bootstrap admits only the adjacent bundled `perch` package. Python/DYLD environment overrides and `PERCH_ROOT` are removed; existing `HOME` and `SSH_AUTH_SOCK` are retained for SSH. A marked packaged app with missing runtime resources fails clearly instead of falling back to an external interpreter. Developer `swift run` remains available separately.

## Local native build

On an Apple Silicon Mac with Xcode installed:

```sh
bash scripts/build_macos.sh v0.1.0-alpha.1
```

This downloads the fixed runtime to the ignored build cache, verifies SHA256, runs Python and Swift tests, builds the native executable, assembles the app, checks architecture/dependencies, signs contained Mach-O files then the app ad-hoc, and verifies the signature. It tests relocated bundled IPC with no source path/system Python, checks that the native executable survives initial launch, creates a DMG, mounts it read-only and repeats those checks, then emits checksums. The launch check does not establish rendered GUI behavior or live SSH acceptance.

No Homebrew or pip installation is performed. Outputs go to `dist/`:

- `Perch-v0.1.0-alpha.1-macos-arm64.dmg`
- `Perch-v0.1.0-alpha.1-macos-arm64.app.zip`
- `SHA256SUMS`
- `BUILD-METADATA.json`
- `RELEASE-NOTES.md`

Versioned binaries are never overwritten automatically. A local uncommitted build is marked `source_dirty: true`; release jobs reject it. The application/DMG build requires macOS and cannot be certified by Linux tests.

## GitHub Actions

The workflow runs on PRs, main pushes, manual runs and version-tag pushes. The Linux job checks the portable core; the native `macos-15` job asserts arm64, tests the bundled Python and Swift code, then builds and validates the package. All jobs have only `contents: read`. GitHub-provided actions are pinned to full commit SHAs, and checkout does not persist credentials.

A tag push produces tested artifacts only. It does not publish an unnotarized release or overwrite final signed assets. The authorized maintainer completes the public prerelease only after matching-commit CI and the local signing/notarization checks below succeed. Existing releases must not be silently overwritten on retries.

## Optional local Developer ID signing and notarization

Start from the exact source commit tested by CI and its verified app ZIP (or a clean matching local build). Obtain the ZIP's hash from the verified SHA256SUMS, not from a guessed filename. On the authorized Apple Silicon Mac:

```sh
python3 scripts/sign_notarize_macos.py \
  --input-zip dist/Perch-v0.1.0-alpha.1-macos-arm64.app.zip \
  --input-sha256 '<exact verified ZIP SHA256>' \
  --expected-commit '<complete tested source commit>' \
  --identity 'Developer ID Application: YOUR EXISTING IDENTITY' \
  --notary-profile 'YOUR EXISTING KEYCHAIN PROFILE' \
  --output dist/notarized-v0.1.0-alpha.1
```

`PERCH_SIGN_IDENTITY` and `PERCH_NOTARY_PROFILE` can supply the same public identity/profile names. They are not passwords. There are deliberately no Apple password, API-key, certificate export/import or `store-credentials` options. The script verifies that the requested valid identity is a Developer ID Application identity, not an Apple Development identity. It requires a clean build of the expected source SHA and uses an untouched input ZIP plus private working copies.

Without a notary profile, the script stops after producing a clearly named `-unnotarized.dmg`, a false notarization status and checksums. It does not claim success or publish anything. If the named profile does not exist, submission fails visibly; the owner must provide an authorized profile separately. Use a fresh output directory for another attempt.

With an existing profile, the script signs contained code and the outer app using hardened runtime and secure timestamps, submits the signed app ZIP, requires Accepted, staples and validates the app, then repacks/signs/submits the DMG and staples/validates it. It performs code-signature and Gatekeeper checks, mounts the final DMG read-only, verifies the contained app ticket and runs packaged smoke checks. All steps must pass before final checksums and post-notarization BUILD-METADATA.json are written.

The app's sealed internal build metadata records the signing stage before notarization. The release's external BUILD-METADATA.json records the later Accepted/stapled/Gatekeeper state without mutating the signed app. `_private/` contains local notary receipts and pre-notarization material; never publish it.

### Public prerelease gate

Before the authorized maintainer publishes:

1. Confirm the exact commit's GitHub Actions run succeeded and source/metadata match.
2. Confirm final external metadata says `signature: Developer ID Application`, `notarized: true`, both staple fields true and Gatekeeper accepted.
3. Check final SHA256SUMS, code signatures/tickets and DMG mount/readback. Confirm required live-machine and GUI acceptance separately.
4. Create/update only the intended GitHub **prerelease** with the final DMG, stapled-app ZIP, final SHA256SUMS and final BUILD-METADATA.json. Clearly state arm64, minimum macOS and that signing occurred on an authorized Mac from the same CI-tested commit.
5. Download the published DMG and compare its final hash before announcing completion.

Never substitute the initial CI artifact or pre-notarization hash. No Intel or Universal compatibility is claimed.

## Upstream references

- https://github.com/astral-sh/python-build-standalone/releases/tag/20261009
- https://github.com/astral-sh/python-build-standalone/blob/main/docs/distributions.rst
- https://docs.python.org/3/using/cmdline.html
- https://docs.python.org/3/license.html
- https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/
