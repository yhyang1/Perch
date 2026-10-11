import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
spec = importlib.util.spec_from_file_location('perch_sign', SCRIPTS / 'sign_notarize_macos.py')
signing = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(SCRIPTS))
try:
    spec.loader.exec_module(signing)
finally:
    sys.path.remove(str(SCRIPTS))


class SigningTests(unittest.TestCase):
    def test_requires_exact_input_hash(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'app.zip'
            path.write_bytes(b'test input')
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertEqual(signing.verify_digest(path, digest), digest)
            for wrong in ('0' * 64, 'not a hash'):
                with self.assertRaises(ValueError):
                    signing.verify_digest(path, wrong)

    def test_only_clean_matching_source(self):
        sha = 'a' * 40
        metadata = {'source_commit': sha, 'source_dirty': False, 'architecture': 'arm64', 'version': 'v0.1.0-alpha.1'}
        signing.validate_source(metadata, sha)
        for key, value in [('source_dirty', True), ('source_commit', 'b' * 40), ('architecture', 'x86_64'), ('version', 'latest')]:
            with self.assertRaises(ValueError):
                signing.validate_source({**metadata, key: value}, sha)

    def test_development_identity_cannot_substitute_for_distribution(self):
        fingerprint = 'A' * 40
        development = '1) ' + fingerprint + ' "Apple Development: Example"'
        with self.assertRaises(ValueError):
            signing.select_identity(fingerprint, development)
        distribution = '1) ' + fingerprint + ' "Developer ID Application: Example (TEAM)"'
        self.assertEqual(signing.select_identity(fingerprint.lower(), distribution), fingerprint)
        self.assertEqual(signing.select_identity('Developer ID Application: Example (TEAM)', distribution), fingerprint)

    def test_zip_traversal_rejected_without_extracting(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'bad.zip'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('../escape', b'no')
            with self.assertRaises(ValueError):
                signing.validate_zip_paths(path)
            self.assertFalse((Path(folder).parent / 'escape').exists())

    def test_notarization_requires_accepted_and_uses_only_existing_profile(self):
        with tempfile.TemporaryDirectory() as folder:
            private = Path(folder)
            for status in ('Invalid', 'In Progress'):
                response = subprocess.CompletedProcess([], 0, json.dumps({'status': status}), '')
                with patch.object(signing.subprocess, 'run', return_value=response) as call:
                    with self.assertRaises(RuntimeError):
                        signing.notarize(Path('test.zip'), 'existing-test-profile', private, 'app')
                    args = call.call_args.args[0]
                    self.assertIn('--keychain-profile', args)
                    self.assertNotIn('store-credentials', args)
                    self.assertNotIn('--password', args)
            response = subprocess.CompletedProcess([], 0, '{"status":"Accepted"}', '')
            with patch.object(signing.subprocess, 'run', return_value=response):
                self.assertEqual(signing.notarize(Path('test.zip'), 'existing-test-profile', private, 'app')['status'], 'Accepted')

    def test_signature_requires_hardened_runtime_and_timestamp(self):
        details = 'Authority=Developer ID Application: Example\nflags=0x10000(runtime)\nTimestamp=example\nTeamIdentifier=TEAM\n'
        good = subprocess.CompletedProcess([], 0, '', details)
        with patch.object(signing.subprocess, 'run', return_value=good):
            self.assertTrue(signing.signature_details(Path('Perch.app'))['hardened_runtime'])
        for missing in ('Timestamp=example\n', 'flags=0x10000(runtime)\n', 'Authority=Developer ID Application: Example\n'):
            with patch.object(signing.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '', details.replace(missing, ''))):
                with self.assertRaises(ValueError):
                    signing.signature_details(Path('Perch.app'))
