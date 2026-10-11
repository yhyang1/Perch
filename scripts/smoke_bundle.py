#!/usr/bin/env python3
"""Exercise bundled IPC from an unrelated, hostile cwd with no developer config."""
import json
import os
from pathlib import Path
import plistlib
import select
import subprocess
import sys
import tempfile
import time


def smoke(app):
    app = Path(app).resolve()
    resources = app / 'Contents/Resources'
    with (app / 'Contents/Info.plist').open('rb') as stream:
        assert plistlib.load(stream)['PerchBundledRuntime'] is True
    python = resources / 'python/bin/python3'
    entry = resources / 'bridge/bootstrap.py'
    with tempfile.TemporaryDirectory(prefix='Perch untrusted cwd ') as folder:
        cwd = Path(folder)
        for name in ('perch.py', 'sitecustomize.py', 'usercustomize.py'):
            (cwd / name).write_text('raise RuntimeError("EXTERNAL CODE MUST NOT LOAD")\n')
        env = {'PATH': '/usr/bin:/bin', 'HOME': str(cwd), 'LANG': 'en_US.UTF-8',
               'PYTHONHOME': '/nonexistent/perch-poison', 'PYTHONPATH': str(cwd),
               'PERCH_ROOT': '/nonexistent/perch-poison'}
        process = subprocess.Popen([str(python), '-I', '-S', '-B', '-u', str(entry)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=cwd, env=env)
        try:
            request = {'id': 'packaged-smoke', 'method': 'health', 'params': {}}
            process.stdin.write((json.dumps(request) + '\n').encode())
            process.stdin.flush()
            deadline = time.monotonic() + 15
            response = None
            while time.monotonic() < deadline:
                ready, _, _ = select.select([process.stdout], [], [], max(0, deadline-time.monotonic()))
                if not ready:
                    break
                line = process.stdout.readline()
                if not line:
                    break
                message = json.loads(line)
                if message.get('id') == 'packaged-smoke':
                    response = message
                    break
            assert response == {'id': 'packaged-smoke', 'result': {'protocol': 1, 'implementation': 'perch.bridge'}}, response
            process.stdin.close()
            process.wait(timeout=5)
            assert process.returncode == 0, process.stderr.read().decode(errors='replace')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream and not stream.closed:
                    stream.close()
    print('Bundled bridge IPC passed from unrelated cwd with poisoned Python settings.')
    # A launch/survival check of the actual Swift executable, not screenshot or
    # live-machine GUI acceptance. It starts disconnected and runs no SSH command.
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('PYTHON', 'DYLD_')) and key != 'PERCH_ROOT'}
    with tempfile.TemporaryDirectory(prefix='Perch GUI launch ') as folder:
        application = subprocess.Popen([str(app / 'Contents/MacOS/PerchMac')],
            cwd=folder, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            time.sleep(3)
            assert application.poll() is None, application.stderr.read().decode(errors='replace')
            print('Native packaged executable survived initial launch; no GUI interaction is claimed.')
        finally:
            if application.poll() is None:
                application.terminate()
                try:
                    application.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    application.kill()
                    application.wait()
                    raise AssertionError('Packaged app did not terminate after the launch check.')
            application.stderr.close()


if __name__ == '__main__':
    smoke(sys.argv[1])
