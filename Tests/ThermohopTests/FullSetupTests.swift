import Foundation
import XCTest
import Darwin
@testable import Thermohop

final class FullSetupTests: XCTestCase {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thermohop-setup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPresetCoordinatesAllFeaturesWithoutChangingFactoryDefaults() throws {
        let policy = try fullSetupPolicy()
        XCTAssertTrue(isFullSetupPolicy(policy))
        XCTAssertEqual(policy.awake.cutoff, .serious)
        XCTAssertEqual(policy.effectiveThermal.pauseAt, .serious)
        XCTAssertEqual(policy.effectiveThermal.resumeDelay, 60)
        XCTAssertEqual(policy.wifi.requiredHealth, .internet)
        XCTAssertEqual(policy.wifi.probes.count, 1)
        XCTAssertFalse(AgentPolicy().awake.closedLid)
        XCTAssertFalse(AgentPolicy().wifi.enabled)
    }

    func testInvalidProbeCannotBeSavedBySetup() {
        XCTAssertThrowsError(try fullSetupPolicy(probeURL: "https://example.invalid/?token=synthetic"))
        XCTAssertThrowsError(try fullSetupPolicy(probeURL: "file:///workspace/example"))
    }

    func testPrivatePolicyCreationAndIdempotentRerunPreserveCustomRules() throws {
        let path = try temporaryDirectory().appendingPathComponent("policy.json").path
        var policy = try fullSetupPolicy()
        policy.awake.agents = ["example-agent"]
        policy.wifi.checkInterval = 27
        try saveSetupPolicy(policy, path: path, replace: false)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        try saveSetupPolicy(try fullSetupPolicy(), path: path, replace: false)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        XCTAssertEqual(try loadPolicy(path).awake.agents, ["example-agent"])
        XCTAssertEqual(try loadPolicy(path).wifi.checkInterval, 27)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testExistingPartialPolicyRequiresExplicitReplacement() throws {
        let path = try temporaryDirectory().appendingPathComponent("policy.json")
        let original = Data("{\"wifi\":{\"enabled\":false}}".utf8)
        try original.write(to: path)
        XCTAssertThrowsError(try saveSetupPolicy(fullSetupPolicy(), path: path.path, replace: false))
        XCTAssertEqual(try Data(contentsOf: path), original)
        try saveSetupPolicy(fullSetupPolicy(), path: path.path, replace: true)
        XCTAssertTrue(isFullSetupPolicy(try loadPolicy(path.path)))
    }

    func testSymlinkCannotOverwriteAnotherFile() throws {
        let root = try temporaryDirectory()
        let target = root.appendingPathComponent("keep.txt")
        let link = root.appendingPathComponent("policy.json")
        try Data("keep this".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try saveSetupPolicy(fullSetupPolicy(), path: link.path, replace: true))
        XCTAssertEqual(try String(contentsOf: target), "keep this")
    }

    func testProfileMetadataPreservesPrioritiesAndDoesNotStorePasswords() throws {
        let path = try temporaryDirectory().appendingPathComponent("profiles.json").path
        try setupProfiles(regular: "Example router", hotspot: "Example phone", path: path)
        var profiles = try readProfiles(path)
        profiles.profiles[0].priority = 23
        try writeProfiles(profiles, to: path)
        try setupProfiles(regular: "Example router", hotspot: "Example phone", path: path)
        XCTAssertEqual(try readProfiles(path).profiles[0].priority, 23)
        XCTAssertThrowsError(try setupProfiles(regular: "Example router", hotspot: "Other phone", path: path))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "profiles"])
    }

    func testReadinessNeverClaimsNetworkVerificationFromMetadataAlone() {
        let ready = SetupReadiness(policyReady: true, installedApp: true, credentialsReady: true,
                                   locationReady: true, watchdogReady: true)
        XCTAssertTrue(ready.ready)
        XCTAssertEqual(ready.fields["networkChecked"] as? Bool, false)
        XCTAssertEqual(ready.fields["networkAccessVerified"] as? Bool, false)
        XCTAssertEqual(ready.fields["supervisionStarted"] as? Bool, false)
        XCTAssertFalse(SetupReadiness().ready)
        XCTAssertFalse(SetupReadiness().nextSteps.isEmpty)
    }

    func testInstallationMarkerUsesMetadataWithoutOpeningRootPrivateContents() throws {
        let directory = try temporaryDirectory()
        let marker = directory.appendingPathComponent("marker")
        try Data("thermohop optional awake helper\n".utf8).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        XCTAssertTrue(setupInstallationMarker(marker.path, owner: getuid()))
        XCTAssertFalse(setupInstallationMarker(marker.path, owner: getuid() + 1))
        let link = directory.appendingPathComponent("linked-marker")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: marker)
        XCTAssertFalse(setupInstallationMarker(link.path, owner: getuid()))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path)
        XCTAssertFalse(setupInstallationMarker(marker.path, owner: getuid()))
    }

    func testWatchdogJobRequiresRunningTrustedProgramAndPID() {
        let identity = "state = running\nprogram = /trusted/helper\npid = 12345\n"
        XCTAssertTrue(setupJobIdentity(identity, executable: "/trusted/helper"))
        XCTAssertFalse(setupJobIdentity(identity, executable: "/other/helper"))
        XCTAssertFalse(setupJobIdentity(identity.replacingOccurrences(of: "running", with: "waiting"), executable: "/trusted/helper"))
        XCTAssertFalse(setupJobIdentity(identity.replacingOccurrences(of: "12345", with: "0"), executable: "/trusted/helper"))
    }

    func testCompatibleHeartbeatRequiresFreshSafeContractForCurrentUser() {
        var status: [String: Any] = ["uid": 501, "active": false, "sleepRestored": true,
                                   "token": "", "cutoffLevel": 2, "expires": 0.0, "uptime": 100.0]
        XCTAssertTrue(setupHeartbeatReady(status, uid: 501, now: 101))
        XCTAssertFalse(setupHeartbeatReady(status, uid: 502, now: 101))
        XCTAssertFalse(setupHeartbeatReady(status, uid: 501, now: 104))
        XCTAssertFalse(setupHeartbeatReady(status, uid: 501, now: 99))
        status["protocolVersion"] = 2
        XCTAssertFalse(setupHeartbeatReady(status, uid: 501, now: 101))
        status["protocolVersion"] = 1; status["cutoffLevel"] = 3
        XCTAssertFalse(setupHeartbeatReady(status, uid: 501, now: 101))
    }
}
