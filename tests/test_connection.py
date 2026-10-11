import unittest
from perch.transport import Connection


class ConnectionTests(unittest.TestCase):
    def test_no_host_options_or_shell(self):
        for host in ['-oProxyCommand=evil', 'host;echo hi', 'ssh://host', 'host\nother', '']:
            with self.assertRaises(ValueError):
                Connection(host, '/tmp')

    def test_ssh_options_are_conservative(self):
        c = Connection('user@host', "/tmp/a'; touch bad; '")
        self.assertIn('StrictHostKeyChecking=yes', c.ssh())
        self.assertIn('BatchMode=yes', c.ssh())
        self.assertIn('ClearAllForwardings=yes', c.ssh())
        self.assertIn('ForwardAgent=no', c.ssh())
        self.assertEqual(c.ssh()[-1], 'user@host')

    def test_workspace_validation(self):
        for path in ['relative', '/tmp/\nfoo']:
            with self.assertRaises(ValueError):
                Connection('host', path)

