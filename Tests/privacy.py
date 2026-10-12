#!/usr/bin/env python3
"""Check stdout/stderr privacy with synthetic input, without credentials or joins."""
import json
import os
import pathlib
import subprocess
import tempfile
import uuid

BINARY = pathlib.Path(__file__).resolve().parents[1] / '.build/release/thermohop'
MARKER = 'synthetic-sensitive-' + uuid.uuid4().hex
checks = 0


def run(label, arguments, code, data=None, environment=None):
    global checks
    result = subprocess.run([str(BINARY), *arguments], input=data, capture_output=True,
                            env=environment, timeout=10)
    assert result.returncode == code, label + ': unexpected exit code'
    assert MARKER.encode() not in result.stdout + result.stderr, label + ': sensitive input leaked'
    checks += 1
    return result


for label, arguments in (
    ('invalid numeric value', ['wifi', 'status', '--timeout', MARKER]),
    ('invalid enum value', ['wifi', 'profiles', 'add', 'Example', '--role', MARKER]),
    ('unexpected argument', ['thermal', 'status', MARKER]),
    ('unknown option', ['--' + MARKER]),
    ('extra credential argument', ['wifi', 'credential', 'set', 'Example', MARKER]),
):
    run(label, arguments, 64)

for label, arguments in (
    ('root help', ['--help']),
    ('subcommand help', ['wifi', 'setup', '--help']),
    ('version', ['--version']),
    ('completion', ['--generate-completion-script', 'zsh']),
):
    result = run(label, arguments, 0)
    assert result.stdout, label + ': missing output'

with tempfile.TemporaryDirectory(prefix='thermohop-privacy-test-') as directory:
    root = pathlib.Path(directory)
    policy = root / 'policy.json'
    profiles = root / 'profiles.json'
    for label, contents in (
        ('unknown policy key', {MARKER: True}),
        ('unknown nested key', {'wifi': {MARKER: True}}),
        ('credential URL', {'wifi': {'probes': [{'url': 'https://user:' + MARKER + '@example.invalid/'}]}}),
        ('query credential', {'wifi': {'probes': [{'url': 'https://example.invalid/?token=' + MARKER}]}}),
    ):
        policy.write_text(json.dumps(contents))
        run(label, ['policy', 'validate', str(policy)], 2)
    policy.write_text('{"value": "' + MARKER)
    run('malformed policy', ['policy', 'validate', str(policy)], 2)
    profiles.write_text(json.dumps({'schemaVersion': 1, 'profiles': [{'ssid': MARKER, 'role': 'invalid'}]}))
    run('malformed profiles', ['wifi', 'setup', '--status', '--config', str(profiles)], 2)
    run('nonterminal prompt', ['wifi', 'credential', 'set', 'Example', '--prompt'], 2,
        data=MARKER.encode())
    run('invalid credential input', ['wifi', 'credential', 'set', 'Example'], 2,
        data=MARKER.encode() + b'\0')

    # Real child stdout/stderr and arguments/environment must not enter supervisor logs.
    policy.write_text(json.dumps({'awake': {'enabled': False}, 'thermal': {'enabled': False},
                                  'wifi': {'enabled': False}}))
    profiles.write_text(json.dumps({'schemaVersion': 1, 'profiles': []}))
    environment = os.environ.copy()
    environment['THERMOHOP_TEST_SECRET'] = MARKER
    script = 'import os,sys; print(sys.argv[1]); print(os.environ["THERMOHOP_TEST_SECRET"], file=sys.stderr)'
    result = run('workload output and metadata', ['supervise', '--policy', str(policy),
                 '--config', str(profiles), '--duration', '3', '--', '/usr/bin/python3',
                 '-c', script, MARKER], 0, environment=environment)
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert any(e.get('event') == 'workloadStarted' for e in events), 'Workload did not start'
    assert any(e.get('event') == 'workloadExited' and e.get('exitCode') == 0 for e in events), 'Workload did not exit cleanly'

print(f'{checks} privacy checks passed; no real secrets, network changes or sleep overrides')
