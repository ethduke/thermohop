import Foundation
import ArgumentParser

struct SimulationFrame: Decodable {
    var time: Double
    var pressure: Pressure
    var ssid: String?
    var healthy: Bool
    var permissionReady: Bool
    var visible: [String]?
    var agents: Int
    var thermalResult: String?
    var networkResult: String?
    enum CodingKeys: String, CodingKey { case time, pressure, agents, ssid, healthy, permissionReady, visible, thermalResult, networkResult }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        time = try values.decode(Double.self, forKey: .time)
        agents = try values.decodeIfPresent(Int.self, forKey: .agents) ?? 1
        pressure = try values.decode(Pressure.self, forKey: .pressure)
        ssid = try values.decodeIfPresent(String.self, forKey: .ssid)
        healthy = try values.decodeIfPresent(Bool.self, forKey: .healthy) ?? true
        permissionReady = try values.decodeIfPresent(Bool.self, forKey: .permissionReady) ?? true
        visible = try values.decodeIfPresent([String].self, forKey: .visible)
        thermalResult = try values.decodeIfPresent(String.self, forKey: .thermalResult)
        networkResult = try values.decodeIfPresent(String.self, forKey: .networkResult)
    }
}
struct PolicySimulate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "simulate", abstract: "Replay JSONL observations and explicit outcomes; no OS actions, probes, or real-time waits.")
    @Option var policy: String
    @Option(help: "JSONL frames with time/pressure and optional network observations/outcomes.") var input: String
    @OptionGroup var store: StoreOptions
    func run() throws {
        try perform {
            let config = try loadPolicy(policy)
            let profiles = try readProfiles(store.config).profiles
            let url = URL(fileURLWithPath: input)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1048576,
                  let content = try? String(contentsOf: url, encoding: .utf8) else {
                throw Failure(code: 2, message: "Simulation input must be UTF-8 JSONL of at most 1 MiB.")
            }
            var frames: [SimulationFrame] = []
            var previous: Double = -1
            for line in content.split(separator: "\n") {
                guard frames.count < 10000, let frame = try? JSONDecoder().decode(SimulationFrame.self, from: Data(line.utf8)),
                      frame.agents >= 0, frame.time.isFinite, frame.time >= 0, frame.time > previous,
                      frame.thermalResult == nil || ["success", "failed"].contains(frame.thermalResult!),
                      frame.networkResult == nil || ["success", "failed", "uncertain"].contains(frame.networkResult!) else {
                    throw Failure(code: 2, message: "Invalid simulation frame, outcome, or non-increasing time.")
                }
                previous = frame.time; frames.append(frame)
            }
            guard !frames.isEmpty else { throw Failure(code: 2, message: "Simulation input is empty.") }
            var thermal = ThermalRules(); var network = NetworkRules()
            var awake = AwakeRecoveryRules()
            var previousActivity: Bool?
            for frame in frames {
                emit(["event": "simulationObservation", "time": frame.time, "pressure": frame.pressure.rawValue])
                let safe = awake.allowsActivity(time: frame.time, pressure: frame.pressure, policy: config.awake)
                let active = !config.awake.enabled || (safe && frame.agents > 0)
                if config.awake.enabled && previousActivity != active {
                    emit(["event": "policyDecision", "action": active ? "preventIdleSleep" : "allowSleep",
                          "reason": awake.cooling ? "thermalSafetyAndRecovery" : (active ? "agentOrOwnedWorkloadPresent" : "noDetectedAgents"), "simulated": true])
                    emit(["event": "simulatedResult", "action": active ? "preventIdleSleep" : "allowSleep", "result": "proposed", "verified": false])
                    previousActivity = active
                }
                if let action = thermal.decide(time: frame.time, pressure: frame.pressure, policy: config.effectiveThermal),
                   action.action != "resumeWorkload" || !config.awake.enabled || !awake.cooling {
                    emit(action.fields(simulated: true))
                    if let result = frame.thermalResult {
                        thermal.complete(action, verified: result == "success", time: frame.time)
                        emit(["event": "simulatedResult", "action": action.action, "result": result, "verified": result == "success"])
                    }
                }
                guard active, frame.pressure != .critical else {
                    network.resetProgress()
                    continue
                }
                let observation = NetworkObservation(time: frame.time, ssid: frame.ssid, healthy: frame.healthy && frame.ssid != nil,
                    permissionReady: frame.permissionReady, visible: frame.visible.map { Set($0) })
                if let action = network.decide(observation, policy: config.wifi, profiles: profiles) {
                    emit(action.fields(simulated: true))
                    if let result = frame.networkResult, !action.candidates.isEmpty {
                        network.complete(time: frame.time, policy: config.wifi, uncertain: result == "uncertain")
                        emit(["event": "simulatedResult", "action": action.action, "result": result, "verified": result == "success"])
                    }
                }
            }
            emit(["event": "simulationCompleted", "frames": frames.count, "workloadPaused": thermal.pausedBySupervisor, "networkBlocked": network.blocked])
        }
    }
}
