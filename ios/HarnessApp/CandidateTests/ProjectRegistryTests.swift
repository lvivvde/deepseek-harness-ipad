import Foundation
import XCTest
import HarnessCandidate

/// Candidate projects: each one a native workspace with its own durable state, mounted in the Worker
/// at `/dsh/workspace/<name>`.
final class ProjectRegistryTests: XCTestCase {
    var root = ""

    override func setUpWithError() throws { root = NSTemporaryDirectory() + "candidate-registry-" + UUID().uuidString }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func code(_ work: () throws -> Any) -> String? {
        do { _ = try work(); return nil } catch let error as CandidateError { return error.code } catch { return "\(error)" }
    }

    func testCreatedProjectsSurviveReopenWithTheirOwnDirectories() throws {
        let registry = try ProjectRegistry(root: root)
        let demo = try registry.create(name: "演示", pluginEnabled: true)
        let notes = try registry.create(name: "notes", pluginEnabled: false)
        XCTAssertEqual(demo.mount, "/dsh/workspace/演示")
        XCTAssertNotEqual(demo.id, notes.id)
        XCTAssertNotNil(UUID(uuidString: demo.id))
        for project in [demo, notes] {
            var directory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: registry.workspace(project), isDirectory: &directory) && directory.boolValue)
            XCTAssertNotEqual(registry.workspace(project), registry.state(project))
        }
        let reopened = try ProjectRegistry(root: root)
        XCTAssertEqual(reopened.projects, [notes, demo].sorted { $0.name < $1.name })
    }

    func testNamesAreSingleSafeComponentsAndUnique() throws {
        let registry = try ProjectRegistry(root: root)
        _ = try registry.create(name: "app", pluginEnabled: false)
        XCTAssertEqual(code { try registry.create(name: "app", pluginEnabled: true) }, "PROJECT_NAME_TAKEN")
        for bad in ["", ".", "..", ".hidden", "a/b", "a\u{0}b", "line\nbreak", String(repeating: "x", count: 65)] {
            XCTAssertEqual(code { try registry.create(name: bad, pluginEnabled: false) }, "PROJECT_NAME_REFUSED", bad)
        }
        XCTAssertEqual(registry.projects.map(\.name), ["app"])
    }
}
