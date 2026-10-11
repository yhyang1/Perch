"""Machine-first SSH adapter. No agent installation or agent authentication needed."""
import asyncio
import os
import posixpath
import shlex
import tempfile
from pathlib import Path
from .transport import Connection, RpcError


class Machine:
    def __init__(self, emit):
        self.emit = emit
        self.connection = None
        self.state = 'disconnected'
        self.terminal = None
        self.terminal_tasks = []
        self.generation = 0

    def status(self, state, message=None):
        self.state = state
        self.emit('machineState', {'state': state, 'message': message})

    def path(self, value):
        if not isinstance(value, str) or not value.startswith('/') or any(ord(c) < 32 for c in value):
            raise ValueError('Use an absolute remote path without control characters.')
        return posixpath.normpath(value)

    async def run(self, command, limit=2 * 1024 * 1024, timeout=25):
        if not self.connection:
            raise ValueError('Connect to a machine first.')
        process = await asyncio.create_subprocess_exec(*(self.connection.ssh() + [command]),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        async def bounded(stream, maximum):
            result = bytearray()
            while True:
                chunk = await stream.read(65536)
                if not chunk:
                    return bytes(result)
                result.extend(chunk)
                if len(result) > maximum:
                    raise ValueError('Remote output exceeds prototype size limit.')
        async def collect():
            stdout, stderr = await asyncio.gather(bounded(process.stdout, limit), bounded(process.stderr, 65536))
            await process.wait()
            if process.returncode:
                raise RpcError('SSH operation failed (exit ' + str(process.returncode) + '): ' + stderr.decode(errors='replace'))
            return stdout
        try:
            return await asyncio.wait_for(collect(), timeout)
        finally:
            if process.returncode is None:
                process.kill()
                await process.wait()

    async def connect(self, params):
        if self.state == 'connecting':
            raise ValueError('Connection check already in progress.')
        workspace = params.get('workspace', '')
        connection = Connection(params['host'], self.path(workspace) if workspace else '/')
        self.generation += 1
        await self.terminal_stop()
        generation = self.generation
        self.connection = connection
        self.status('connecting')
        try:
            # Fixed read-only commands; no software installation, settings, or agent process.
            command = ('cd -- ' + shlex.quote(connection.workspace) + ' && ' if workspace else '') + 'hostname && id -un && uname -s && uname -m && pwd -P'
            raw = (await self.run(command, limit=65536)).decode(errors='replace').splitlines()
            if len(raw) != 5:
                raise RpcError('Unexpected system probe output; check login-shell banners.')
            if generation != self.generation:
                raise RpcError('Connection check was cancelled.')
            result = dict(zip(('hostname', 'user', 'kernel', 'architecture', 'workspace'), raw))
            self.connection = Connection(connection.host, self.path(result['workspace']))
            result['transport'] = 'ssh'
            self.status('ready', 'SSH identity check succeeded. Each file operation verifies its own connection.')
            return result
        except Exception as exc:
            if generation == self.generation:
                self.status('error', str(exc))
            raise

    async def list_files(self, path):
        path = self.path(path)
        raw = await self.run('find -- ' + shlex.quote(path) + " -mindepth 1 -maxdepth 1 -printf '%y\\0%s\\0%p\\0'", limit=4 * 1024 * 1024)
        fields = raw.split(b'\0')
        if fields[-1] != b'' or (len(fields) - 1) % 3:
            raise RpcError('Malformed directory response.')
        entries = []
        for i in range(0, len(fields) - 1, 3):
            try:
                remote = fields[i + 2].decode('utf-8')
            except UnicodeDecodeError:
                continue  # Invalid UTF-8 names cannot safely round-trip through the UI.
            entries.append({'name': posixpath.basename(remote), 'path': remote,
                'type': {'d': 'directory', 'f': 'file', 'l': 'symlink'}.get(fields[i].decode(), 'other'),
                'size': int(fields[i + 1])})
        entries.sort(key=lambda item: (item['type'] != 'directory', item['name'].lower()))
        return {'path': path, 'entries': entries}

    async def read_file(self, path):
        path = self.path(path)
        q = shlex.quote(path)
        raw = await self.run('test -f ' + q + ' && head -c 1048577 -- ' + q, limit=1048577)
        if b'\0' in raw:
            raise ValueError('Binary file: download it instead of showing a text preview.')
        return {'path': path, 'text': raw[:1048576].decode(errors='replace'), 'truncated': len(raw) > 1048576}

    async def download(self, remote, local):
        remote = self.path(remote)
        destination = Path(local).expanduser().absolute()
        if destination.exists():
            raise ValueError('Choose a new filename; existing local files are not overwritten.')
        # Explicit user-selected path; file browser is not restricted to an agent workspace.
        q = shlex.quote(remote)
        raw = await self.run('test -f ' + q + ' && head -c 104857601 -- ' + q,
                             limit=104857601, timeout=120)
        if len(raw) > 104857600:
            raise ValueError('Prototype download limit is 100 MiB.')
        name = None
        try:
            with tempfile.NamedTemporaryFile(dir=destination.parent, prefix='.perch-', delete=False) as output:
                name = output.name
                output.write(raw)
            os.link(name, destination)
            return {'localPath': str(destination), 'bytes': len(raw)}
        finally:
            if name:
                os.unlink(name)

    async def terminal_start(self):
        if self.state != 'ready' or not self.connection:
            raise ValueError('Complete the SSH machine check before opening a terminal.')
        if self.terminal and self.terminal.returncode is None:
            raise ValueError('A terminal is already running.')
        await self.terminal_stop()
        argv = self.connection.ssh()
        argv[argv.index('-T')] = '-tt'  # Request an actual remote PTY; never a new listener.
        command = 'cd -- ' + shlex.quote(self.connection.workspace) + ' && exec "${SHELL:-/bin/sh}" -i'
        process = await asyncio.create_subprocess_exec(*(argv + [command]), stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, env={**os.environ, 'TERM': 'dumb'})
        self.terminal = process
        async def stream(reader):
            import codecs
            decoder = codecs.getincrementaldecoder('utf-8')('replace')
            while True:
                chunk = await reader.read(4096)
                if not chunk:
                    final = decoder.decode(b'', final=True)
                    if final:
                        self.emit('terminalOutput', {'text': final})
                    break
                self.emit('terminalOutput', {'text': decoder.decode(chunk)})
        async def watch():
            await process.wait()
            if self.terminal is process:
                self.emit('terminalState', {'state': 'stopped' if process.returncode == 0 else 'error',
                    'message': 'SSH terminal exited: ' + str(process.returncode)})
        self.terminal_tasks = [asyncio.create_task(stream(process.stdout)), asyncio.create_task(stream(process.stderr)), asyncio.create_task(watch())]
        self.emit('terminalState', {'state': 'running', 'message': 'SSH process started; wait for the remote shell prompt.'})
        return {'started': True}

    async def terminal_write(self, text):
        if not self.terminal or self.terminal.returncode is not None:
            raise ValueError('No running SSH terminal.')
        if not isinstance(text, str) or len(text.encode()) > 65536:
            raise ValueError('Terminal input limit is 64 KiB.')
        self.terminal.stdin.write(text.encode())
        await self.terminal.stdin.drain()
        return {}

    async def terminal_stop(self):
        process, self.terminal = self.terminal, None
        if process and process.returncode is None:
            process.terminate()
            try:
                await asyncio.wait_for(process.wait(), 3)
            except asyncio.TimeoutError:
                process.kill()
                await process.wait()
        for task in self.terminal_tasks:
            task.cancel()
        await asyncio.gather(*self.terminal_tasks, return_exceptions=True)
        self.terminal_tasks = []
        self.emit('terminalState', {'state': 'stopped', 'message': 'Terminal closed. Remote background processes may continue.'})
        return {}

    async def disconnect(self):
        self.generation += 1
        await self.terminal_stop()
        self.connection = None
        self.status('disconnected')
        return {}
