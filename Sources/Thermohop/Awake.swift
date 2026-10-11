import Foundation
import ArgumentParser
import Darwin
import IOKit
import IOKit.pwr_mgt

struct AgentProcess {
    let pid: Int32
    let name: String
    var fields: [String: Any] { ["pid": pid, "name": name] }
}

enum AwakeDecision: String { case keepAwake, allowSleep, thermalCutoff }
func awakeDecision(pressure: Pressure, agents: Int, cutoff: Pressure) -> AwakeDecision {
    if pressure.rank >= cutoff.rank { return .thermalCutoff }
    return agents > 0 ? .keepAwake : .allowSleep
}

// Match executable/process names, never full argument strings containing prompts
// or secrets. Presence is a heuristic, not proof of an active inference request.
func detectAgents(names: Set<String>, pids: Set<Int32>, uid: UInt32 = getuid()) throws -> [AgentProcess] {
    let count = proc_listallpids(nil, 0)
    guard count > 0, count < 100_000 else {
        throw Failure(code: 1, message: "Unable to enumerate processes; sleep prevention is unavailable.")
    }
    var all = [Int32](repeating: 0, count: Int(count) + 1024)
    let found = all.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard found > 0, Int(found) < all.count else {
        throw Failure(code: 1, message: "Process enumeration was incomplete; sleep prevention is unavailable.")
    }
    var result: [AgentProcess] = []
    for pid in all.prefix(Int(found)) where pid > 0 && pid != getpid() {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == uid, info.pbi_status != 4, info.pbi_status != 5 else { continue }
        var path = [CChar](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(pid, &path, UInt32(path.count))
        let executable = pathLength > 0 ? URL(fileURLWithPath: String(cString: path)).lastPathComponent : ""
        var label = [CChar](repeating: 0, count: 256)
        let labelLength = proc_name(pid, &label, UInt32(label.count))
        let name = labelLength > 0 ? String(cString: label) : executable
        if pids.contains(pid) || names.contains(executable) || names.contains(name) {
            result.append(AgentProcess(pid: pid, name: names.contains(executable) ? executable : name))
        }
    }
    return result.sorted { $0.pid < $1.pid }
}

func lidState() -> String {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return "unknown" }
    defer { IOObjectRelease(service) }
    guard let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
          let closed = value as? NSNumber else { return "unknown" }
    return closed.boolValue ? "closed" : "open"
}

final class SleepAssertion {
    private var id: IOPMAssertionID?
    // The OS expires this lease even if sampling hangs. Process exit also
    // releases it; no persistent global power setting is changed.
    static let leaseSeconds: Double = 5
    var held: Bool { id != nil }
    func acquire() throws {
        guard id == nil else { try renew(); return }
        var created: IOPMAssertionID = 0
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionNameKey: "Thermohop agent thermal guard",
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
            kIOPMAssertionTimeoutKey: Self.leaseSeconds,
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease
        ]
        guard IOPMAssertionCreateWithProperties(properties as CFDictionary, &created) == kIOReturnSuccess else {
            throw Failure(code: 1, message: "macOS refused the sleep-prevention assertion.")
        }
        id = created
    }
    func renew() throws {
        guard let id else { return }
        guard IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString, Self.leaseSeconds as CFNumber) == kIOReturnSuccess else {
            throw Failure(code: 5, message: "Sleep-prevention lease expired or could not be renewed; stopping.")
        }
    }
    func release() throws {
        guard let current = id else { return }
        guard IOPMAssertionRelease(current) == kIOReturnSuccess else {
            throw Failure(code: 1, message: "Unable to verify assertion release; exiting to release process-owned assertions.")
        }
        id = nil
    }
    deinit { if let id { IOPMAssertionRelease(id) } }
}

struct AwakeOptions: ParsableArguments {
    @Option(name: .long, parsing: .upToNextOption, help: "Exact executable/process names. Overrides default CLI names; presence does not prove active work.")
    var agent: [String] = ["claude", "codex", "aider", "goose", "opencode", "gemini"]
    @Option(name: .long, parsing: .upToNextOption, help: "Explicit same-user PIDs for wrappers that cannot be recognized by executable name.")
    var pid: [Int32] = []
    @Option(help: "Thermal cutoff: fair (1) or serious (2). Safety is always enabled; critical (3) also stops.")
    var cutoff: Pressure = .serious
    mutating func validate() throws {
        guard cutoff == .fair || cutoff == .serious else { throw ValidationError("Cutoff must be fair (1) or serious (2).") }
        guard agent.count <= 32, pid.count <= 256,
              agent.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\0") && $0.utf8.count <= 255 }),
              pid.allSatisfy({ $0 > 0 }) else { throw ValidationError("Use nonempty executable names and positive PIDs.") }
    }
}

struct Awake: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Detect agent processes and prevent idle sleep only below a thermal cutoff.",
        subcommands: [AwakeStatus.self, AwakeWatch.self, AwakeSimulate.self, AwakeDaemon.self, AwakeBackstop.self])
}
struct AwakeStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")
    @OptionGroup var options: AwakeOptions
    func run() throws {
        try perform {
            let agents = try detectAgents(names: Set(options.agent), pids: Set(options.pid))
            let pressure = Pressure.current
            emit(["event": "awakeStatus", "agents": agents.map(\.fields), "detection": "processPresence",
                  "pressure": pressure.rawValue, "thermalLevel": pressure.rank, "cutoff": options.cutoff.rawValue,
                  "lid": lidState(), "eligible": !agents.isEmpty && pressure.rank < options.cutoff.rank,
                  "assertionHeld": false, "closedLidOverride": "requiresOptInPrivilegedWatchdog", "fanControl": "unavailable"])
        }
    }
}
struct AwakeWatch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "watch", abstract: "Keep detected agents awake until a thermal cutoff; release only this process's assertion.")
    @OptionGroup var options: AwakeOptions
    @Option(help: "Bounded session duration, up to 86400 seconds.") var duration: Double = 3600
    @Option(help: "Sampling interval, greater than zero and at most 1 second.") var interval: Double = 0.5
    @Flag(help: "Observe and report decisions without acquiring sleep assertions.") var observeOnly = false
    @Flag(help: "Opt into system-wide lid-close sleep prevention through the separately installed privileged watchdog.") var closedLid = false
    mutating func validate() throws { try validateSeconds(duration, max: 86400); try validateSeconds(interval, max: 1) }
    func run() throws {
        var exitStatus: Int32 = 0
        try perform {
            let lock = try SupervisorLock(name: "awake")
            let cancellation = Cancellation()
            let assertion = SleepAssertion()
            let lidLease = closedLid && !observeOnly ? try ClosedLidLease() : nil
            defer { lidLease?.withdraw() }
            var sources: [DispatchSourceSignal] = []
            let interrupt = Darwin.signal(SIGINT, SIG_IGN), terminate = Darwin.signal(SIGTERM, SIG_IGN)
            for number in [SIGINT, SIGTERM] {
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { cancellation.cancel() }; source.resume(); sources.append(source)
            }
            defer {
                for source in sources { source.cancel() }
                Darwin.signal(SIGINT, interrupt); Darwin.signal(SIGTERM, terminate)
                withExtendedLifetime(lock) {}
            }
            // Foundation reports thermal pressure even without temperature sensors.
            // Check current pressure again immediately before acquiring/renewing.
            let deadline = ProcessInfo.processInfo.systemUptime + duration
            var last: String?
            var pendingSince: Double?
            var reason = "durationExpired", exit: Int32 = 0
            emit(["event": "awakeStarted", "observeOnly": observeOnly, "cutoff": options.cutoff.rawValue,
                  "thermalCutoffLevel": options.cutoff.rank, "closedLidOverride": closedLid ? "requestedPrivilegedLease" : "unsupported", "fanControl": "unavailable"])
            while !cancellation.cancelled && ProcessInfo.processInfo.systemUptime < deadline {
                let agents = try detectAgents(names: Set(options.agent), pids: Set(options.pid))
                let pressure = Pressure.current
                let lid = lidState()
                let snapshot = "\(pressure.rawValue):\(lid):\(agents.map(\.pid))"
                if last != snapshot {
                    emit(["event": "awakeObservation", "agents": agents.map(\.fields), "pressure": pressure.rawValue,
                          "thermalLevel": pressure.rank, "lid": lid, "detection": "processPresence"])
                    last = snapshot
                }
                let decision = awakeDecision(pressure: pressure, agents: agents.count, cutoff: options.cutoff)
                if decision == .thermalCutoff {
                    reason = "thermalCutoff"; exit = 10; break
                }
                if decision == .allowSleep {
                    lidLease?.withdraw()
                    pendingSince = nil
                    if assertion.held { try assertion.release(); emit(["event": "sleepAssertionReleased", "reason": "noDetectedAgents", "verified": true]) }
                } else if !observeOnly {
                    if let lidLease {
                        try lidLease.renew(options: options)
                        if !lidLease.confirmed() {
                            // A requested lease is not proof that the helper has
                            // changed the OS setting; report the pending state.
                            if assertion.held { try assertion.release() }
                            if pendingSince == nil {
                                pendingSince = ProcessInfo.processInfo.systemUptime
                                emit(["event": "closedLidLeasePending", "verified": false])
                            }
                            if ProcessInfo.processInfo.systemUptime - pendingSince! >= 3 {
                                throw Failure(code: 3, message: "The closed-lid watchdog did not confirm the lease. Check helper installation and whether another app already disabled sleep; no keep-awake assertion is held.")
                            }
                            cancellation.wait(min(interval, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
                            continue
                        }
                        if pendingSince != nil { emit(["event": "closedLidLeaseConfirmed", "verified": true]); pendingSince = nil }
                    }
                    let wasHeld = assertion.held
                    try assertion.acquire()
                    if !wasHeld { emit(["event": "sleepAssertionAcquired", "verified": true, "leaseSeconds": SleepAssertion.leaseSeconds]) }
                }
                cancellation.wait(min(interval, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            }
            if cancellation.cancelled { reason = "interrupted"; exit = 130 }
            let wasHeld = assertion.held
            lidLease?.withdraw()
            try assertion.release()
            let restored = lidLease?.waitForRestoration() ?? true
            emit(["event": "awakeStopped", "reason": reason, "exitCode": exit,
                  "assertionReleased": wasHeld, "assertionHeld": false, "sleepAllowedByThermohop": restored,
                  "closedLidRestorationPending": !restored])
            if !restored && exit == 0 { exit = 5 }
            exitStatus = exit
        }
        if exitStatus != 0 { throw ExitCode(exitStatus) }
    }
}

struct AwakeSimulate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "simulate", abstract: "Exercise the real thermal keep-awake rule without touching processes or power settings.")
    @Option var input: String
    @OptionGroup var options: AwakeOptions
    struct Frame: Decodable { let time: Double; let pressure: Pressure; let agents: Int }
    func run() throws {
        try perform {
            guard let data = FileManager.default.contents(atPath: input), data.count <= 1_048_576,
                  let text = String(data: data, encoding: .utf8) else { throw Failure(code: 2, message: "Invalid simulation file; use UTF-8 JSONL up to 1 MiB.") }
            let lines = text.split(whereSeparator: \.isNewline)
            guard !lines.isEmpty, lines.count <= 10_000 else { throw Failure(code: 2, message: "Provide 1 to 10000 simulation frames.") }
            var frames: [Frame] = [], previous = -Double.infinity
            for line in lines {
                guard let frame = try? JSONDecoder().decode(Frame.self, from: Data(line.utf8)), frame.time.isFinite,
                      frame.time >= 0, frame.time > previous, frame.agents >= 0 else {
                    throw Failure(code: 2, message: "Frames require increasing nonnegative time, pressure and nonnegative agents.")
                }
                frames.append(frame); previous = frame.time
            }
            for frame in frames {
                let decision = awakeDecision(pressure: frame.pressure, agents: frame.agents, cutoff: options.cutoff)
                emit(["event": "awakeDecision", "decision": decision.rawValue, "time": frame.time,
                      "thermalLevel": frame.pressure.rank, "simulated": true])
                if decision == .thermalCutoff { break }
            }
        }
    }
}
