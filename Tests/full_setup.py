#!/usr/bin/env python3
"""Check full setup planning and resumability without dialogs, root or real secrets."""
import json
import pathlib
import subprocess
import tempfile
import uuid

BINARY = pathlib.Path(__file__).resolve().parents[1] / '.build/release/thermohop'
MARKER = 'synthetic-sensitive-' + uuid.uuid4().hex
checks = 0


def check(condition, message):
    global checks
    assert condition, message
    checks += 1


def run(arguments, code=0):
    result = subprocess.run([str(BINARY), 'setup', *arguments], input=b'', capture_output=True, timeout=15)
    check(result.returncode == code, 'Unexpected setup exit code')
    check(MARKER.encode() not in result.stdout + result.stderr, 'Setup echoed a supplied private value')
    return result


with tempfile.TemporaryDirectory(prefix='thermohop-full-setup-') as directory:
    root = pathlib.Path(directory)
    policy = root / 'policy.json'
    profiles = root / 'profiles.json'
    arguments = ['--policy', str(policy), '--config', str(profiles)]
    plan = json.loads(run(['--dry-run', '--authorize', *arguments]).stdout)
    check(plan['event'] == 'setupPlan' and plan['policy']['awake']['closedLid']
          and plan['policy']['thermal']['enabled'] and plan['policy']['wifi']['enabled']
          and not plan['permissionDialogs'] and not plan['networkChanges']
          and not policy.exists() and not profiles.exists(), 'Plan must not apply setup')
    state = json.loads(run(['--status', *arguments]).stdout)
    check(not state['ready'] and not state['policyReady'] and not state['credentialsReady']
          and not state['networkChecked'] and not state['supervisionStarted']
          and not policy.exists(), 'Read-only status must not create policy or claim connectivity')
    run(arguments, 2)
    check(not policy.exists(), 'A manual wizard without a local terminal must not start')
    result = run(['--non-interactive', *arguments], 2)
    state = json.loads(result.stdout)
    check(state['policyReady'] and not state['ready'] and state['humanInputRequired']
          and not state['networkAccessVerified'] and not state['supervisionStarted'],
          'Agent setup must prepare policy and leave human-only steps pending')
    policy_data = json.loads(policy.read_text())
    check(policy_data['awake']['closedLid'] and policy_data['wifi']['enabled']
          and policy.stat().st_mode & 0o777 == 0o600,
          'Generated full policy must be private and enable the requested features')
    policy_data['awake']['agents'] = ['example-agent']
    policy.write_text(json.dumps(policy_data))
    before = policy.read_bytes()
    run(['--non-interactive', *arguments], 2)
    check(policy.read_bytes() == before, 'Rerun must preserve custom policy values')
    router = 'th-test-' + uuid.uuid4().hex[:12]
    hotspot = 'th-test-' + uuid.uuid4().hex[:12]
    state = json.loads(run(['--non-interactive', '--regular', router, '--hotspot', hotspot, *arguments], 2).stdout)
    stored = json.loads(profiles.read_text())
    check(len(stored['profiles']) == 2 and not state['credentialsReady']
          and profiles.stat().st_mode & 0o777 == 0o600,
          'Agent setup may save names but must never invent or request passwords')
    check(str(root).encode() not in result.stdout + result.stderr,
          'Readiness output must not contain full personal paths')
    run(['--status', '--authorize', *arguments], 64)
    run(['--dry-run', '--probe-url', 'https://example.invalid/?token=' + MARKER, *arguments], 2)
    partial = root / 'partial.json'
    partial.write_text('{"wifi":{"enabled":false}}')
    run(['--non-interactive', '--policy', str(partial), '--config', str(profiles)], 2)
    check(partial.read_text() == '{"wifi":{"enabled":false}}', 'Existing partial policy must be preserved')
    run(['--non-interactive', '--replace-policy', '--policy', str(partial), '--config', str(profiles)], 2)
    check(json.loads(partial.read_text())['awake']['closedLid'], 'Explicit replacement must apply the preset')

print(f'{checks} full-setup checks passed; no permission dialogs, root changes, password reads, joins or supervision')
