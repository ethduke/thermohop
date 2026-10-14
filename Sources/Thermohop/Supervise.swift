import Foundation
import ArgumentParser
import Darwin

final class SupervisorLock {
    private var descriptor: Int32 = -1
    init(name: String = "supervisor", mode: AwakeControllerMode = .supervisor) throws {
        let path = "/private/tmp/thermohop-\(name)-\(getuid()).lock"
        descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure(code: 8, message: "Unable to open supervisor lock.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o077 == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw Failure(code: 8, message: "Another supervisor is running, or its lock is unavailable.")
        }
        do {
            let data = try JSONEncoder().encode(SupervisorLockOwner(mode: mode))
            guard ftruncate(descriptor, 0) == 0,
                  data.withUnsafeBytes({ pwrite(descriptor, $0.baseAddress, $0.count, 0) }) == data.count else {
                throw Failure(code: 8, message: "Unable to record supervisor identity.")
            }
        } catch {
            close(descriptor); descriptor = -1
            throw error
        }
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
}
struct Supervise: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Apply explicit thermal/Wi-Fi policy, verify results, and emit JSONL decisions.")
    @Option(help: "JSON policy file. Generate one with policy defaults.") var policy: String
    @Option(help: "Maximum supervision duration, up to 86400 seconds.") var duration: Double = 3600
    @Flag(help: "Observe and propose actions only; does not launch or signal workloads or join networks.") var observeOnly = false
    @OptionGroup var store: StoreOptions
    @Option(help: "Wi-Fi interface name.") var interface: String?
    @Argument(parsing: .captureForPassthrough, help: "Owned workload command after --. Its output is suppressed; wrap it to write a log if needed.") var command: [String] = []
    mutating func validate() throws { try validateSeconds(duration, max: 86400) }
    func run() throws {
        var exitStatus: Int32 = 0
        try perform {
            let config = try loadPolicy(policy)
            let profiles = try readProfiles(store.config).profiles
            guard !config.wifi.enabled || !profiles.isEmpty else { throw Failure(code: 2, message: "Enabled Wi-Fi supervision requires explicitly configured profiles.") }
            let lock = try SupervisorLock()
            let cancellation = Cancellation()
            let started = ProcessInfo.processInfo.systemUptime
            let deadline = started + duration
            var signals: [DispatchSourceSignal] = []
            let oldInterrupt = Darwin.signal(SIGINT, SIG_IGN)
            let oldTerminate = Darwin.signal(SIGTERM, SIG_IGN)
            for number in [SIGINT, SIGTERM] {
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { cancellation.cancel() }; source.resume(); signals.append(source)
            }
            defer {
                for source in signals { source.cancel() }
                Darwin.signal(SIGINT, oldInterrupt); Darwin.signal(SIGTERM, oldTerminate)
                withExtendedLifetime(lock) {}
            }
            let workloadCommand = command.first == "--" ? Array(command.dropFirst()) : command
            if !observeOnly && config.awake.enabled && !workloadCommand.isEmpty && Pressure.current.rank >= config.awake.cutoff.rank {
                throw Failure(code: 10, message: "Thermal cutoff already reached; refusing to launch a workload.")
            }
            let awake = try SupervisorAwake(policy: config.awake, observeOnly: observeOnly)
            defer { try? awake.stop() }
            let gate = ActivityGate(cutoff: config.awake.enabled ? config.awake.cutoff : .critical)
            let workload = workloadCommand.isEmpty || observeOnly ? nil : try OwnedWorkload(command: workloadCommand)
            var thermal = ThermalRules()
            var options = WiFiOptions(); options.interface = interface; options.timeout = config.wifi.operationTimeout
            let network = config.wifi.enabled ? NetworkSupervisor(policy: config.wifi, profiles: profiles,
                options: options, observeOnly: observeOnly, cancellation: cancellation, started: started, allowed: { gate.allowed }, generation: { gate.generation }) : nil
            defer {
                gate.set(false); cancellation.cancel()
                network?.finish()
                workload?.close(resumeOwnedPause: thermal.pausedBySupervisor)
                emit(["event": "supervisorStopped", "exitCode": exitStatus])
            }
            emit(["event": "supervisorStarted", "observeOnly": observeOnly, "wifiEnabled": config.wifi.enabled,
                  "workloadOwned": workload != nil, "duration": duration])
            if let workload { emit(["event": "workloadStarted", "pid": workload.pid, "processGroup": workload.pid]) }
            network?.start()
            do {
                var previous: Pressure?
                var previousAgents: [Int32]?
                var previousLid: String?
                var previousNetworkAllowed: Bool?
                while !cancellation.cancelled && ProcessInfo.processInfo.systemUptime < deadline {
                    workload?.poll()
                    if let status = workload?.exitCode {
                        emit(["event": "workloadExited", "exitCode": status]); exitStatus = status; break
                    }
                    if let workload, thermal.pausedBySupervisor && !workload.stopped {
                        thermal.pausedBySupervisor = false
                        emit(["event": "workloadStateChanged", "reason": "resumedOutsideSupervisor"])
                    }
                    let pressure = Pressure.current
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    let agents = config.awake.enabled ? try detectAgents(names: Set(config.awake.agents), pids: Set(config.awake.pids)) : []
                    let lid = lidState()
                    if previousAgents != agents.map(\.pid) || previousLid != lid {
                        emit(["event": "agentObservation", "agents": agents.map { ["pid": $0.pid, "name": $0.name] as [String: Any] },
                              "detection": "processPresence", "lid": lid, "thermalLevel": pressure.rank])
                        previousAgents = agents.map(\.pid); previousLid = lid
                    }
                    let activityAllowed = try awake.update(time: elapsed, pressure: pressure, agents: agents,
                        owned: workload, ownsPause: thermal.pausedBySupervisor)
                    let networkAllowed = activityAllowed && (!config.awake.enabled || !agents.isEmpty || (workload.map { !$0.stopped && $0.exitCode == nil } ?? false))
                    gate.set(networkAllowed)
                    if previousNetworkAllowed != networkAllowed && config.wifi.enabled {
                        emit(["event": "networkPolicyState", "active": networkAllowed,
                              "reason": networkAllowed ? "eligibleActivity" : "noAgentsOrThermalSafety"])
                        previousNetworkAllowed = networkAllowed
                    }
                    if pressure != previous {
                        emit(["event": "thermalObservation", "pressure": pressure.rawValue, "thermalLevel": pressure.rank, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started])
                        previous = pressure
                    }
                    if let decision = thermal.decide(time: ProcessInfo.processInfo.systemUptime - started, pressure: pressure, policy: config.effectiveThermal),
                       decision.action != "resumeWorkload" || !config.awake.enabled || !awake.cooling {
                        emit(decision.fields())
                        if observeOnly {
                            // Virtual state avoids repeated proposals; this is not execution verification.
                            thermal.complete(decision, verified: true, time: ProcessInfo.processInfo.systemUptime - started)
                            emit(["event": "actionResult", "action": decision.action, "result": "proposed", "verified": false, "nextRetrySeconds": thermal.retryAt])
                        } else if let workload {
                            let verified = decision.action == "pauseWorkload" ? workload.pause() : workload.resume()
                            thermal.complete(decision, verified: verified, time: ProcessInfo.processInfo.systemUptime - started)
                            emit(["event": "actionResult", "action": decision.action, "result": verified ? "succeeded" : "failed", "verified": verified,
                                  "verification": "ownedProcessGroupLeader", "pid": workload.pid, "nextRetrySeconds": thermal.retryAt])
                        } else {
                            thermal.complete(decision, verified: false, time: ProcessInfo.processInfo.systemUptime - started)
                            emit(["event": "actionResult", "action": decision.action, "result": "noOwnedWorkload", "verified": false, "nextRetrySeconds": thermal.retryAt])
                        }
                    }
                    cancellation.wait(min(config.sampleInterval, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
                }
                gate.set(false)
                try awake.stop()
            } catch {
                gate.set(false)
                if let failure = error as? Failure { exitStatus = failure.code } else { exitStatus = 1 }
                do { try awake.stop() } catch { emit(["event": "cleanupFailed", "component": "sleepPrevention", "verified": false]) }
                throw error
            }
            if cancellation.cancelled { exitStatus = 130 }
            emit(["event": "supervisorStopping", "reason": cancellation.cancelled ? "interrupted" : (workload?.exitCode != nil ? "workloadExited" : "durationExpired")])
        }
        if exitStatus != 0 { throw ExitCode(exitStatus) }
    }
}
