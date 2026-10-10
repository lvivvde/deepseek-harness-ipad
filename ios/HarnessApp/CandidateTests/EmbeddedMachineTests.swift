import Darwin
import Foundation
import XCTest
import HarnessCandidate

/// The in-process VM boundary, with a stand-in engine in place of the QEMU library: it records the
/// arguments, writes to the serial socket and runs until QMP asks it to quit.
final class EmbeddedMachineTests: XCTestCase {
    var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "embedded-machine-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/share,odd", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    private func configuration() -> EmbeddedMachine.Configuration {
        .init(inputs: root + "/inputs", firmware: root + "/qemu", token: "t", logs: root + "/logs")
    }

    /// The descriptor a `-chardev socket,id=<id>,fd=<n>` argument names.
    private static func descriptor(_ arguments: [String], _ id: String) -> Int32? {
        arguments.first { $0.hasPrefix("socket,id=\(id),fd=") }.flatMap { Int32($0.split(separator: "=").last!) }
    }

    /// Reads QMP input until it holds `quit`.
    private static func awaitQuit(_ fd: Int32) -> String {
        var received = ""
        var buffer = [UInt8](repeating: 0, count: 512)
        while !received.contains("\"quit\"") {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            received += String(decoding: buffer[..<count], as: UTF8.self)
        }
        return received
    }

    func testItBootsOnceWithTheShareSerialAndControlAndQuitsThroughQMP() throws {
        let recorded = Locked<[String]>([])
        let qmp = Locked("")
        let machine = try EmbeddedMachine(configuration()) { arguments in
            recorded.set(arguments)
            if let serial = Self.descriptor(arguments, "serial") { _ = "boot marker\n".withCString { write(serial, $0, strlen($0)) } }
            guard let control = Self.descriptor(arguments, "qmp") else { return -9 }
            qmp.set(Self.awaitQuit(control))
            return 0
        }
        let exited = expectation(description: "exit")
        let statuses = Locked<[Int32?]>([])
        machine.onExit = { status in statuses.update { $0.append(status) }; exited.fulfill() }
        try machine.boot(workspace: root + "/share,odd")
        XCTAssertThrowsError(try machine.boot(workspace: root + "/share,odd"))
        XCTAssertFalse(machine.exited)
        machine.stop()
        machine.stop()
        wait(for: [exited], timeout: 10)

        let argv = recorded.value
        XCTAssertEqual(Array(argv.prefix(3)), ["qemu-aarch64-softmmu", "-L", root + "/qemu"])
        XCTAssertTrue(argv.contains("local,id=workspace,path=" + root + "/share,,odd,security_model=none,writeout=immediate"))
        XCTAssertTrue(argv.contains { $0.hasPrefix("user,id=net,restrict=on,hostfwd=tcp:127.0.0.1:") && $0.hasSuffix("-:4500") })
        XCTAssertEqual(argv.firstIndex(of: "chardev=qmp,mode=control").map { argv[$0 - 1] }, "-mon")
        XCTAssertTrue(qmp.value.contains("qmp_capabilities"))
        XCTAssertTrue(machine.exited)
        XCTAssertEqual(statuses.value, [0], "one exit, with the engine's status")
        XCTAssertThrowsError(try machine.boot(workspace: root + "/share,odd"), "never restarts in the process")
        let deadline = Date().addingTimeInterval(5)
        var serial = ""
        while !serial.contains("boot marker") && Date() < deadline {
            serial = (try? String(contentsOfFile: root + "/logs/serial-private.log", encoding: .utf8)) ?? ""
            usleep(10_000)
        }
        XCTAssertTrue(serial.contains("boot marker"), "serial output reaches the private log")
    }

    func testAnEngineThatNeverRanIsReportedOnceAndLeavesNoDescriptors() throws {
        let given = Locked<[Int32]>([])
        let machine = try EmbeddedMachine(configuration()) { arguments in
            given.set([Self.descriptor(arguments, "serial"), Self.descriptor(arguments, "qmp")].compactMap { $0 })
            return -1
        }
        let exited = expectation(description: "exit")
        let statuses = Locked<[Int32?]>([])
        machine.onExit = { status in statuses.update { $0.append(status) }; exited.fulfill() }
        try machine.boot(workspace: root + "/share,odd")
        wait(for: [exited], timeout: 10)
        machine.stop()
        XCTAssertTrue(machine.exited)
        XCTAssertEqual(statuses.value, [-1])
        XCTAssertEqual(given.value.count, 2)
        XCTAssertEqual(given.value.map { fcntl($0, F_GETFD) }, [-1, -1], "QEMU's ends are closed for it")
    }

    func testStopBeforeBootStartsNothing() throws {
        var started = false
        let machine = try EmbeddedMachine(configuration()) { _ in started = true; return 0 }
        machine.stop()
        XCTAssertFalse(machine.exited)
        XCTAssertFalse(started)
    }

    func testAMissingLibraryIsAnEngineFailureNotACrash() {
        XCTAssertEqual(EmbeddedMachine.library(at: root + "/absent")(["qemu-aarch64-softmmu"]), -1)
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
    func update(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}
