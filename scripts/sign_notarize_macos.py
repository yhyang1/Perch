#!/usr/bin/env python3
"""Optional local Developer ID signing. Never exports keys or creates credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile

from build_macos import capture, macho_files, parse_version, run, verify_native_code


def verify_digest(path, expected):
    if not re.fullmatch(r'[0-9a-fA-F]{64}', expected):
        raise ValueError('Supply the exact input app ZIP SHA256 from its verified build.')
    actual = hashlib.sha256(Path(path).read_bytes()).hexdigest()
    if actual.lower() != expected.lower():
        raise ValueError('Input ZIP checksum mismatch; nothing was signed.')
    return actual


def validate_source(metadata, expected):
    if not re.fullmatch(r'[0-9a-f]{40}', expected):
        raise ValueError('Expected source commit must be a complete lowercase Git SHA.')
    if metadata.get('source_commit') != expected or metadata.get('source_dirty') is not False:
        raise ValueError('The input must be a clean build of the exact expected source commit.')
    if metadata.get('architecture') != 'arm64':
        raise ValueError('This signing path supports the tested arm64 package only.')
    parse_version(metadata.get('version', ''))


def validate_zip_paths(path):
    with zipfile.ZipFile(path) as archive:
        for member in archive.infolist():
            name = member.filename
            if name.startswith('/') or '..' in Path(name).parts:
                raise ValueError('Unsafe archive path: ' + name)


def select_identity(requested, listing):
    for line in listing.splitlines():
        match = re.search(r'\b([A-Fa-f0-9]{40}) "(Developer ID Application: [^"]+)"', line)
        if match and requested in (match.group(1), match.group(1).lower(), match.group(2)):
            return match.group(1)
    raise ValueError('The requested usable Developer ID Application identity was not found. No key was created or exported.')


def signature_details(app):
    result = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(app)], check=True,
                            capture_output=True, text=True)
    output = result.stderr + result.stdout
    if 'Authority=Developer ID Application:' not in output or '(runtime)' not in output:
        raise ValueError('Developer ID and hardened-runtime signature verification failed.')
    if not re.search(r'^Timestamp=.+', output, flags=re.MULTILINE):
        raise ValueError('A secure signing timestamp was not recorded.')
    team = re.search(r'^TeamIdentifier=(.+)$', output, flags=re.MULTILINE)
    if not team or team.group(1) in ('not set', ''):
        raise ValueError('Missing Developer ID team identifier.')
    return {'team_identifier': team.group(1), 'hardened_runtime': True, 'secure_timestamp': True}


def notarize(archive, profile, private_directory, label):
    # A profile name refers only to an existing login-keychain credential. There
    # are deliberately no password/API-key flags or store-credentials commands.
    result = subprocess.run(['/usr/bin/xcrun', 'notarytool', 'submit', str(archive),
        '--keychain-profile', profile, '--wait', '--output-format', 'json'], capture_output=True, text=True)
    (private_directory / (label + '-submit.json')).write_text(result.stdout)
    (private_directory / (label + '-stderr.txt')).write_text(result.stderr)
    if result.returncode:
        raise RuntimeError('Notarization submission failed. Inspect the private local log; an existing authorized Keychain profile may be required. No credentials were created.')
    receipt = json.loads(result.stdout)
    if receipt.get('status') != 'Accepted':
        raise RuntimeError('Apple notarization did not return Accepted. Stop and inspect the private submission result.')
    return receipt


def image(app, target, work, identity):
    stage = work / (target.stem + '-contents')
    stage.mkdir()
    run(['/usr/bin/ditto', app, stage / 'Perch.app'])
    (stage / 'Applications').symlink_to('/Applications')
    run(['/usr/bin/hdiutil', 'create', '-volname', 'Perch', '-srcfolder', stage,
         '-format', 'UDZO', '-fs', 'HFS+', target])
    run(['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp', target])
    run(['/usr/bin/codesign', '--verify', '--strict', target])


def checksums(directory, files):
    (directory / 'SHA256SUMS').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in files))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-zip', type=Path, required=True)
    parser.add_argument('--input-sha256', required=True)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--identity', default=os.environ.get('PERCH_SIGN_IDENTITY'),
                        help='Existing Developer ID Application identity name or certificate SHA1; alternatively PERCH_SIGN_IDENTITY.')
    parser.add_argument('--notary-profile', default=os.environ.get('PERCH_NOTARY_PROFILE'),
                        help='Existing Keychain notarytool profile. Omit to stop with clearly unnotarized signed preview files.')
    parser.add_argument('--output', type=Path, required=True, help='New output directory; existing files are never replaced.')
    args = parser.parse_args()
    if os.uname().sysname != 'Darwin' or os.uname().machine != 'arm64':
        raise SystemExit('Use the authorized native Apple Silicon Mac for signing.')
    if not args.identity:
        raise SystemExit('Provide an existing Developer ID Application identity; no signing credential is generated.')
    source = args.input_zip.resolve()
    input_digest = verify_digest(source, args.input_sha256)
    validate_zip_paths(source)
    identity = select_identity(args.identity, capture(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning']))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    private = output / '_private'
    private.mkdir(mode=0o700)
    with tempfile.TemporaryDirectory(prefix='Perch Developer ID ') as folder:
        work = Path(folder)
        run(['/usr/bin/ditto', '-x', '-k', source, work])
        app = work / 'Perch.app'
        resources = app / 'Contents/Resources'
        metadata_path = resources / 'BUILD-METADATA.json'
        metadata = json.loads(metadata_path.read_text())
        validate_source(metadata, args.expected_commit)
        verify_native_code(app)
        metadata.update({'signature': 'Developer ID Application', 'notarized': False,
                         'signing_origin': 'authorized local Mac', 'input_app_zip_sha256': input_digest})
        # Build-stage status is sealed here; final release metadata is written
        # separately after ticket stapling, without mutating the signed app.
        metadata_path.write_text(json.dumps(metadata, indent=2) + '\n')
        for binary in macho_files(app):
            run(['/usr/bin/codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp', binary])
        run(['/usr/bin/codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp', app])
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
        metadata.update(signature_details(app))
        stem = 'Perch-' + metadata['version'] + '-macos-arm64'
        pre_dmg = private / (stem + '-unnotarized.dmg')
        image(app, pre_dmg, work, identity)
        app_zip = private / (stem + '-signed-app.zip')
        run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, app_zip])
        if not args.notary_profile:
            final = output / pre_dmg.name
            shutil.copy2(pre_dmg, final)
            meta = output / 'BUILD-METADATA.json'
            meta.write_text(json.dumps(metadata, indent=2) + '\n')
            checksums(output, [final, meta])
            print('Signed, hardened and timestamped, but NOT NOTARIZED. No release was published. Supply an existing authorized notary profile and a new output directory to complete notarization.')
            return
        notarize(app_zip, args.notary_profile, private, 'app')
        run(['/usr/bin/xcrun', 'stapler', 'staple', app])
        run(['/usr/bin/xcrun', 'stapler', 'validate', app])
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
        run(['/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', app])
        final_dmg = private / (stem + '.dmg')
        image(app, final_dmg, work, identity)
        notarize(final_dmg, args.notary_profile, private, 'dmg')
        run(['/usr/bin/xcrun', 'stapler', 'staple', final_dmg])
        run(['/usr/bin/xcrun', 'stapler', 'validate', final_dmg])
        run(['/usr/bin/codesign', '--verify', '--strict', final_dmg])
        run(['/usr/sbin/spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', final_dmg])
        mount = work / 'verified-mounted-dmg'
        mount.mkdir()
        attached = False
        try:
            run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, final_dmg])
            attached = True
            run(['/usr/bin/xcrun', 'stapler', 'validate', mount / 'Perch.app'])
            run(['/usr/bin/codesign', '--verify', '--deep', '--strict', mount / 'Perch.app'])
            run(['/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', mount / 'Perch.app'])
            run([resources / 'python/bin/python3', '-I', '-S', '-B', Path(__file__).with_name('smoke_bundle.py'), mount / 'Perch.app'])
        finally:
            if attached:
                run(['/usr/bin/hdiutil', 'detach', mount])
        run(['/usr/bin/hdiutil', 'verify', final_dmg])
        final_zip = private / (stem + '.app.zip')
        run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, final_zip])
        metadata.update({'notarized': True, 'app_stapled': True, 'dmg_stapled': True,
                         'gatekeeper_assessment': 'accepted', 'release_metadata_stage': 'after signing and notarization'})
        meta = output / 'BUILD-METADATA.json'
        meta.write_text(json.dumps(metadata, indent=2) + '\n')
        published_dmg, published_zip = output / final_dmg.name, output / final_zip.name
        os.link(final_dmg, published_dmg)  # exclusive publication; ticket bytes/xattrs retained
        os.link(final_zip, published_zip)
        checksums(output, [published_dmg, published_zip, meta])
        print('Notarized/stapled app and DMG verified. Final hashes:', output / 'SHA256SUMS')
        print('Nothing was uploaded to GitHub. Publish only these final files after matching-commit CI and release approval. Never publish _private logs or pre-notarization images.')


if __name__ == '__main__':
    main()
