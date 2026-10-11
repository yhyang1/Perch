"""Safe SSH invocation. Never reads credentials or changes SSH setup."""
import re
from dataclasses import dataclass


@dataclass(frozen=True)
class Connection:
    host: str
    workspace: str

    def __post_init__(self):
        if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.@-]*', self.host):
            raise ValueError('Use an existing SSH alias or user@host (no options/URLs).')
        if not self.workspace.startswith('/') or any(ord(c) < 32 for c in self.workspace):
            raise ValueError('Remote workspace must be an absolute path without control characters.')

    def ssh(self):
        return ['/usr/bin/ssh', '-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2',
                '-o', 'ClearAllForwardings=yes', '-o', 'ForwardAgent=no', self.host]


class RpcError(Exception):
    pass
