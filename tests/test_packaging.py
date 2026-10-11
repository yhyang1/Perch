import hashlib
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('perch_build', ROOT / 'scripts/build_macos.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class PackagingTests(unittest.TestCase):
    def test_only_explicit_alpha_versions(self):
        self.assertEqual(build.parse_version('v0.1.0-alpha.1'), ('0.1.0', '1'))
        for version in ('latest', 'v0.1.0', '../bad', 'v0.1.0-alpha.1; echo bad', 'v1.0.0-beta.1'):
            with self.assertRaises(ValueError):
                build.parse_version(version)

    def test_bundle_symlink_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / 'app'
            root.mkdir()
            (root / 'escape').symlink_to(Path(folder))
            with self.assertRaises(ValueError):
                build.macho_files(root)

    def test_macho_detection_allows_internal_symlinks(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            binary = root / 'python3.13'
            binary.write_bytes(bytes.fromhex('cffaedfe') + b'fixture, not executable')
            (root / 'python3').symlink_to('python3.13')
            (root / 'README').write_text('not a binary')
            self.assertEqual(build.macho_files(root), [binary.resolve()])

    def test_runtime_license_hashes_and_references(self):
        folder = ROOT / 'packaging/runtime-licenses'
        provenance = json.loads((folder / 'PROVENANCE.json').read_text())
        for filename, digest in provenance['files'].items():
            self.assertEqual(hashlib.sha256((folder / filename).read_bytes()).hexdigest(), digest, filename)
        for path in provenance['license_paths_from_python_json']:
            self.assertTrue((folder / Path(path).relative_to('licenses')).is_file(), path)
        self.assertIn('LICENSE.zlib-ng.txt', provenance['files'])

    def test_bootstrap_ignores_external_python_settings_and_cwd(self):
        with tempfile.TemporaryDirectory(prefix='Perch isolated entry ') as folder:
            root = Path(folder)
            bridge = root / 'resources' / 'bridge'
            bridge.mkdir(parents=True)
            shutil.copy2(ROOT / 'packaging/bootstrap.py', bridge / 'bootstrap.py')
            shutil.copytree(ROOT / 'perch', bridge / 'perch', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
            poison = root / 'poison'
            poison.mkdir()
            for name in ('perch.py', 'sitecustomize.py', 'usercustomize.py'):
                (poison / name).write_text('raise RuntimeError("must not execute")\n')
            environment = dict(os.environ, PYTHONHOME='/nonexistent/poison', PYTHONPATH=str(poison), PERCH_ROOT=str(poison))
            process = subprocess.Popen([sys.executable, '-I', '-S', '-B', '-u', str(bridge / 'bootstrap.py')],
                cwd=poison, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                process.stdin.write(b'{"id":"health","method":"health","params":{}}\n')
                process.stdin.flush()
                ready, _, _ = select.select([process.stdout], [], [], 10)
                self.assertTrue(ready, 'No isolated bridge response')
                response = json.loads(process.stdout.readline())
                self.assertEqual(response, {'id': 'health', 'result': {'protocol': 1, 'implementation': 'perch.bridge'}})
                process.stdin.close()
                process.wait(timeout=5)
                self.assertEqual(process.returncode, 0, process.stderr.read().decode())
                self.assertFalse(list(bridge.rglob('__pycache__')))
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                for stream in (process.stdin, process.stdout, process.stderr):
                    if stream and not stream.closed:
                        stream.close()

    def test_marked_bootstrap_does_not_fall_back_to_checkout(self):
        with tempfile.TemporaryDirectory() as folder:
            entry = Path(folder) / 'bootstrap.py'
            shutil.copy2(ROOT / 'packaging/bootstrap.py', entry)
            result = subprocess.run([sys.executable, '-I', '-S', '-B', str(entry)],
                cwd=ROOT, capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'bundled Perch bridge is missing', result.stderr)
