import asyncio
import tempfile
import os
import sys
import shutil
import unittest
from pathlib import Path
from unittest.mock import patch
from perch.machine import Machine
from perch.transport import Connection, RpcError


class MachineTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.events = []
        self.machine = Machine(lambda e, p: self.events.append((e, p)))
        self.mock = patch.object(Connection, 'ssh', return_value=[sys.executable, str(Path(__file__).with_name('fake_ssh.py')), '-T'])
        self.mock.start()
        self.identity = await self.machine.connect({'host': 'LOCAL-FIXTURE-NOT-SSH', 'workspace': str(self.root)})

    async def asyncTearDown(self):
        await self.machine.disconnect()
        self.mock.stop()
        self.temp.cleanup()

    async def test_identity_without_agent(self):
        self.assertTrue(self.identity['hostname'])
        self.assertTrue(self.identity['user'])
        self.assertEqual(self.identity['workspace'], str(self.root))
        self.assertEqual(self.machine.state, 'ready')

    async def test_identity_probe_without_hostname_executable(self):
        # Minimal guest-like PATH intentionally has no hostname executable.
        # The fixture uses an absolute Python path and /bin/sh, so only the
        # real probe's external commands must be present here.
        tools = self.root / 'minimal-bin'
        tools.mkdir()
        for name in ('uname', 'id'):
            executable = shutil.which(name)
            self.assertIsNotNone(executable, name + ' is needed for the local probe test')
            (tools / name).symlink_to(executable)
        with patch.dict(os.environ, {'PATH': str(tools)}):
            self.assertIsNone(shutil.which('hostname'))
            identity = await self.machine.connect({'host': 'fixture', 'workspace': str(self.root)})
        self.assertTrue(identity['hostname'])
        self.assertTrue(identity['user'])
        self.assertEqual(identity['workspace'], str(self.root))
        self.assertEqual(self.machine.state, 'ready')

    async def test_default_workspace_uses_login_directory(self):
        result = await self.machine.connect({'host': 'fixture', 'workspace': ''})
        self.assertTrue(result['workspace'].startswith('/'))
        self.assertEqual(self.machine.connection.workspace, result['workspace'])

    async def test_list_read_download_quoted_names(self):
        f = self.root / "a'; not a command.txt"
        f.write_text('hello machine')
        (self.root / 'folder').mkdir()
        listing = await self.machine.list_files(str(self.root))
        self.assertEqual(listing['entries'][0]['type'], 'directory')
        self.assertIn(str(f), [x['path'] for x in listing['entries']])
        preview = await self.machine.read_file(str(f))
        self.assertEqual(preview['text'], 'hello machine')
        out = self.root / 'copy.txt'
        await self.machine.download(str(f), str(out))
        self.assertEqual(out.read_bytes(), f.read_bytes())
        with self.assertRaises(ValueError):
            await self.machine.download(str(f), str(out))

    async def test_binary_and_missing_file(self):
        f = self.root / 'binary'
        f.write_bytes(b'abc\0xyz')
        with self.assertRaises(ValueError):
            await self.machine.read_file(str(f))
        with self.assertRaises(RpcError):
            await self.machine.read_file(str(self.root / 'missing'))

    async def test_terminal_stream_input_and_stop(self):
        # The client fixture must not inherit zsh/fish/custom startup files.
        with patch.dict(os.environ, {'SHELL': '/nonexistent/perch-test-shell', 'ENV': '/nonexistent/perch-test-env'}):
            await self.machine.terminal_start()
        await self.machine.terminal_write("printf 'PERCH_TERMINAL_FIXTURE\\n'\n")
        deadline = asyncio.get_running_loop().time() + 5
        while asyncio.get_running_loop().time() < deadline:
            output = ''.join(p['text'] for e, p in self.events if e == 'terminalOutput')
            if 'PERCH_TERMINAL_FIXTURE' in output:
                break
            await asyncio.sleep(.01)
        self.assertIn('PERCH_TERMINAL_FIXTURE', output, repr(self.events))
        with self.assertRaises(ValueError):
            await self.machine.terminal_start()
        await self.machine.terminal_stop()
        with self.assertRaises(ValueError):
            await self.machine.terminal_write('echo should not execute\n')

    async def test_disconnect_stops_terminal(self):
        await self.machine.terminal_start()
        process = self.machine.terminal
        await self.machine.disconnect()
        self.assertIsNotNone(process.returncode)
        self.assertEqual(self.machine.state, 'disconnected')

    async def test_output_limit_and_timeout(self):
        with self.assertRaises(ValueError):
            await self.machine.run('printf 123456789', limit=5)
        with self.assertRaises(asyncio.TimeoutError):
            await self.machine.run('exec sleep 20', timeout=.03)

    async def test_cancel_connection_does_not_publish_ready(self):
        started, release = asyncio.Event(), asyncio.Event()
        async def slow_probe(*args, **kwargs):
            started.set()
            await release.wait()
            return b'host\nuser\nLinux\naarch64\n/tmp\n'
        with patch.object(self.machine, 'run', side_effect=slow_probe):
            pending = asyncio.create_task(self.machine.connect({'host': 'fixture', 'workspace': '/tmp'}))
            await started.wait()
            await self.machine.disconnect()
            release.set()
            with self.assertRaises(RpcError):
                await pending
        self.assertEqual(self.machine.state, 'disconnected')

    async def test_invalid_remote_path(self):
        for path in ['relative', '/tmp/\ninvalid']:
            with self.assertRaises(ValueError):
                await self.machine.list_files(path)
