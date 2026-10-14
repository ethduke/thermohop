import XCTest
@testable import Thermohop

final class ProcessPresentationTests: XCTestCase {
    func testReadableProcessListAndParentRelationship() {
        let agents = [AgentProcess(pid: 10, name: "codex", state: .waiting, parentPID: 2, parentName: "node"),
                      AgentProcess(pid: 11, name: "claude", state: .runnable, parentPID: 10, parentName: "codex")]
        let lines = agentProcessLines(agents)
        XCTAssertTrue(lines[0].contains("1. Codex — PID 10 — waiting — parent: Node.js (PID 2)"))
        XCTAssertTrue(lines[1].contains("2. Claude Code — PID 11 — running / ready — parent: Codex (PID 10)"))
    }

    func testUnknownMetadataDoesNotInventTaskOrRole() {
        let agent = AgentProcess(pid: 12, name: "custom-agent")
        let line = agentProcessLines([agent])[0]
        XCTAssertTrue(line.contains("custom-agent"))
        XCTAssertTrue(line.contains("state unavailable"))
        XCTAssertTrue(line.contains("parent unavailable"))
        XCTAssertFalse(line.contains("worker"))
    }

    func testTerminalControlCharactersCannotInjectLines() {
        let agent = AgentProcess(pid: 13, name: "custom\n\u{1B}[31m", parentPID: 2, parentName: "node\r\t\u{1B}")
        let line = agentProcessLines([agent])[0]
        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("\r"))
        XCTAssertFalse(line.contains("\t"))
        XCTAssertFalse(line.contains("\u{1B}"))
        XCTAssertFalse(safeProcessLabel("label\u{202E}").contains("\u{202E}"))
    }

    func testJSONKeepsIdentifiersAndAddsSafeMetadata() {
        let agent = AgentProcess(pid: 14, name: "codex", state: .waiting, parentPID: 2, parentName: "node")
        XCTAssertEqual(agent.fields["pid"] as? Int32, 14)
        XCTAssertEqual(agent.fields["name"] as? String, "codex")
        XCTAssertEqual(agent.fields["displayName"] as? String, "Codex")
        XCTAssertEqual(agent.fields["state"] as? String, "waiting")
        XCTAssertEqual(agent.fields["parentPID"] as? Int32, 2)
        XCTAssertNil(agent.fields["arguments"])
        XCTAssertNil(agent.fields["path"])
        XCTAssertNil(agent.fields["task"])
    }

    func testStatusMakesReadOnlyAndUnknownTaskScopeClear() {
        let text = readableAwakeStatus(agents: [], pressure: .nominal, cutoff: .serious, lid: "unknown")
        XCTAssertTrue(text.contains("Thermal: normal (level 0; cutoff 2)"))
        XCTAssertTrue(text.contains("Lid: unavailable"))
        XCTAssertTrue(text.contains("No recognized agent processes"))
        XCTAssertTrue(text.contains("Task titles are unavailable"))
        XCTAssertTrue(text.contains("creates no sleep assertion"))
    }
}
