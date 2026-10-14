import Foundation
import ArgumentParser
import Darwin

enum MonitorState: String {
    case waitingForAgent, keepingAwake, cooling, lidClosed
}

struct MonitorRules {
    private var recovery = AwakeRecoveryRules()

    mutating func state(time: Double, pressure: Pressure, agents: Int, lid: String,
                        policy: AwakePolicy) -> MonitorState {
        let safe = recovery.allowsActivity(time: time, pressure: pressure, policy: policy)
        if !safe { return .cooling }
        if lid == "closed" { return .lidClosed }
        return agents > 0 ? .keepingAwake : .waitingForAgent
    }
}

private struct MonitorOutput {
    let json: Bool

    func started(policy: AwakePolicy, duration: Double?) {
        if json {
            emit(["event": "monitorStarted", "mode": "openLid",
                  "thermalCutoffLevel": policy.cutoff.rank, "resumeThermalLevel": policy.resumeAt.rank,
                  "resumeDelaySeconds": policy.resumeDelay,
                  "duration": duration.map { $0 as Any } ?? NSNull(), "closedLidOverride": false])
        } else {
            line("Thermohop: open-lid monitoring. Ctrl+C to stop.")
        }
    }

    func status(_ state: MonitorState, pressure: Pressure, agents: [AgentProcess],
                lid: String, assertionHeld: Bool, policy: AwakePolicy, showProcesses: Bool) {
        if json {
            emit(["event": "monitorStatus", "state": state.rawValue,
                  "thermalLevel": pressure.rank, "pressure": pressure.rawValue, "lid": lid,
                  "agents": agents.map(\.fields), "detection": "processPresence",
                  "assertionHeld": assertionHeld, "verified": true])
        } else {
            switch state {
            case .waitingForAgent:
                line("Waiting for a recognized agent; sleep is allowed. Thermal level \(pressure.rank).")
            case .keepingAwake:
                let count = agents.count
                line("Keeping awake: \(count) matched agent process\(count == 1 ? "" : "es"). Thermal level \(pressure.rank).")
            case .cooling:
                line("Cooling at thermal level \(pressure.rank); sleep prevention released. Recovery requires \(Int(policy.resumeDelay)) continuous seconds at level \(policy.resumeAt.rank).")
            case .lidClosed:
                line("Lid closed; sleep prevention released. Monitoring will continue after waking.")
            }
            if showProcesses && !agents.isEmpty {
                for text in agentProcessLines(agents) { line(text) }
                line("Task titles are unavailable; OS process state does not show model activity.")
            }
        }
    }

    func stopped(reason: String) {
        if json {
            emit(["event": "monitorStopped", "reason": reason, "assertionHeld": false,
                  "verified": true, "closedLidOverride": false])
        } else {
            line("Stopped; Thermohop's sleep prevention is released.")
        }
    }

    private func line(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}

struct Monitor: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "monitor",
        abstract: "Monitor agent processes with the lid open until Ctrl+C; recover automatically after cooling.")
    @OptionGroup var options: AwakeOptions
    @Flag(help: "Emit JSONL status instead of readable messages.") var json = false
    @Option(help: "Optional session limit in seconds, up to 86400; omitted means until Ctrl+C.") var duration: Double?

    mutating func validate() throws {
        if let duration { try validateSeconds(duration, max: 86400) }
    }

    func run() throws {
        var interrupted = false
        try perform(jsonOutput: json) {
            let lock = try SupervisorLock(name: "awake")
            var assertion = SleepAssertion()
            defer { try? assertion.release(); withExtendedLifetime(lock) {} }
            let cancellation = Cancellation()
            var signals: [DispatchSourceSignal] = []
            let oldInterrupt = Darwin.signal(SIGINT, SIG_IGN)
            let oldTerminate = Darwin.signal(SIGTERM, SIG_IGN)
            for number in [SIGINT, SIGTERM] {
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { cancellation.cancel() }
                source.resume(); signals.append(source)
            }
            defer {
                for source in signals { source.cancel() }
                Darwin.signal(SIGINT, oldInterrupt); Darwin.signal(SIGTERM, oldTerminate)
            }
            var policy = AwakePolicy()
            policy.agents = options.agent; policy.pids = options.pid; policy.cutoff = options.cutoff
            let output = MonitorOutput(json: json)
            let started = ProcessInfo.processInfo.systemUptime
            let deadline = duration.map { started + $0 } ?? .infinity
            var rules = MonitorRules()
            var previous: String?
            var previousAgents: [Int32]?
            var lastSample = Date()
            output.started(policy: policy, duration: duration)
            while !cancellation.cancelled && ProcessInfo.processInfo.systemUptime < deadline {
                let now = Date()
                if assertion.held && now.timeIntervalSince(lastSample) >= SleepAssertion.leaseSeconds {
                    // A suspended controller's kernel lease can expire. Replace only
                    // our assertion object, then recheck live eligibility before acquisition.
                    assertion = SleepAssertion()
                }
                lastSample = now
                let agents = try detectAgents(names: Set(options.agent), pids: Set(options.pid))
                let lid = lidState()
                let pressure = Pressure.current
                let state = rules.state(time: ProcessInfo.processInfo.systemUptime - started,
                    pressure: pressure, agents: agents.count, lid: lid, policy: policy)
                if state == .keepingAwake { try assertion.acquire() }
                else { try assertion.release() }
                let snapshot = "\(state.rawValue):\(pressure.rawValue):\(lid):\(agents.map(\.pid))"
                if previous != snapshot {
                    output.status(state, pressure: pressure, agents: agents, lid: lid,
                                  assertionHeld: assertion.held, policy: policy,
                                  showProcesses: previousAgents != agents.map(\.pid))
                    previous = snapshot
                    previousAgents = agents.map(\.pid)
                }
                cancellation.wait(min(0.5, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            }
            interrupted = cancellation.cancelled
            try assertion.release()
            output.stopped(reason: interrupted ? "interrupted" : "durationExpired")
        }
        if interrupted { throw ExitCode(130) }
    }
}
