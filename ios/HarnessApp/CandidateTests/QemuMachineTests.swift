#if os(macOS)
import Foundation
import XCTest
import HarnessCandidate

/// The QEMU process boundary, with a stand-in executable that records its arguments.
final class QemuMachineTests: XCTestCase {
    var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "qemu-machine-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/share,odd", withIntermediateDirectories: true)
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"" + root + "/argv\"\nexec sleep 30\n"
        FileManager.default.createFile(atPath: root + "/qemu", contents: Data(script.utf8), attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    func testItBootsOnceWithTheShareAndReportsOneExitAfterStop() throws {
        let machine = try QemuMachine(.init(executable: root + "/qemu", inputs: root + "/inputs", token: "t", logs: root + "/logs"))
        let exited = expectation(description: "exit")
        var statuses: [Int32?] = []
        machine.onExit = { statuses.append($0); exited.fulfill() }
        try machine.boot(workspace: root + "/share,odd")
        XCTAssertThrowsError(try machine.boot(workspace: root + "/share,odd"))
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: root + "/argv") && Date() < deadline { usleep(10_000) }
        let argv = try String(contentsOfFile: root + "/argv", encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(argv.contains("local,id=workspace,path=" + root + "/share,,odd,security_model=none,writeout=immediate"))
        XCTAssertTrue(argv.contains { $0.hasPrefix("user,id=net,restrict=on,hostfwd=tcp:127.0.0.1:") && $0.hasSuffix("-:4500") })
        XCTAssertFalse(machine.exited)
        machine.stop()
        machine.stop()
        wait(for: [exited], timeout: 10)
        XCTAssertTrue(machine.exited)
        XCTAssertEqual(statuses.count, 1)
        XCTAssertThrowsError(try machine.boot(workspace: root + "/share,odd"), "never restarts in the process")
    }
}
#endif
