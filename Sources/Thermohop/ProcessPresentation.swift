import Foundation

enum AgentProcessState: String {
    case starting, runnable, waiting, unknown

    init(bsdStatus: UInt32) {
        switch bsdStatus {
        case 1: self = .starting
        case 2: self = .runnable
        case 3: self = .waiting
        default: self = .unknown
        }
    }

    var readable: String {
        switch self {
        case .starting: return "starting"
        case .runnable: return "running / ready"
        case .waiting: return "waiting"
        case .unknown: return "state unavailable"
        }
    }
}

// Process names are untrusted display data; never emit terminal control characters.
func safeProcessLabel(_ name: String) -> String {
    let scalars = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "unknown process" : text
}

func friendlyProcessName(_ name: String) -> String {
    switch name.lowercased() {
    case "codex": return "Codex"
    case "claude": return "Claude Code"
    case "aider": return "Aider"
    case "goose": return "Goose"
    case "opencode": return "OpenCode"
    case "gemini": return "Gemini CLI"
    case "node": return "Node.js"
    case "python", "python3": return "Python"
    case "zsh": return "zsh shell"
    case "bash": return "bash shell"
    case "sh": return "shell"
    default: return safeProcessLabel(name)
    }
}

struct AgentProcess {
    let pid: Int32
    let name: String
    var state: AgentProcessState = .unknown
    var parentPID: Int32? = nil
    var parentName: String? = nil

    var displayName: String { friendlyProcessName(name) }
    var fields: [String: Any] {
        ["pid": pid, "name": name, "displayName": displayName, "state": state.rawValue,
         "parentPID": parentPID.map { $0 as Any } ?? NSNull(),
         "parentName": parentName.map { safeProcessLabel($0) as Any } ?? NSNull()]
    }
}

func agentProcessLines(_ agents: [AgentProcess]) -> [String] {
    if agents.isEmpty { return ["  No recognized agent processes."] }
    return agents.enumerated().map { index, agent in
        let parent: String
        if let pid = agent.parentPID {
            let label = agent.parentName.map(friendlyProcessName) ?? "unknown process"
            parent = "parent: \(label) (PID \(pid))"
        } else { parent = "parent unavailable" }
        return "  \(index + 1). \(agent.displayName) — PID \(agent.pid) — \(agent.state.readable) — \(parent)"
    }
}

func readableAwakeStatus(agents: [AgentProcess], pressure: Pressure, cutoff: Pressure, lid: String) -> String {
    let thermal: String
    switch pressure {
    case .nominal: thermal = "normal"
    case .fair: thermal = "elevated"
    case .serious: thermal = "high"
    case .critical: thermal = "critical"
    }
    var lines = ["Thermohop awake status",
                 "Thermal: \(thermal) (level \(pressure.rank); cutoff \(cutoff.rank))",
                 "Lid: \(lid == "unknown" ? "unavailable" : lid)",
                 "Detected agent processes: \(agents.count)", ""]
    lines += agentProcessLines(agents)
    lines += ["", "Task titles are unavailable; OS process state does not show model activity.",
              "This status check creates no sleep assertion."]
    return lines.joined(separator: "\n")
}
