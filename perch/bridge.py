"""Native UI IPC. JSON lines on stdin/stdout; no network listener."""
import asyncio
import json
import sys
import signal
from .machine import Machine


MAX_FRAME_BYTES = 32 * 1024 * 1024


def output(value):
    frame = json.dumps(value, ensure_ascii=False)
    if len(frame.encode('utf-8')) > MAX_FRAME_BYTES:
        error = {'message': 'Response exceeds the 32 MiB IPC limit. Browse a smaller directory or download the file.'}
        value = ({'id': value['id'], 'error': error} if 'id' in value else {'event': 'error', 'payload': error})
        frame = json.dumps(value)
    print(frame, flush=True)


async def main():
    loop = asyncio.get_running_loop()
    owner = asyncio.current_task()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, owner.cancel)
    reader = asyncio.StreamReader(limit=1024 * 1024 + 1)
    pipe, _ = await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    machine = Machine(lambda event, payload: output({'event': event, 'payload': payload}))
    tasks = set()
    ids = set()
    async def dispatch(message):
        ident = message.get('id')
        try:
            method, params = message['method'], message.get('params', {})
            if method == 'machineConnect':
                result = await machine.connect(params)
            elif method == 'machineDisconnect':
                result = await machine.disconnect()
            elif method == 'listFiles':
                result = await machine.list_files(params['path'])
            elif method == 'readFile':
                result = await machine.read_file(params['path'])
            elif method == 'downloadFile':
                result = await machine.download(params['remotePath'], params['localPath'])
            elif method == 'terminalStart':
                result = await machine.terminal_start()
            elif method == 'terminalWrite':
                result = await machine.terminal_write(params['text'])
            elif method == 'terminalStop':
                result = await machine.terminal_stop()
            else:
                raise ValueError('Unknown bridge method: ' + str(method))
            output({'id': ident, 'result': result})
        except Exception as exc:
            output({'id': ident, 'error': {'message': str(exc)}})
    try:
        while True:
            line = await reader.readline()
            if not line:
                break
            try:
                if len(line) > 1024 * 1024:
                    raise ValueError('Bridge request exceeds 1 MiB.')
                message = json.loads(line)
                if not isinstance(message, dict) or not isinstance(message.get('id'), (int, str)):
                    raise ValueError('Each bridge command needs a string or integer id.')
                ident = (type(message['id']).__name__, message['id'])
                if ident in ids:
                    raise ValueError('Duplicate bridge command id rejected.')
                ids.add(ident)
                task = asyncio.create_task(dispatch(message))
                tasks.add(task)
                task.add_done_callback(tasks.discard)
            except Exception as exc:
                output({'error': {'message': str(exc)}})
    finally:
        pipe.close()
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await machine.disconnect()


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except asyncio.CancelledError:
        pass
