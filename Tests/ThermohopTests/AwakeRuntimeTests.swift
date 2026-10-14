import XCTest
import Darwin
import IOKit.pwr_mgt
@testable import Thermohop

final class AwakeRuntimeTests: XCTestCase {
    func testRunningMonitorCanAllowSleep() {
        let status = AwakeRuntimeStatus(monitorState: .running, monitorPID: 12, mode: .monitor,
                                        assertionHeld: false, closedLidPrevention: false)
        XCTAssertTrue(status.readableLines.contains("Monitor: running (PID 12; open-lid monitor)"))
        XCTAssertTrue(status.readableLines.contains("Sleep prevention by Thermohop: inactive"))
        XCTAssertEqual(status.fields["monitorRunning"] as? Bool, true)
        XCTAssertEqual(status.fields["sleepPreventionActive"] as? Bool, false)
    }

    func testPausedMonitorReportsActualLeaseInsteadOfInferringItsRelease() {
        var status = AwakeRuntimeStatus(monitorState: .paused, monitorPID: 12,
                                       assertionHeld: true, closedLidPrevention: false)
        XCTAssertEqual(status.fields["monitorRunning"] as? Bool, false)
        XCTAssertEqual(status.preventingSleep, true)
        status.assertionHeld = false
        XCTAssertEqual(status.preventingSleep, false)
        XCTAssertTrue(status.readableLines.contains("Monitor: paused (PID 12)"))
    }

    func testUnavailableObservationDoesNotPretendSleepIsAllowed() {
        let status = AwakeRuntimeStatus(monitorState: .stopped, assertionHeld: nil, closedLidPrevention: false)
        XCTAssertNil(status.preventingSleep)
        XCTAssertTrue(status.fields["assertionHeld"] is NSNull)
        XCTAssertTrue(status.readableLines.contains("Sleep prevention by Thermohop: unavailable"))
        XCTAssertTrue(AwakeRuntimeStatus().fields["monitorRunning"] is NSNull)
    }

    func testClosedLidWatchdogRestorationCanOutliveStoppedController() {
        let status = AwakeRuntimeStatus(monitorState: .stopped, assertionHeld: false, closedLidPrevention: true)
        XCTAssertEqual(status.preventingSleep, true)
        XCTAssertTrue(status.readableLines.contains("Closed-lid sleep override: active (system-wide)"))
        XCTAssertEqual(AwakeRuntimeStatus(assertionHeld: true, closedLidPrevention: nil).preventingSleep, true)
    }

    func testLockIdentityRejectsPIDReuseAndOtherUsers() throws {
        let owner = try SupervisorLockOwner(mode: .monitor)
        var info = try XCTUnwrap(processIdentity(getpid()))
        XCTAssertEqual(owner.state(for: info, uid: getuid()), .running)
        info.pbi_status = 4
        XCTAssertEqual(owner.state(for: info, uid: getuid()), .paused)
        info.pbi_start_tvusec += 1
        XCTAssertEqual(owner.state(for: info, uid: getuid()), .unknown)
        XCTAssertEqual(owner.state(for: nil, uid: getuid()), .unknown)
        XCTAssertEqual(owner.state(for: processIdentity(getpid()), uid: getuid() + 1), .unknown)
    }

    func testOnlyActiveNamedIdleAssertionCounts() {
        var assertion: [String: Any] = [kIOPMAssertionNameKey: SleepAssertion.name,
            kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn]
        XCTAssertTrue(isThermohopSleepAssertion(assertion))
        assertion[kIOPMAssertionNameKey] = "another application"
        XCTAssertFalse(isThermohopSleepAssertion(assertion))
        assertion[kIOPMAssertionNameKey] = SleepAssertion.name
        assertion[kIOPMAssertionLevelKey] = kIOPMAssertionLevelOff
        XCTAssertFalse(isThermohopSleepAssertion(assertion))
        assertion[kIOPMAssertionLevelKey] = kIOPMAssertionLevelOn
        assertion[kIOPMAssertionTypeKey] = "other assertion type"
        XCTAssertFalse(isThermohopSleepAssertion(assertion))
    }
}
