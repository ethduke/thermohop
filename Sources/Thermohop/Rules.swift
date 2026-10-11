import Foundation

struct Decision {
    var action: String
    var reason: String
    var candidates: [String] = []
    var retryAt: Double = 0
    func fields(simulated: Bool = false) -> [String: Any] {
        ["event": "policyDecision", "action": action, "reason": reason,
         "candidates": candidates, "nextRetrySeconds": retryAt, "simulated": simulated]
    }
}
struct ThermalRules {
    var pausedBySupervisor = false
    private var hotSince: Double?
    private var coolSince: Double?
    private(set) var retryAt: Double = 0
    mutating func decide(time: Double, pressure: Pressure, policy: ThermalPolicy) -> Decision? {
        guard policy.enabled else { return nil }
        if pressure.rank >= policy.pauseAt.rank {
            if hotSince == nil { hotSince = time }
        } else { hotSince = nil }
        if pressure.rank <= policy.resumeAt.rank {
            if coolSince == nil { coolSince = time }
        } else { coolSince = nil }
        guard time >= retryAt else { return nil }
        if !pausedBySupervisor && (pressure == .critical || hotSince.map({ time - $0 >= policy.pauseDelay }) == true) {
            return Decision(action: "pauseWorkload", reason: pressure == .critical ? "criticalPressure" : "sustainedPressure", retryAt: time)
        }
        if pausedBySupervisor && coolSince.map({ time - $0 >= policy.resumeDelay }) == true {
            return Decision(action: "resumeWorkload", reason: "sustainedRecovery", retryAt: time)
        }
        return nil
    }
    mutating func complete(_ decision: Decision, verified: Bool, time: Double) {
        if verified { pausedBySupervisor = decision.action == "pauseWorkload"; retryAt = time }
        else { retryAt = time + 5 }
    }
}
struct NetworkObservation {
    var time: Double
    var ssid: String?
    var healthy: Bool
    var permissionReady: Bool
    var visible: Set<String>?
}
struct NetworkRules {
    private(set) var blocked = false
    private(set) var failures = 0
    private(set) var retryAt: Double = 0
    private(set) var previousRegular: String?
    private var returnCandidate: String?
    private var appearances = 0
    private var lastScan: Double = -.infinity
    mutating func block() { blocked = true }
    mutating func resetProgress() {
        failures = 0; appearances = 0; returnCandidate = nil; lastScan = -.infinity
        // Preserve cooldowns, remembered regular network, and intervention blocks.
    }
    func needsScan(_ observation: NetworkObservation, policy: NetworkPolicy, profiles: [Profile]) -> Bool {
        guard policy.enabled, !blocked, observation.permissionReady, observation.time >= retryAt else { return false }
        if !observation.healthy && failures + 1 >= policy.failureChecks { return true }
        return profiles.contains { $0.ssid == observation.ssid && $0.role == .hotspot }
            && observation.time - lastScan >= policy.returnScanInterval
    }
    mutating func decide(_ observation: NetworkObservation, policy: NetworkPolicy, profiles: [Profile]) -> Decision? {
        guard policy.enabled, !blocked else { return nil }
        guard observation.permissionReady, observation.ssid != nil else {
            blocked = true
            return Decision(action: "interventionRequired", reason: "permissionOrConnectionUnknown")
        }
        if let ssid = observation.ssid, !profiles.contains(where: { $0.ssid == ssid }) {
            blocked = true
            return Decision(action: "interventionRequired", reason: "currentNetworkNotConfigured")
        }
        if let current = profiles.first(where: { $0.ssid == observation.ssid && $0.role == .regular }) {
            previousRegular = current.ssid
        }
        if !profiles.contains(where: { $0.ssid == observation.ssid && $0.role == .hotspot }) {
            appearances = 0; returnCandidate = nil
        }
        failures = observation.healthy ? 0 : min(failures + 1, policy.failureChecks)
        guard observation.time >= retryAt else { return nil }
        if let visible = observation.visible {
            let returnScanDue = observation.time - lastScan >= policy.returnScanInterval
            if returnScanDue || failures >= policy.failureChecks { lastScan = observation.time }
            let regular = profiles.filter { $0.role == .regular && visible.contains($0.ssid) }.sorted {
                if $0.ssid == $1.ssid { return false }
                if $0.ssid == previousRegular { return true }
                if $1.ssid == previousRegular { return false }
                return $0.priority == $1.priority ? $0.ssid < $1.ssid : $0.priority < $1.priority
            }
            if failures >= policy.failureChecks {
                let ordered = orderedProfiles(ProfileFile(profiles: profiles))
                let eligible = ordered.filter { visible.contains($0.ssid) && $0.ssid != observation.ssid }.map(\.ssid)
                retryAt = observation.time + policy.retryCooldown
                appearances = 0; returnCandidate = nil
                return Decision(action: eligible.isEmpty ? "networkUnavailable" : "fallback", reason: "consecutiveHealthFailures",
                    candidates: eligible, retryAt: retryAt)
            }
            if !returnScanDue { return nil }
            if profiles.contains(where: { $0.ssid == observation.ssid && $0.role == .hotspot }) {
                if let candidate = regular.first?.ssid {
                    if candidate == returnCandidate { appearances += 1 }
                    else { returnCandidate = candidate; appearances = 1 }
                    if appearances >= policy.returnScans {
                        appearances = 0; retryAt = observation.time + policy.retryCooldown
                        return Decision(action: "returnToRegular", reason: "regularNetworkStable",
                            candidates: regular.map(\.ssid), retryAt: retryAt)
                    }
                } else { appearances = 0; returnCandidate = nil }
            } else { appearances = 0; returnCandidate = nil }
        }
        return nil
    }
    mutating func complete(time: Double, policy: NetworkPolicy, uncertain: Bool) {
        failures = 0; appearances = 0; returnCandidate = nil
        retryAt = time + policy.retryCooldown
        if uncertain { blocked = true }
    }
}
