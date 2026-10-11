Thermohop
=========
A macOS CLI supervisor for agent workloads: observe, decide from explicit policy,
act, then verify. It detects configured agent processes, keeps work awake while
thermal pressure is safe, pauses its own workload on heat, and manages configured
Wi-Fi fallback/return. JSONL explains decisions and outcomes. No model is embedded.
Requires macOS 13+ and Swift 5.9+.

Build and test
--------------
    swift build -c release
    .build/release/thermohop policy defaults > policy.json
    .build/release/thermohop policy validate policy.json
    .build/release/thermohop supervise --policy policy.json --observe-only --duration 60
    .build/release/thermohop supervise --policy policy.json --duration 300 -- /bin/sleep 240

Observe-only creates no workload, signals, sleep assertions, privileged leases or
network joins. Enabled Wi-Fi observation can still scan and contact your endpoints.
Live Wi-Fi requires the installed app identity:
    ./install.sh
    thermohop wifi permission request --timeout 30
    thermohop wifi permission status
    thermohop wifi status
    thermohop wifi scan

The installer creates ~/Applications/Thermohop.app and ~/.local/bin/thermohop.
Put that bin directory on PATH. Allow Location access in System Settings if needed.
Workers launch through macOS Launch Services: directly spawning an executable can
report authorization while macOS redacts SSIDs. Replacing the ad-hoc signed build
may require authorization again. Verify status and scan without reinstalling in
between. Hidden SSIDs mean unknown state, never evidence of disconnection.
Routine supervision never opens permission or Keychain approval dialogs.

Agent and thermal policy
------------------------
Default awake.agents: claude, codex, aider, goose, opencode, gemini. Exact executable
or process names are matched for the current user; stopped/zombie processes are
excluded. Set awake.agents and/or awake.pids for wrappers or other agents. No
arguments, prompts or browser contents are inspected. Presence does not prove an
agent is actively working. An explicit owned command also qualifies for prevention.

macOS thermal pressure levels, not Celsius:
    0 nominal   Normal conditions; resume after 60 continuous seconds of recovery.
    1 fair      Elevated pressure; continue with the default cutoff.
    2 serious   Immediately release prevention and pause the owned workload.
    3 critical  Same safety reaction; further Wi-Fi actions are suspended.

Default sampleInterval is 0.5 seconds. Set awake.cutoff to fair for a stricter
level-1 cutoff; awake.resumeAt must be lower, with awake.resumeDelay defaulting to
60 seconds. Recovery must be continuous; renewed heat resets the cooling timer.
The supervisor stays available for recovery, reacquiring prevention when eligible
work returns. With awake.enabled=true, thermal pausing cannot be disabled/delayed
past the awake cutoff; a stricter thermal.pauseAt is respected. Resume uses the
lower resumeAt and longer resumeDelay of both sections. Setting awake.enabled=false
opts out of agent-aware prevention/gating and uses the explicit thermal policy.

Only a command launched after -- belongs to the supervisor. STOP/CONT target its
new process group and verify the leader's state; existing agents are never signaled.
Only a pause owned by this supervisor can be resumed. Detached descendants cannot
be controlled. Workload stdio is disconnected; use a wrapper to write your own log.
Duration expiry/interruption terminates the owned group with bounded escalation;
leader exit ends supervision and returns its status. Process presence detection,
thermal safety and network checks run without blocking each other's sampling.
Policies/profiles are snapshots: restart after edits. Unknown JSON fields fail.

Without an owned command, heat releases prevention but does not halt unrelated
agents. Releasing this app's assertion allows sleep; it does not guarantee immediate
sleep, release other apps' assertions, or stop all computation.

Run a real agent
----------------
Use an authenticated CLI in noninteractive mode; this Claude example allows only
file-reading tools. exec preserves the workload PID; redirect output to keep the
supervisor's JSONL separate:
    thermohop supervise --policy policy.json --duration 900 -- /bin/sh -c \
      'exec claude --safe-mode -p "Review this project without editing files." \
        --tools Read,Glob,Grep --allowedTools Read,Glob,Grep > agent.log 2>&1'

With default policy, level 2 produces verified pauseWorkload and a stopped leader
(state T in ps); 60 continuous seconds at nominal produces verified resumeWorkload.
Local pausing does not stop remote model inference. Use policy simulate to replay
thermal scenarios without heating the Mac; simulation does not verify real signals.
For a live Wi-Fi test, configure a secured router, hotspot and Internet probe.
Interrupt only your router's WAN while keeping Wi-Fi associated; restore WAN after
verified fallback. Require verified fallback/returnToRegular results and health
checks. Unreadable SSIDs or uncertain joins require intervention and restart.

Lid handling and optional watchdogs
----------------------------------
    thermohop awake status
    thermohop awake watch --observe-only --duration 60
    thermohop awake watch --agent my-agent --pid 12345 --cutoff fair --duration 300

Standalone awake watch uses the same process detection and 5-second timed idle
sleep assertion, but exits 10 at the cutoff; restart after cooling. The integrated
supervisor instead waits for recovery. No agents, exit or process death releases
its process-owned assertion. The lid is reported open/closed where IOKit supports
it, otherwise unknown. Standard assertions do not override lid-close sleep.

Optional closed-lid operation requires an explicitly installed privileged backend:
    swift build -c release
    sudo ./scripts/install-awake-helper.py --user-id "$(id -u)"
Then set awake.closedLid=true in the supervisor policy, or run:
    .build/release/thermohop awake watch --closed-lid --duration 300

The separate installer is never run automatically. Two root-owned launchd watchdogs
control the system-wide SleepDisabled setting. A 5-second lease binds to controller
PID/start time; the main watchdog independently checks agent presence, thermal
cutoff and lid availability. It journals ownership before changing the setting,
restores sleep on heat/expiry/death, and recovers its journal after restart. A
second watchdog restores the owned setting if the main watchdog hangs. A confirmed
lease is required before proceeding; shutdown reports whether restoration was
verified. A pre-existing foreign SleepDisabled setting is never claimed/reset.
Avoid simultaneous apps changing that global setting. After stopping the session:
    sudo ./scripts/install-awake-helper.py --remove

Fan control is unavailable in this build; macOS handles fans automatically.
Thermal reporting can lag physical heating. Restricted backpack airflow means this
is not a guarantee of safe closed-lid operation; do not rely on fans alone.

Wi-Fi setup and reactions
-------------------------
    thermohop wifi profiles add 'Example home' --role regular --priority 10
    thermohop wifi profiles add 'Example phone' --role hotspot
    thermohop wifi join 'Example home' --dry-run
    thermohop wifi fallback --dry-run
    thermohop wifi return --dry-run

Profiles are an explicit allowlist in ~/Library/Application Support/Thermohop/
profiles.json; --config overrides it. Scanning never adds profiles automatically.
Lower regular priority wins, then the single configured hotspot. Enable your phone
hotspot manually: cellular fallback means joining its Wi-Fi, not managing a modem.
Pipe a password manager's secret output into wifi credential set 'Example home'.
Passwords stay in device-local Keychain; no password arguments/output or imported
macOS Wi-Fi items. Set reads piped stdin with a 10-second limit. Authorize/unlock
Keychain during setup. Automated joins support WPA2/WPA3 Personal; open networks
need manual join --allow-open and are excluded from supervision.

wifi.enabled defaults to false. Explicitly choose requiredHealth: association,
local or internet. Local/internet need probes, for example:
    {"wifi":{"enabled":true,"requiredHealth":"internet","probes":[
      {"kind":"http","scope":"internet","url":"https://example.com",
       "expectedStatus":200}]}}

Choose endpoints you intend to contact. HTTP sends HEAD with exact status matching,
no redirects/cookies/credentials. TCP uses kind, scope, host and port. Both require
a Wi-Fi path and bounded timeouts; HTTPS uses OS certificate validation. All probes
in a scope must pass. Association, local and internet/service health stay separate;
a successful join alone is insufficient evidence of Internet access.

Default network rules:
- Check every 10 seconds while an eligible agent/owned workload is active and safe.
  Suspend on heat/cooling or absence; discard partial failure/return counts.
- After 3 consecutive health failures, scan and try visible allowed regular
  networks by priority, then hotspot, excluding the current unhealthy SSID.
- Verify association and required health. Known failure tries the next candidate;
  exhausting candidates attempts/verifies rollback to the original allowed SSID.
- On hotspot, scan every 60 seconds; return after the same regular candidate appears
  in 3 scheduled scans. Prefer the previous regular network, then priority.
- Apply a 60-second retry cooldown. Remember state only for this session.
- Permission loss, radio-off, unreadable SSID, unconfigured current SSID, timeout or
  uncertain outcome blocks switching until correction/restart. If a thermal/agent
  cancellation interrupts a join, its outcome is uncertain and also blocks retries.
  Thermal monitoring/prevention continue even when Wi-Fi is blocked.

wifi checkInterval, failureChecks, returnScanInterval, returnScans, retryCooldown,
operationTimeout, transactionTimeout and probeTimeout are configurable. Operations
add to the check interval. A cancelled association may still finish inside macOS;
inspect status before restarting. No Instant Hotspot activation, enterprise/hidden
network automation, captive-portal login or direct cellular control is provided.

Simulation and output
---------------------
    thermohop policy simulate --policy policy.json --input scenario.jsonl
    thermohop awake simulate --input awake-scenario.jsonl

Policy simulation replays the real decision rules without OS actions, probes,
credentials or waits. Frames have increasing time and pressure, plus optional
agents (count, default 1), ssid, healthy, permissionReady and visible allowed SSIDs.
Explicit thermalResult success/failed or networkResult success/failed/uncertain
feeds verification back into the rules. Missing outcomes remain proposals:
    {"time":0,"pressure":"serious","agents":1,"thermalResult":"success"}
    {"time":1,"pressure":"nominal","agents":1}
    {"time":61,"pressure":"nominal","agents":1,"thermalResult":"success"}
Standalone awake simulation takes time/pressure/agents and stops at its cutoff.

Runtime JSONL has schemaVersion 1 and UTC timestamps. policyDecision explains why;
actionResult, networkVerification and rollbackResult distinguish verified actions
from proposals. nextRetrySeconds is elapsed session/simulation time. Responses,
command arguments and secrets are not logged. Help/errors may be plain text;
policy defaults emits formatted JSON.

Exit codes: 0 success/duration; 1 internal/filesystem; 2 input/config; 3 unavailable
Wi-Fi/watchdog; 4 permission; 5 deadline/unverified restoration; 6 unusable network;
7 Keychain; 8 lock busy; 10 thermal cutoff; 64 parser; 130 interrupted.
