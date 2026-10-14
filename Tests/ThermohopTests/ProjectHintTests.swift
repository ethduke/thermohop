import Foundation
import XCTest
@testable import Thermohop

final class ProjectHintTests: XCTestCase {
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    func testOnlyWorkingFolderBasenameIsReturned() {
        XCTAssertEqual(projectNameHint("/workspace/private-parent/example-project", homeDirectory: home), "example-project")
        XCTAssertEqual(projectNameHint("/workspace/example-project/", homeDirectory: home), "example-project")
        XCTAssertEqual(projectNameHint("/workspace/other/../example-project", homeDirectory: home), "example-project")
    }

    func testHomeAndSystemDirectoriesRemainUnknown() {
        for path in ["/", home, home + "/Documents", home + "/Desktop", "/Applications/Agent.app/Contents/Resources",
                     "/System/Library", "/private/tmp", "/workspace/node_modules", "/Volumes/Drive"] {
            XCTAssertNil(projectNameHint(path, homeDirectory: home), "Generic directory should not become a project")
        }
        XCTAssertNil(projectNameHint("relative/project", homeDirectory: home))
    }

    func testProjectLabelCannotInjectTerminalControls() {
        let name = projectNameHint("/workspace/example\n\u{1B}[31m", homeDirectory: home)
        XCTAssertNotNil(name)
        XCTAssertFalse(name!.contains("\n"))
        XCTAssertFalse(name!.contains("\u{1B}"))
    }

    func testJSONAndHumanOutputContainOnlyProjectName() throws {
        let hint = projectNameHint("/workspace/private-parent/example-project", homeDirectory: home)
        let agent = AgentProcess(pid: 1, name: "codex", projectName: hint)
        let json = String(data: try JSONSerialization.data(withJSONObject: agent.fields), encoding: .utf8)!
        let line = agentProcessLines([agent])[0]
        XCTAssertEqual(agent.fields["projectName"] as? String, "example-project")
        XCTAssertEqual(agent.fields["projectSource"] as? String, "workingDirectory")
        XCTAssertTrue(line.contains("project folder: example-project"))
        XCTAssertFalse(json.contains("private-parent"))
        XCTAssertFalse(json.contains("/workspace"))
        XCTAssertFalse(line.contains("private-parent"))
        XCTAssertNil(agent.fields["cwd"])
        XCTAssertNil(agent.fields["path"])
    }

    func testProjectChangesInvalidatePresentationEvenForSamePID() {
        let first = AgentProcess(pid: 1, name: "codex", projectName: "first-project")
        let second = AgentProcess(pid: 1, name: "codex", projectName: "second-project")
        XCTAssertNotEqual(first.presentationKey, second.presentationKey)
        XCTAssertNotEqual(AgentProcess(pid: 1, name: "codex").presentationKey,
                          AgentProcess(pid: 1, name: "codex", projectName: "unknown").presentationKey)
    }
}
