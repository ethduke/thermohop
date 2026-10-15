#!/usr/bin/env python3
"""Verify installer plans and GUI authorization arguments without root changes."""
import contextlib
import io
import json
import os
import pathlib
import runpy
import shlex
import subprocess
import sys
import tempfile
from unittest import mock

INSTALLER = pathlib.Path(__file__).resolve().parents[1] / 'scripts/install-awake-helper.py'
checks = 0


def invoke(arguments):
    output, errors = io.StringIO(), io.StringIO()
    with mock.patch.object(sys, 'argv', [str(INSTALLER), *arguments]), \
         mock.patch.object(os, 'geteuid', return_value=os.getuid()), \
         mock.patch.object(subprocess, 'run') as run, \
         contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
        run.return_value.returncode = 0
        try:
            runpy.run_path(str(INSTALLER), run_name='__main__')
        except SystemExit as error:
            code = error.code
        else:
            raise AssertionError('Installer must exit before privileged operations')
    return code, output.getvalue(), errors.getvalue(), run


def check(value, message):
    global checks
    assert value, message
    checks += 1


code, output, _, run = invoke(['--plan'])
plan = json.loads(output)
check(code == 0 and not run.called and plan['requiresAdministrator']
      and not plan['installationChangesSleepSetting'], 'Plan must not change settings or request access')
check(len(plan['launchDaemons']) == 2 and 'thermal level 2' in plan['authorizationPrompt']
      and 'remain installed until removed' in plan['authorizationPrompt'],
      'Plan must disclose thermal cutoff and persistent privileged jobs')
code, output, _, run = invoke(['--plan', '--remove'])
plan = json.loads(output)
check(code == 0 and not run.called and plan['restoresOwnedSleepSettingOnRemoval'],
      'Removal plan must disclose conditional restoration without acting')
code, _, _, run = invoke([])
check(isinstance(code, str) and '--gui' in code and not run.called,
      'Unprivileged direct installation must fail before subprocess execution')
code, _, _, run = invoke(['--gui', '--user-id', '0'])
check(code == 2 and not run.called, 'GUI must reject a root target without authorization')
code, _, _, run = invoke(['--gui', '--user-id', '2147483545'])
check(code == 2 and not run.called, 'GUI must reject a nonexistent target before authorization')
code, _, _, run = invoke(['--gui'])
arguments = run.call_args.args[0]
check(code == 0 and arguments[:2] == ['/usr/bin/osascript', '-e']
      and 'with prompt (item 2 of argv)' in arguments[2],
      'GUI must supply the descriptive native authorization prompt')
check(shlex.split(arguments[3]) == ['/usr/bin/python3', str(INSTALLER), '--user-id', str(os.getuid())]
      and 'Thermohop needs administrator access' in arguments[4]
      and 'password' not in arguments[2],
      'GUI must pass a quoted command and never handle an administrator password')
script = arguments[2]
code, _, _, run = invoke(['--gui', '--remove'])
arguments = run.call_args.args[0]
check(code == 0 and shlex.split(arguments[3]) == ['/usr/bin/python3', str(INSTALLER), '--remove']
      and 'before deleting the files' in arguments[4],
      'Removal must use separate wording and preserve the root restoration guard')
code, _, _, run = invoke(['--gui', '--plan'])
check(code == 0 and not run.called, 'A GUI plan must not display an authorization dialog')

with tempfile.TemporaryDirectory(prefix='thermohop-bundled-helper-test-') as directory:
    binary = pathlib.Path(directory) / "example tool's binary"
    binary.write_bytes(b'synthetic executable fixture')
    binary.chmod(0o755)
    code, _, _, run = invoke(['--gui', '--binary', str(binary)])
    arguments = run.call_args.args[0]
    check(code == 0 and shlex.split(arguments[3])[-2:] == ['--binary', str(binary.resolve())],
          'Bundled setup must quote explicit executable paths without needing a checkout')
    binary.chmod(0o777)
    code, _, _, run = invoke(['--gui', '--binary', str(binary)])
    check(isinstance(code, str) and not run.called, 'Unsafe executable must be refused before authorization')

with tempfile.TemporaryDirectory(prefix='thermohop-authorization-test-') as directory:
    compiled = pathlib.Path(directory) / 'authorization.scpt'
    result = subprocess.run(['/usr/bin/osacompile', '-o', str(compiled), '-e', script],
                            capture_output=True, text=True, timeout=10)
    check(result.returncode == 0 and compiled.is_file(), 'Native authorization script must compile')

print(f'{checks} installer setup checks passed; no authorization dialogs or root changes')
