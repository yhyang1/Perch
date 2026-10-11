#!/usr/bin/env python3
"""LOCAL TEST FIXTURE ONLY: no SSH authentication and no remote PTY.

The product targets a Linux/GNU guest. This fixture implements only the exact
GNU find output contract that the adapter requests, so client tests do not
accidentally depend on macOS providing GNU find. Other commands run locally in
a clean POSIX shell. This is not evidence of support for macOS remote hosts.
"""
import os
import shlex
import stat
import sys


def main():
    command = sys.argv[-1]
    tokens = shlex.split(command)
    if tokens and tokens[0] == 'find':
        expected_tail = ['-mindepth', '1', '-maxdepth', '1', '-printf', '%y\\0%s\\0%p\\0']
        if len(tokens) != 9 or tokens[1] != '--' or tokens[3:] != expected_tail:
            raise ValueError('Unsupported GNU find contract in LOCAL fixture: ' + repr(tokens))
        with os.scandir(tokens[2]) as entries:
            for entry in entries:
                info = entry.stat(follow_symlinks=False)
                mode = info.st_mode
                kind = 'd' if stat.S_ISDIR(mode) else 'f' if stat.S_ISREG(mode) else 'l' if stat.S_ISLNK(mode) else 'o'
                fields = [kind.encode(), str(info.st_size).encode(), os.fsencode(entry.path)]
                sys.stdout.buffer.write(b'\0'.join(fields) + b'\0')
        return
    environment = dict(os.environ)
    environment.update({'SHELL': '/bin/sh', 'ENV': '/dev/null', 'BASH_ENV': '/dev/null'})
    environment.pop('CDPATH', None)
    os.execve('/bin/sh', ['/bin/sh', '-c', command], environment)


if __name__ == '__main__':
    main()
