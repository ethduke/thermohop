#!/usr/bin/env python3
"""Exercise setup with a PTY and disposable, synthetic Keychain credentials.

Run after `swift build -c release`: python3 Tests/setup.py
No Wi-Fi joins, permission requests, or real network passwords are used.
"""
import errno
import json
import os
import pathlib
import select
import signal
import subprocess
import tempfile
import termios
import time
import uuid

BINARY = pathlib.Path(__file__).resolve().parents[1] / '.build/release/thermohop'
PREFIX = 'th-test-' + uuid.uuid4().hex[:12]
SSIDS = [PREFIX + suffix for suffix in ('-router', '-phone', '-resume-r', '-resume-p')]
FAKE = 'synthetic-test-password-' + uuid.uuid4().hex
checks = 0


def check(condition, message):
    global checks
    assert condition, message
    checks += 1


def run(args, code=0, data=None):
    result = subprocess.run([str(BINARY), *args], input=data, capture_output=True,
                            timeout=15)
    assert result.returncode == code, 'Unexpected exit for ' + repr(args)
    return result


class Terminal:
    def __init__(self, args):
        self.pid, self.fd = os.forkpty()
        if self.pid == 0:
            os.execv(str(BINARY), [str(BINARY), *args])
        self.output = b''
        self.result = None

    def until(self, expected):
        deadline = time.monotonic() + 10
        while expected not in self.output:
            assert time.monotonic() < deadline, 'Terminal prompt timed out'
            if select.select([self.fd], [], [], .1)[0]:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        raise AssertionError('Terminal ended before expected prompt')
                    raise
                assert chunk, 'Terminal ended before expected prompt'
                self.output += chunk

    def send(self, value):
        os.write(self.fd, value)

    def echo(self):
        return bool(termios.tcgetattr(self.fd)[3] & termios.ECHO)

    def finish(self):
        deadline = time.monotonic() + 10
        while True:
            assert time.monotonic() < deadline, 'Terminal command timed out'
            if select.select([self.fd], [], [], .1)[0]:
                try:
                    chunk = os.read(self.fd, 65536)
                    self.output += chunk
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.result = os.waitstatus_to_exitcode(status)
                # Drain output written immediately before exit.
                while select.select([self.fd], [], [], 0)[0]:
                    try:
                        chunk = os.read(self.fd, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    self.output += chunk
                return self.result

    def close(self):
        if self.result is None:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        os.close(self.fd)


def terminal(args, actions=None):
    session = Terminal(args)
    try:
        if actions:
            actions(session)
        code = session.finish()
        return code, session.output, session.echo()
    finally:
        session.close()


try:
    with tempfile.TemporaryDirectory(prefix='thermohop-setup-test-') as directory:
        config = pathlib.Path(directory) / 'private' / 'profiles.json'
        options = ['--config', str(config)]
        result = json.loads(run(['wifi', 'setup', '--status', *options]).stdout)
        check(not result['credentialsReady'] and result['humanInputRequired']
              and result['profiles'] == [] and not config.exists(),
              'Read-only empty status must require human setup')
        run(['wifi', 'setup', '--regular', SSIDS[0], '--hotspot', SSIDS[1], *options], 2)
        check(not config.exists(), 'Noninteractive wizard must refuse before writing')
        run(['wifi', 'setup', '--status', '--regular', SSIDS[0], *options], 2)
        run(['wifi', 'credential', 'set', SSIDS[0], '--prompt'], 2, data=b'ignored')
        run(['wifi', 'credential', 'set', SSIDS[0]], 2, data=b'x' * 4097)
        check(True, 'Ambiguous status, non-TTY password prompt and overlong pipe rejected')

        def cancel(session):
            session.until(b'Wi-Fi password: ')
            check(not session.echo(), 'Password prompt must disable echo')
            session.send(FAKE.encode() + b'\x03')
        code, output, echo = terminal(['wifi', 'credential', 'set', SSIDS[0], '--prompt'], cancel)
        check(code == -signal.SIGINT and echo and FAKE.encode() not in output,
              'SIGINT must restore echo without leaking input')

        def wizard(session):
            session.until(b'Router SSID: ')
            session.send(SSIDS[0].encode() + b'\n')
            session.until(b'Phone hotspot SSID: ')
            session.send(SSIDS[1].encode() + b'\n')
            session.until(b'regular Wi-Fi password: ')
            check(not session.echo(), 'Router password must be hidden')
            session.send(FAKE.encode() + b'\n')
            session.until(b'hotspot Wi-Fi password: ')
            check(not session.echo(), 'Hotspot password must be hidden')
            session.send(FAKE.encode() + b'\n')
        code, output, echo = terminal(['wifi', 'setup', *options], wizard)
        check(code == 0 and echo and FAKE.encode() not in output,
              'Completed setup must restore echo and never print passwords')
        file = json.loads(config.read_text())
        check({p['ssid'] for p in file['profiles']} == set(SSIDS[:2])
              and FAKE not in config.read_text()
              and config.stat().st_mode & 0o777 == 0o600
              and config.parent.stat().st_mode & 0o777 == 0o700,
              'Profile metadata must be private and contain no passwords')
        result = json.loads(run(['wifi', 'setup', '--status', *options]).stdout)
        check(result['credentialsReady'] and not result['humanInputRequired']
              and not result['networkAccessVerified']
              and all(p['credential'] == 'stored' for p in result['profiles']),
              'Metadata readiness must not claim connectivity')

        file['profiles'][0]['priority'] = 23
        config.write_text(json.dumps(file))
        code, output, echo = terminal(['wifi', 'setup', '--regular', SSIDS[0],
                                       '--hotspot', SSIDS[1], *options])
        check(code == 0 and b'Wi-Fi password: ' not in output
              and json.loads(config.read_text())['profiles'][0]['priority'] == 23,
              'Rerun must preserve stored credentials and explicit priorities')
        code, _, _ = terminal(['wifi', 'setup', '--regular', SSIDS[0],
                               '--hotspot', SSIDS[0], *options])
        check(code == 2, 'Duplicate router/hotspot rejected')
        code, _, _ = terminal(['wifi', 'setup', '--regular', SSIDS[0],
                               '--hotspot', SSIDS[3], *options])
        check(code == 2, 'Existing different hotspot must not be silently replaced')

        def replace(session):
            session.until(b'Wi-Fi password: ')
            session.send((FAKE + '-updated').encode() + b'\n')
        code, output, echo = terminal(['wifi', 'credential', 'set', SSIDS[0], '--prompt'], replace)
        # The command verifies its own write by reading back inside Thermohop.
        # A different executable would need separate Keychain ACL approval.
        check(code == 0 and echo and FAKE.encode() not in output
              and b'credentialStored' in output,
              'Hidden prompt must replace the disposable Keychain item')

        resume_config = pathlib.Path(directory) / 'resume.json'
        resume_args = ['wifi', 'setup', '--regular', SSIDS[2], '--hotspot', SSIDS[3],
                       '--config', str(resume_config)]
        def partial(session):
            session.until(b'regular Wi-Fi password: ')
            session.send(FAKE.encode() + b'\n')
            session.until(b'hotspot Wi-Fi password: ')
            session.send(b'\x03')
        code, _, echo = terminal(resume_args, partial)
        check(code == -signal.SIGINT and echo
              and len(json.loads(resume_config.read_text())['profiles']) == 1,
              'Cancelled setup must keep only the completed entry')
        def resume(session):
            session.until(b'hotspot Wi-Fi password: ')
            session.send(FAKE.encode() + b'\n')
        code, output, echo = terminal(resume_args, resume)
        check(code == 0 and echo and b'regular Wi-Fi password: ' not in output,
              'Retry must resume setup without requesting the completed password')
finally:
    for ssid in SSIDS:
        run(['wifi', 'credential', 'delete', ssid])

print(f'{checks} setup checks passed; disposable Keychain items removed; no network changes')
