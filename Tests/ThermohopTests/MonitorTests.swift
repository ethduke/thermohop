import XCTest
@testable import Thermohop

final class MonitorTests: XCTestCase {
    func testDefaultSafetyAndAgentEligibility() {
        let policy = AwakePolicy()
        XCTAssertEqual(policy.cutoff, .serious)
        XCTAssertEqual(policy.resumeAt, .nominal)
        XCTAssertEqual(policy.resumeDelay, 60)
        var rules = MonitorRules()
        XCTAssertEqual(rules.state(time: 0, pressure: .nominal, agents: 0, lid: "open", policy: policy), .waitingForAgent)
        XCTAssertEqual(rules.state(time: 1, pressure: .nominal, agents: 1, lid: "open", policy: policy), .keepingAwake)
        XCTAssertEqual(rules.state(time: 2, pressure: .fair, agents: 1, lid: "open", policy: policy), .keepingAwake)
        XCTAssertEqual(rules.state(time: 3, pressure: .serious, agents: 1, lid: "open", policy: policy), .cooling)
        XCTAssertEqual(rules.state(time: 4, pressure: .critical, agents: 1, lid: "open", policy: policy), .cooling)
    }

    func testContinuousNominalRecovery() {
        let policy = AwakePolicy()
        var rules = MonitorRules()
        XCTAssertEqual(rules.state(time: 0, pressure: .serious, agents: 1, lid: "open", policy: policy), .cooling)
        XCTAssertEqual(rules.state(time: 1, pressure: .nominal, agents: 1, lid: "open", policy: policy), .cooling)
        XCTAssertEqual(rules.state(time: 60, pressure: .nominal, agents: 1, lid: "open", policy: policy), .cooling)
        XCTAssertEqual(rules.state(time: 61, pressure: .nominal, agents: 1, lid: "open", policy: policy), .keepingAwake)
    }

    func testFairPressureAndRenewedHeatResetRecovery() {
        let policy = AwakePolicy()
        var rules = MonitorRules()
        _ = rules.state(time: 0, pressure: .serious, agents: 1, lid: "open", policy: policy)
        _ = rules.state(time: 1, pressure: .nominal, agents: 1, lid: "open", policy: policy)
        XCTAssertEqual(rules.state(time: 59, pressure: .fair, agents: 1, lid: "open", policy: policy), .cooling)
        _ = rules.state(time: 60, pressure: .nominal, agents: 1, lid: "open", policy: policy)
        XCTAssertEqual(rules.state(time: 119, pressure: .nominal, agents: 1, lid: "open", policy: policy), .cooling)
        XCTAssertEqual(rules.state(time: 120, pressure: .critical, agents: 1, lid: "open", policy: policy), .cooling)
        _ = rules.state(time: 121, pressure: .nominal, agents: 1, lid: "open", policy: policy)
        XCTAssertEqual(rules.state(time: 180, pressure: .nominal, agents: 1, lid: "open", policy: policy), .cooling)
        XCTAssertEqual(rules.state(time: 181, pressure: .nominal, agents: 1, lid: "open", policy: policy), .keepingAwake)
    }

    func testRecoveryWithoutAgentsKeepsSleepAllowed() {
        let policy = AwakePolicy()
        var rules = MonitorRules()
        _ = rules.state(time: 0, pressure: .serious, agents: 0, lid: "open", policy: policy)
        _ = rules.state(time: 1, pressure: .nominal, agents: 0, lid: "open", policy: policy)
        XCTAssertEqual(rules.state(time: 61, pressure: .nominal, agents: 0, lid: "open", policy: policy), .waitingForAgent)
        XCTAssertEqual(rules.state(time: 62, pressure: .nominal, agents: 1, lid: "open", policy: policy), .keepingAwake)
    }

    func testClosedLidDoesNotPreventSleep() {
        let policy = AwakePolicy()
        var rules = MonitorRules()
        XCTAssertEqual(rules.state(time: 0, pressure: .nominal, agents: 1, lid: "closed", policy: policy), .lidClosed)
        XCTAssertEqual(rules.state(time: 1, pressure: .nominal, agents: 1, lid: "open", policy: policy), .keepingAwake)
        XCTAssertEqual(rules.state(time: 2, pressure: .nominal, agents: 1, lid: "unknown", policy: policy), .keepingAwake)
    }

    func testStricterCutoffStillNeedsNominalRecovery() {
        var policy = AwakePolicy()
        policy.cutoff = .fair
        var rules = MonitorRules()
        XCTAssertEqual(rules.state(time: 0, pressure: .fair, agents: 1, lid: "open", policy: policy), .cooling)
        XCTAssertEqual(rules.state(time: 100, pressure: .fair, agents: 1, lid: "open", policy: policy), .cooling)
        _ = rules.state(time: 101, pressure: .nominal, agents: 1, lid: "open", policy: policy)
        XCTAssertEqual(rules.state(time: 160, pressure: .nominal, agents: 1, lid: "open", policy: policy), .cooling)
        XCTAssertEqual(rules.state(time: 161, pressure: .nominal, agents: 1, lid: "open", policy: policy), .keepingAwake)
    }
}
