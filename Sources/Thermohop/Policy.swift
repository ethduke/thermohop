import Foundation
import ArgumentParser

enum HealthScope: String, Codable { case association, local, internet }
enum ProbeKind: String, Codable { case tcp, http }
struct HealthProbe: Codable {
    var kind: ProbeKind = .http
    var scope: HealthScope = .internet
    var host = ""
    var port = 443
    var url = ""
    var expectedStatus = 200
}
struct ThermalPolicy: Codable {
    var enabled = true
    var pauseAt: Pressure = .serious
    var pauseDelay: Double = 0
    var resumeAt: Pressure = .nominal
    var resumeDelay: Double = 60
}
struct NetworkPolicy: Codable {
    var enabled = false
    var checkInterval: Double = 10
    var failureChecks = 3
    var returnScanInterval: Double = 60
    var returnScans = 3
    var retryCooldown: Double = 60
    var operationTimeout: Double = 20
    var transactionTimeout: Double = 120
    var probeTimeout: Double = 3
    var requiredHealth: HealthScope = .internet
    var probes: [HealthProbe] = []
}
struct AgentPolicy: Codable {
    var schemaVersion = 1
    var sampleInterval: Double = 0.5
    var awake = AwakePolicy()
    var thermal = ThermalPolicy()
    var wifi = NetworkPolicy()

    func validate() throws {
        func bound(_ value: Double, _ limit: Double, zero: Bool = false) throws {
            guard value.isFinite, value >= (zero ? 0 : 0.05), value <= limit else {
                throw Failure(code: 2, message: "Invalid policy time value.")
            }
        }
        guard schemaVersion == 1 else { throw Failure(code: 2, message: "Policy schemaVersion must be 1.") }
        try bound(sampleInterval, 60)
        try awake.validate()
        guard !awake.enabled || sampleInterval <= 1 else {
            throw Failure(code: 2, message: "Agent-aware thermal safety requires sampleInterval at most 1 second.")
        }
        try bound(thermal.pauseDelay, 3600, zero: true)
        try bound(thermal.resumeDelay, 3600, zero: true)
        guard thermal.resumeAt.rank < thermal.pauseAt.rank else {
            throw Failure(code: 2, message: "Thermal resumeAt must be below pauseAt.")
        }
        try bound(wifi.checkInterval, 3600)
        try bound(wifi.returnScanInterval, 3600)
        try bound(wifi.retryCooldown, 3600)
        try bound(wifi.operationTimeout, 120)
        try bound(wifi.transactionTimeout, 300)
        try bound(wifi.probeTimeout, 30)
        guard (1...100).contains(wifi.failureChecks), (1...100).contains(wifi.returnScans), wifi.probes.count <= 8 else {
            throw Failure(code: 2, message: "Policy check counts must be 1–100; at most eight probes are allowed.")
        }
        if wifi.enabled && wifi.requiredHealth != .association && !wifi.probes.contains(where: { $0.scope == wifi.requiredHealth }) {
            throw Failure(code: 2, message: "Enabled Wi-Fi policy needs an explicit probe for its requiredHealth scope.")
        }
        for probe in wifi.probes {
            guard probe.scope != .association else { throw Failure(code: 2, message: "Probes must have local or internet scope.") }
            switch probe.kind {
            case .tcp:
                guard !probe.host.isEmpty, !probe.host.contains(where: { $0.isWhitespace }), !probe.host.contains("/"),
                      (1...65535).contains(probe.port) else { throw Failure(code: 2, message: "Invalid TCP probe host or port.") }
            case .http:
                guard let url = URL(string: probe.url), ["https", "http"].contains(url.scheme), url.host != nil,
                      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                      (1...65535).contains(url.port ?? 443),
                      (100...599).contains(probe.expectedStatus) else {
                    throw Failure(code: 2, message: "HTTP probes need a URL without credentials, query, or fragment and a valid expectedStatus.")
                }
            }
        }
    }
    var effectiveThermal: ThermalPolicy {
        guard awake.enabled else { return thermal }
        var result = thermal
        result.enabled = true
        result.pauseAt = thermal.pauseAt.rank < awake.cutoff.rank ? thermal.pauseAt : awake.cutoff
        result.pauseDelay = 0
        result.resumeAt = thermal.resumeAt.rank < awake.resumeAt.rank ? thermal.resumeAt : awake.resumeAt
        result.resumeDelay = max(thermal.resumeDelay, awake.resumeDelay)
        return result
    }
}

// Merge omitted fields with defaults while rejecting unknown keys (including typos).
func mergedPolicy(_ supplied: [String: Any], defaults: [String: Any]) throws -> [String: Any] {
    var result = defaults
    for (key, value) in supplied {
        guard let original = defaults[key] else { throw Failure(code: 2, message: "Unknown policy field; compare with policy defaults.") }
        if let nested = original as? [String: Any] {
            guard let object = value as? [String: Any] else { throw Failure(code: 2, message: "Policy section must be an object.") }
            result[key] = try mergedPolicy(object, defaults: nested)
        } else if key == "probes", let probes = value as? [[String: Any]] {
            let template = try JSONSerialization.jsonObject(with: JSONEncoder().encode(HealthProbe())) as! [String: Any]
            result[key] = try probes.map { try mergedPolicy($0, defaults: template) }
        } else { result[key] = value }
    }
    return result
}
func loadPolicy(_ path: String) throws -> AgentPolicy {
    let url = URL(fileURLWithPath: path)
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536,
          let data = try? Data(contentsOf: url), let supplied = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw Failure(code: 2, message: "Policy must be a JSON object of at most 64 KiB.")
    }
    let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentPolicy())) as! [String: Any]
    let merged = try mergedPolicy(supplied, defaults: defaults)
    guard let policy = try? JSONDecoder().decode(AgentPolicy.self, from: JSONSerialization.data(withJSONObject: merged)) else {
        throw Failure(code: 2, message: "Invalid policy field type or enum value.")
    }
    try policy.validate()
    return policy
}
struct Policy: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect, validate, and simulate supervisor rules.",
        subcommands: [PolicyDefaults.self, PolicyValidate.self, PolicySimulate.self])
}
struct PolicyDefaults: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "defaults", abstract: "Emit a JSON policy template; Wi-Fi actions are disabled until explicitly configured.")
    func run() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(AgentPolicy()))
        FileHandle.standardOutput.write(Data([10]))
    }
}
struct PolicyValidate: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "validate")
    @Argument var path: String
    func run() throws { try perform { _ = try loadPolicy(path); emit(["event": "policyValid"]) } }
}
