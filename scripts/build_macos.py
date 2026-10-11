#!/usr/bin/env python3
"""Native arm64 preview build. No signing identities, secrets or installs needed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MACHO = {bytes.fromhex(h) for h in ('feedface', 'feedfacf', 'cefaedfe', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def run(args, **kwargs):
    print('+', ' '.join(str(x) for x in args), flush=True)
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def capture(args):
    return subprocess.check_output([str(x) for x in args], text=True).strip()


def parse_version(value):
    match = re.fullmatch(r'v(\d+\.\d+\.\d+)-alpha\.(\d+)', value)
    if not match:
        raise ValueError('This unsigned preview pipeline accepts vX.Y.Z-alpha.N versions only.')
    return match.group(1), match.group(2)


def macho_files(root):
    root = root.resolve()
    found = []
    for path in root.rglob('*'):
        if path.is_symlink():
            # Upstream relative symlinks are allowed only within this app.
            if not path.resolve().is_relative_to(root):
                raise ValueError('Bundle symlink escapes application: ' + str(path))
            continue
        if path.is_file():
            with path.open('rb') as stream:
                if stream.read(4) in MACHO:
                    found.append(path)
    return sorted(found, key=lambda p: len(p.parts), reverse=True)


def verify_native_code(app):
    for binary in macho_files(app):
        architectures = capture(['/usr/bin/lipo', '-archs', binary]).split()
        if architectures != ['arm64']:
            raise ValueError('Expected arm64-only Mach-O: ' + str(binary) + ' ' + str(architectures))
        linked = capture(['/usr/bin/otool', '-L', binary]).splitlines()[1:]
        for line in linked:
            dependency = line.strip().split(' (', 1)[0]
            if dependency.startswith('/') and not dependency.startswith(('/usr/lib/', '/System/Library/')):
                raise ValueError('External library dependency in app: ' + dependency)
        commands = capture(['/usr/bin/otool', '-l', binary]).splitlines()
        for index, line in enumerate(commands):
            if line.strip() == 'cmd LC_RPATH':
                pathline = next((x.strip() for x in commands[index + 1:index + 5] if x.strip().startswith('path ')), '')
                rpath = pathline.removeprefix('path ').split(' (offset', 1)[0]
                if rpath.startswith('/') and not rpath.startswith(('/usr/lib/', '/System/Library/')):
                    raise ValueError('External runtime search path: ' + rpath)


def remove_build_toolchain_rpath(binary):
    """SwiftPM adds an absolute Xcode rpath even when no Xcode dylib is linked."""
    commands = capture(['/usr/bin/otool', '-l', binary]).splitlines()
    for index, line in enumerate(commands):
        if line.strip() != 'cmd LC_RPATH':
            continue
        pathline = next((x.strip() for x in commands[index + 1:index + 5]
                         if x.strip().startswith('path ')), '')
        rpath = pathline.removeprefix('path ').split(' (offset', 1)[0]
        if rpath.startswith('/') and not rpath.startswith(('/usr/lib/', '/System/Library/')):
            run(['/usr/bin/install_name_tool', '-delete_rpath', rpath, binary])


def smoke(app):
    run([sys.executable, '-B', ROOT / 'scripts/smoke_bundle.py', app])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    version, build_number = parse_version(args.version)
    if sys.platform != 'darwin' or capture(['/usr/bin/uname', '-m']) != 'arm64':
        raise SystemExit('Build on native macOS arm64; cross-built/universal artifacts are not supported.')
    runtime = args.runtime.resolve()
    if not (runtime / 'bin/python3').is_file():
        raise SystemExit('The verified standalone runtime is missing.')
    os.chdir(ROOT)
    os.environ['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
    os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
    run([sys.executable, '-B', '-m', 'unittest', 'discover', '-s', 'tests', '-v'])
    run(['/usr/bin/swift', 'test', '--package-path', 'mac'])
    run(['/usr/bin/swift', 'build', '--package-path', 'mac', '-c', 'release', '--arch', 'arm64'])
    products = Path(capture(['/usr/bin/swift', 'build', '--package-path', 'mac', '-c', 'release', '--arch', 'arm64', '--show-bin-path']))
    output = ROOT / 'dist'
    output.mkdir(exist_ok=True)
    stem = 'Perch-' + args.version + '-macos-arm64'
    paths = [output / (stem + '.dmg'), output / (stem + '.app.zip')]
    if any(p.exists() for p in paths):
        raise SystemExit('Versioned output already exists. Inspect/remove your previous local build before rebuilding.')
    with tempfile.TemporaryDirectory(prefix='Perch build ', dir=ROOT / 'build') as temporary:
        work = Path(temporary)
        app = work / 'Perch.app'
        contents = app / 'Contents'
        resources = contents / 'Resources'
        (contents / 'MacOS').mkdir(parents=True)
        resources.mkdir()
        shutil.copy2(products / 'PerchMac', contents / 'MacOS/PerchMac')
        remove_build_toolchain_rpath(contents / 'MacOS/PerchMac')
        shutil.copytree(runtime, resources / 'python', symlinks=True)
        bridge = resources / 'bridge'
        bridge.mkdir()
        shutil.copy2(ROOT / 'packaging/bootstrap.py', bridge / 'bootstrap.py')
        shutil.copytree(ROOT / 'perch', bridge / 'perch', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        shutil.copytree(ROOT / 'packaging/runtime-licenses', resources / 'ThirdPartyLicenses')
        shutil.copy2(ROOT / 'LICENSE', resources / 'Perch-LICENSE.txt')
        info = {
            'CFBundleExecutable': 'PerchMac', 'CFBundleIdentifier': 'io.github.yhyang1.perch',
            'CFBundleName': 'Perch', 'CFBundleDisplayName': 'Perch', 'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': version, 'CFBundleVersion': build_number,
            'LSMinimumSystemVersion': '13.0', 'NSHighResolutionCapable': True,
            'LSApplicationCategoryType': 'public.app-category.developer-tools',
            'PerchBundledRuntime': True, 'PerchDisplayVersion': args.version,
            'NSHumanReadableCopyright': 'Copyright © 2026 Perch contributors. MIT; bundled runtime has separate licenses.'
        }
        with (contents / 'Info.plist').open('wb') as stream:
            plistlib.dump(info, stream)
        metadata = {
            'version': args.version, 'source_commit': capture(['git', 'rev-parse', 'HEAD']),
            'source_dirty': bool(capture(['git', 'status', '--porcelain'])),
            'architecture': 'arm64', 'minimum_macos': '13.0',
            'signature': 'ad-hoc', 'notarized': False,
            'python_version': sys.version.split()[0],
            'python_runtime_sha256': '3338fcd572a670ec45ac9ef75480b95595ea9b6b5dd320952fcf5df185089941',
            'xcode': capture(['/usr/bin/xcodebuild', '-version']),
            'swift': capture(['/usr/bin/swift', '--version']),
        }
        (resources / 'BUILD-METADATA.json').write_text(json.dumps(metadata, indent=2) + '\n')
        verify_native_code(app)
        # Sign leaf Mach-O files first, then the outer bundle. No user identity
        # or certificate is accessed, and no hardened/notarized claim is made.
        for binary in macho_files(app):
            run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', binary])
        run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', app])
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
        # Test relocation and no source/system-Python dependency after signing.
        relocated = work / 'Relocated copy with spaces' / 'Perch.app'
        relocated.parent.mkdir()
        run(['/usr/bin/ditto', app, relocated])
        smoke(relocated)
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', relocated])
        stage = work / 'image-root'
        stage.mkdir()
        run(['/usr/bin/ditto', app, stage / 'Perch.app'])
        (stage / 'Applications').symlink_to('/Applications')
        (stage / 'READ ME.txt').write_text(
            'Perch ' + args.version + ' — Apple Silicon preview\n\n'
            'Drag Perch.app to Applications. Python and the bridge are included.\n'
            'This build is ad-hoc signed, not Developer ID signed or notarized.\n'
            'macOS or your organization may block it. No security checks are disabled.\n'
            'If you require verified distribution, wait for a notarized release.\n'
            'Source: https://github.com/yhyang1/Perch\n')
        run(['/usr/bin/hdiutil', 'create', '-volname', 'Perch', '-srcfolder', stage,
             '-format', 'UDZO', '-fs', 'HFS+', paths[0]])
        mount = work / 'mounted-image'
        mount.mkdir()
        try:
            run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, paths[0]])
            run(['/usr/bin/codesign', '--verify', '--deep', '--strict', mount / 'Perch.app'])
            smoke(mount / 'Perch.app')
        finally:
            if os.path.ismount(mount):
                run(['/usr/bin/hdiutil', 'detach', mount])
        run(['/usr/bin/hdiutil', 'verify', paths[0]])
        run(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, paths[1]])
        (output / 'BUILD-METADATA.json').write_text(json.dumps(metadata, indent=2) + '\n')
        (output / 'SHA256SUMS').write_text(''.join(
            hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n'
            for p in paths + [output / 'BUILD-METADATA.json']))
        notes = ('# Perch ' + args.version + '\n\nApple Silicon (arm64), macOS 13+. '
                 'Python and bridge included; no source checkout or Python install needed.\n\n'
                 '**Preview: ad-hoc signed, not Developer ID signed or notarized.** '
                 'macOS/managed-device policy may block launch. No quarantine removal or security bypass is included.\n\n'
                 'Mount the DMG and drag Perch.app to Applications. Existing SSH setup is required. '
                 'Desktop control and agent execution are not included.\n\n'
                 'Source commit: `' + metadata['source_commit'] + '`\n\n'
                 'The matching workflow ran Python/Swift tests, architecture/link audits, code-signature verification, '
                 'relocated bundled-bridge smoke checks and read-only DMG mount checks before uploading these assets. '
                 'These packaging checks do not replace live SSH or GUI acceptance. See SHA256SUMS and BUILD-METADATA.json.\n')
        (output / 'RELEASE-NOTES.md').write_text(notes)
    print('Built:', *paths, sep='\n')


if __name__ == '__main__':
    main()
