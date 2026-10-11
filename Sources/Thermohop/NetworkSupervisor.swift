import Foundation

final class NetworkSupervisor {
    let policy: NetworkPolicy
    let profiles: [Profile]
    let options: WiFiOptions
    let observeOnly: Bool
    let cancellation: Cancellation
    let started: Double
    private var rules = NetworkRules()
    private let allowed: () -> Bool
    private let generation: () -> UInt64
    private var lastGeneration: UInt64?
    private var mutationStarted = false
    private let group = DispatchGroup()
    private let queue = DispatchQueue(label: "thermohop.network-supervisor")

    init(policy: NetworkPolicy, profiles: [Profile], options: WiFiOptions,
         observeOnly: Bool, cancellation: Cancellation, started: Double, allowed: @escaping () -> Bool = { true }, generation: @escaping () -> UInt64 = { 0 }) {
        self.policy = policy; self.profiles = profiles; self.options = options
        self.observeOnly = observeOnly; self.cancellation = cancellation; self.started = started; self.allowed = allowed; self.generation = generation
    }
    var elapsed: Double { ProcessInfo.processInfo.systemUptime - started }
    func call(_ operation: String, ssid: String? = nil, budget: Double? = nil) throws -> [String: Any] {
        guard allowed(), !cancellation.cancelled else { throw Failure(code: 130, message: "Network policy suspended.") }
        let epoch = generation()
        guard epoch == (lastGeneration ?? epoch) else { throw Failure(code: 130, message: "Network eligibility changed during this check.") }
        if operation == "join" { mutationStarted = true }
        return try worker(operation, options: options, ssid: ssid,
            timeout: min(options.timeout, budget ?? options.timeout), cancelled: { self.cancellation.cancelled || !self.allowed() || self.generation() != epoch })
    }
    func start() {
        group.enter()
        queue.async {
            defer { self.group.leave() }
            while !self.cancellation.cancelled {
                if !self.allowed() { self.rules.resetProgress() }
                else if !self.rules.blocked { self.cycle() }
                self.cancellation.wait(self.policy.checkInterval)
            }
        }
    }
    func finish() { _ = group.wait(timeout: .now() + 2) }
    func intervention(_ reason: String, code: Int32) {
        rules.block()
        emit(["event": "interventionRequired", "component": "wifi", "reason": reason, "code": code, "automaticSwitchingBlocked": true])
    }
    func cycle() {
        mutationStarted = false
        let epoch = generation()
        if lastGeneration != epoch { rules.resetProgress(); lastGeneration = epoch }
        do {
            let status = try call("status")
            guard !cancellation.cancelled, allowed() else { return }
            let location = status["location"] as? [String: Any]
            guard location?["authorization"] as? String == "authorized", location?["initialized"] as? Bool == true else {
                intervention("locationPermissionUnavailable", code: 4); return
            }
            guard status["powerOn"] as? Bool == true else { intervention("wifiRadioOff", code: 3); return }
            guard let ssid = status["ssid"] as? String else {
                intervention("ssidUnavailable", code: 5); return
            }
            if !profiles.contains(where: { $0.ssid == ssid }) {
                intervention("currentNetworkNotConfigured", code: 6); return
            }
            let health = checkHealth(associated: true, policy: policy, cancellation: cancellation, budget: policy.probeTimeout * Double(max(1, policy.probes.count)))
            guard !cancellation.cancelled, allowed() else { return }
            var observation = NetworkObservation(time: elapsed, ssid: ssid, healthy: health.healthy(policy.requiredHealth), permissionReady: true)
            if rules.needsScan(observation, policy: policy, profiles: profiles) {
                let scan = try call("scan")
                let networks = scan["networks"] as? [[String: Any]] ?? []
                observation.visible = Set(networks.filter {
                    ["wpa2Personal", "wpa3Personal", "wpa3Transition"].contains($0["security"] as? String ?? "")
                }.compactMap { $0["ssid"] as? String })
            }
            guard allowed(), !cancellation.cancelled else { return }
            guard generation() == epoch else { rules.resetProgress(); return }
            emit(["event": "networkObservation", "ssid": ssid, "health": health.fields,
                  "requiredHealth": policy.requiredHealth.rawValue, "elapsedSeconds": observation.time])
            guard let decision = rules.decide(observation, policy: policy, profiles: profiles) else { return }
            emit(decision.fields())
            if decision.candidates.isEmpty || observeOnly {
                emit(["event": "actionResult", "action": decision.action, "result": observeOnly ? "proposed" : "noCandidate",
                      "verified": false, "nextRetrySeconds": rules.retryAt]); return
            }
            do { try transact(decision, original: ssid) }
            catch {
                emit(["event": "actionResult", "action": decision.action, "result": "unverified",
                      "verified": false, "nextRetrySeconds": NSNull()])
                throw error
            }
        } catch let failure as Failure {
            if cancellation.cancelled { return }
            if !allowed() || (failure.code == 130 && !mutationStarted) {
                if mutationStarted { intervention("policySuspendedDuringAssociation", code: 5) }
                else { rules.resetProgress() }
                return
            }
            if [3, 4, 5, 130].contains(failure.code) { intervention("networkOutcomeUnknownOrUnavailable", code: failure.code) }
            else {
                rules.complete(time: elapsed, policy: policy, uncertain: false)
                emit(["event": "networkCheckFailed", "code": failure.code, "nextRetrySeconds": rules.retryAt])
            }
        } catch {
            if !cancellation.cancelled && allowed() { intervention("internalNetworkFailure", code: 1) }
        }
    }
    func verify(_ target: String, deadline: Double) throws -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw Failure(code: 5, message: "Network transaction deadline exceeded.") }
        let status = try call("status", budget: remaining)
        let location = status["location"] as? [String: Any]
        guard location?["authorization"] as? String == "authorized", location?["initialized"] as? Bool == true else {
            throw Failure(code: 4, message: "Location access unavailable during verification.")
        }
        guard let current = status["ssid"] as? String else { throw Failure(code: 5, message: "Association outcome is unknown.") }
        guard current == target else { throw Failure(code: 5, message: "Network changed outside the expected transaction.") }
        let health = checkHealth(associated: true, policy: policy, cancellation: cancellation,
            budget: max(0, deadline - ProcessInfo.processInfo.systemUptime))
        guard !cancellation.cancelled, allowed() else { throw Failure(code: 130, message: "Network transaction cancelled.") }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw Failure(code: 5, message: "Network verification timed out.") }
        emit(["event": "networkVerification", "ssid": target, "health": health.fields, "healthy": health.healthy(policy.requiredHealth)])
        return health.healthy(policy.requiredHealth)
    }
    func transact(_ decision: Decision, original: String?) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + policy.transactionTimeout
        for target in decision.candidates {
            guard !cancellation.cancelled, allowed() else { throw Failure(code: 130, message: "Network transaction cancelled.") }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Failure(code: 5, message: "Network transaction timed out.") }
            emit(["event": "networkAttempt", "ssid": target, "action": decision.action])
            do {
                _ = try call("join", ssid: target, budget: remaining)
                if try verify(target, deadline: deadline) {
                    rules.complete(time: elapsed, policy: policy, uncertain: false)
                    emit(["event": "actionResult", "action": decision.action, "ssid": target, "verified": true,
                          "result": "succeeded", "nextRetrySeconds": rules.retryAt]); return
                }
                emit(["event": "networkAttemptFailed", "ssid": target, "reason": "healthRequirementNotMet"])
            } catch let failure as Failure {
                if [3, 4, 5, 130].contains(failure.code) { throw failure }
                // Even an API error may accompany a changed association: observe before another mutation.
                let status = try call("status", budget: max(0.01, deadline - ProcessInfo.processInfo.systemUptime))
                guard let current = status["ssid"] as? String,
                      profiles.contains(where: { $0.ssid == current }) else {
                    throw Failure(code: 5, message: "Failed association left an unknown connection outcome.")
                }
                emit(["event": "networkAttemptFailed", "ssid": target, "code": failure.code])
            }
        }
        // Restore only an explicitly configured previous network, after a known failed outcome.
        if let original, profiles.contains(where: { $0.ssid == original }), !cancellation.cancelled, allowed() {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Failure(code: 5, message: "No time remaining for rollback.") }
            emit(["event": "rollbackAttempt", "ssid": original])
            do {
                _ = try call("join", ssid: original, budget: remaining)
                let verified = try verify(original, deadline: deadline)
                emit(["event": "rollbackResult", "ssid": original, "verified": verified])
            } catch let failure as Failure {
                if [3, 4, 5, 130].contains(failure.code) { throw failure }
                emit(["event": "rollbackResult", "ssid": original, "verified": false, "code": failure.code])
            }
        }
        rules.complete(time: elapsed, policy: policy, uncertain: false)
        emit(["event": "actionResult", "action": decision.action, "result": "failed", "verified": false, "nextRetrySeconds": rules.retryAt])
    }
}
