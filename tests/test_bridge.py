import asyncio
import json
import io
from contextlib import redirect_stdout
from unittest.mock import patch
import os
import re
import signal
import sys
import tempfile
import unittest
from pathlib import Path


class BridgeLifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def test_sigterm_cleans_up_terminal_subprocess(self):
        fixture = str(Path(__file__).with_name('fake_ssh.py').resolve())
        code = ('import runpy; from perch.transport import Connection; '
                'Connection.ssh=lambda self: ' + repr([sys.executable, fixture, '-T']) + '; '
                'runpy.run_module("perch.bridge", run_name="__main__")')
        process = await asyncio.create_subprocess_exec(sys.executable, '-u', '-c', code,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        async def send(ident, method, params):
            process.stdin.write((json.dumps({'id': ident, 'method': method, 'params': params}) + '\n').encode())
            await process.stdin.drain()
        async def until(predicate):
            while True:
                line = await asyncio.wait_for(process.stdout.readline(), 5)
                self.assertTrue(line, 'Bridge ended unexpectedly')
                message = json.loads(line)
                if predicate(message):
                    return message
        try:
            with tempfile.TemporaryDirectory() as folder:
                await send('c', 'machineConnect', {'host': 'fixture', 'workspace': folder})
                result = await until(lambda m: m.get('id') == 'c')
                self.assertIn('result', result)
                await send('t', 'terminalStart', {})
                await until(lambda m: m.get('id') == 't')
                await send('w', 'terminalWrite', {'text': 'echo PERCH_TEST_PID:$$\n'})
                output = ''
                child_pid = None
                for _ in range(50):
                    event = await until(lambda m: m.get('event') == 'terminalOutput')
                    output += event['payload']['text']
                    match = re.search(r'PERCH_TEST_PID:(\d+)', output)
                    if match:
                        child_pid = int(match.group(1))
                        break
                self.assertIsNotNone(child_pid)
                os.kill(child_pid, 0)
                process.send_signal(signal.SIGTERM)
                await asyncio.wait_for(process.wait(), 5)
                self.assertEqual(process.returncode, 0, (await process.stderr.read()).decode())
                with self.assertRaises(ProcessLookupError):
                    os.kill(child_pid, 0)
        finally:
            if process.returncode is None:
                process.kill()
                await process.wait()


class BridgeFrameTests(unittest.TestCase):
    def test_escaped_oversized_response_becomes_small_error(self):
        from perch.bridge import output
        capture = io.StringIO()
        with patch('perch.bridge.MAX_FRAME_BYTES', 1024), redirect_stdout(capture):
            output({'id': 'preview', 'result': {'text': '\x01' * 500}})
        wire = capture.getvalue()
        self.assertLess(len(wire.encode()), 1024)
        message = json.loads(wire)
        self.assertEqual(message['id'], 'preview')
        self.assertIn('error', message)
