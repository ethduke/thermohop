import Foundation

struct AwakePolicy: Codable {
    var enabled = true
    var closedLid = false
    var agents = ["claude", "codex", "aider", "goose", "opencode", "gemini"]
    var pids: [Int32] = []
    var cutoff: Pressure = .serious
    var resumeAt: Pressure = .nominal
    var resumeDelay: Double = 60
    func validate() throws {
        guard cutoff == .fair || cutoff == .serious, resumeAt.rank < cutoff.rank,
              resumeDelay.isFinite, resumeDelay >= 0, resumeDelay <= 3600,
              agents.count <= 32, pids.count <= (closedLid ? 255 : 256),
              agents.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\0") && $0.utf8.count <= 255 }),
              pids.allSatisfy({ $0 > 0 }), !closedLid || enabled else {
            throw Failure(code: 2, message: "Invalid awake policy: use fair/serious cutoff, lower resumeAt, bounded delay and process selectors; closedLid requires enabled=true.")
        }
    }
}

struct AwakeRecoveryRules {
    private(set) var cooling = false
    private var coolSince: Double?
    mutating func allowsActivity(time: Double, pressure: Pressure, policy: AwakePolicy) -> Bool {
        if pressure.rank >= policy.cutoff.rank { cooling = true; coolSince = nil }
        if cooling {
            if pressure.rank <= policy.resumeAt.rank {
                if coolSince == nil { coolSince = time }
                if time - coolSince! >= policy.resumeDelay { cooling = false; coolSince = nil }
            } else { coolSince = nil }
        }
        return !cooling
    }
}

final class ActivityGate {
    private let lock = NSLock()
    private var enabled = false
    private var epoch: UInt64 = 0
    let cutoff: Pressure
    init(cutoff: Pressure) { self.cutoff = cutoff }
    func set(_ value: Bool) {
        lock.lock(); if enabled != value { epoch &+= 1 }; enabled = value; lock.unlock()
    }
    var generation: UInt64 { lock.lock(); defer { lock.unlock() }; return epoch }
    var allowed: Bool {
        lock.lock(); let value = enabled; lock.unlock()
        // Recheck live pressure at the actual worker launch boundary rather than
        // trusting a possibly stale observation from the main sampling loop.
        return value && Pressure.current.rank < cutoff.rank
    }
}

final class SupervisorAwake {
    let policy: AwakePolicy
    let observeOnly: Bool
    private let assertion = SleepAssertion()
    private let lease: ClosedLidLease?
    private let lock: SupervisorLock?
    private var rules = AwakeRecoveryRules()
    private var pendingSince: Double?
    private var lastPlan: Bool?
    private(set) var cooling = false
    private var stopped = false

    init(policy: AwakePolicy, observeOnly: Bool) throws {
        self.policy = policy; self.observeOnly = observeOnly
        lock = policy.enabled && !observeOnly ? try SupervisorLock(name: "awake") : nil
        lease = policy.enabled && policy.closedLid && !observeOnly ? try ClosedLidLease() : nil
    }
    func update(time: Double, pressure: Pressure, agents: [AgentProcess], owned: OwnedWorkload?, ownsPause: Bool) throws -> Bool {
        let safe = rules.allowsActivity(time: time, pressure: pressure, policy: policy)
        cooling = rules.cooling
        let ownedIntent = owned.map { $0.exitCode == nil && (!$0.stopped || ownsPause) } ?? false
        let desired = safe && (!agents.isEmpty || ownedIntent)
        if !policy.enabled { return true }
        if lastPlan != desired {
            emit(["event": "policyDecision", "action": desired ? "preventIdleSleep" : "allowSleep",
                  "reason": cooling ? "thermalSafetyAndRecovery" : (desired ? "agentOrOwnedWorkloadPresent" : "noDetectedAgents"),
                  "simulated": observeOnly])
            lastPlan = desired
        }
        if observeOnly {
            emitIfProposed(desired: desired)
            return desired
        }
        if !desired {
            lease?.withdraw(); pendingSince = nil
            if assertion.held {
                try assertion.release()
                emit(["event": "actionResult", "action": "allowSleep", "verified": true,
                      "verification": "processOwnedAssertionReleased", "closedLidRestorationPending": lease != nil])
            }
            return false
        }
        if let lease {
            var options = try AwakeOptions.parse([])
            options.agent = policy.agents; options.pid = policy.pids; options.cutoff = policy.cutoff
            if let owned, owned.exitCode == nil, !options.pid.contains(owned.pid) { options.pid.append(owned.pid) }
            try lease.renew(options: options)
            if !lease.confirmed() {
                if assertion.held { try assertion.release() }
                if pendingSince == nil {
                    pendingSince = time
                    emit(["event": "closedLidLeasePending", "verified": false])
                }
                if time - pendingSince! >= 3 {
                    throw Failure(code: 3, message: "The closed-lid watchdog did not confirm this supervisor's lease; stopping.")
                }
                return false
            }
            if pendingSince != nil { emit(["event": "closedLidLeaseConfirmed", "verified": true]); pendingSince = nil }
        }
        let held = assertion.held
        try assertion.acquire()
        if !held { emit(["event": "actionResult", "action": "preventIdleSleep", "verified": true,
                         "verification": "timedOSAssertion", "leaseSeconds": SleepAssertion.leaseSeconds]) }
        return true
    }
    private var lastProposal: Bool?
    private func emitIfProposed(desired: Bool) {
        guard lastProposal != desired else { return }; lastProposal = desired
        emit(["event": "actionResult", "action": desired ? "preventIdleSleep" : "allowSleep", "result": "proposed", "verified": false])
    }
    func stop() throws {
        guard !stopped else { return }; stopped = true
        lease?.withdraw()
        try assertion.release()
        let restored = lease?.waitForRestoration() ?? true
        emit(["event": "sleepPreventionStopped", "assertionHeld": false, "closedLidRestorationVerified": restored,
              "verified": !observeOnly && restored])
        if !restored { throw Failure(code: 5, message: "Closed-lid sleep restoration is pending; the independent watchdogs remain responsible for cleanup.") }
    }
    deinit { lease?.withdraw(); withExtendedLifetime(lock) {} }
}
