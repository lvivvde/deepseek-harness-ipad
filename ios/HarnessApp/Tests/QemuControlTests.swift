import Darwin
import Foundation
import XCTest
@testable import HarnessRuntime

/// A QMP peer on a real Unix socketpair, at the executor boundary.
@MainActor
final class QemuControlTests: XCTestCase {
    func testSmallQMPPacketsCompleteWithoutWaitingForAdditionalOutput() async throws {
        let (client, peer) = try connectedPeer()
        defer { client.close(); peer.close() }
        peer.onLine = { line in
            guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = request["id"] as? String else { return }
            try? peer.send("{\"return\":{},\"id\":\"\(id)\"}")
        }
        try peer.send("{\"QMP\":{}}")
        let result = try await client.command("query-status", timeout: 1)
        XCTAssertNotNil(result["return"])
    }

    func testTimedOutCommandCanRetryOnSameChannelAndIgnoreLateReply() async throws {
        let (client, peer) = try connectedPeer()
        defer { client.close(); peer.close() }
        var queries = 0
        var delayedID: String?
        peer.onLine = { line in
            guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = request["id"] as? String else { return }
            if request["execute"] as? String == "qmp_capabilities" {
                try? peer.send("{\"return\":{},\"id\":\"\(id)\"}")
            } else {
                queries += 1
                if queries == 1 { delayedID = id; return }
                // The timed-out reply arrives just before the fresh response.
                try? peer.send("{\"return\":{\"running\":false},\"id\":\"\(delayedID!)\"}")
                try? peer.send("{\"return\":{\"running\":true},\"id\":\"\(id)\"}")
            }
        }
        try peer.send("{\"QMP\":{}}")
        do {
            _ = try await client.command("query-status", timeout: 0.05)
            XCTFail("Unanswered control command must time out")
        } catch { XCTAssertTrue(error is QemuControl.Failure) }
        XCTAssertEqual(queries, 1, "The command must reach QMP before its response timeout is tested")
        let result = try await client.command("query-status", timeout: 1)
        XCTAssertEqual((result["return"] as? [String: Bool])?["running"], true)
    }

    func testClosedControlChannelFinishesPendingProbe() async throws {
        let (client, peer) = try connectedPeer()
        defer { client.close(); peer.close() }
        var queryReceived = false
        peer.onLine = { line in
            guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = request["id"] as? String else { return }
            if request["execute"] as? String == "qmp_capabilities" {
                try? peer.send("{\"return\":{},\"id\":\"\(id)\"}")
            } else { queryReceived = true; peer.close() }
        }
        try peer.send("{\"QMP\":{}}")
        do {
            _ = try await client.command("query-status", timeout: 1)
            XCTFail("EOF cannot report a running VM")
        } catch { XCTAssertTrue(error is QemuControl.Failure) }
        XCTAssertTrue(queryReceived, "Test EOF after negotiation, not a missing greeting")
    }

    private func connectedPeer() throws -> (QemuControl, RuntimeLineChannel) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw POSIXError(.EIO) }
        var enabled: Int32 = 1
        for descriptor in descriptors {
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        }
        let client = QemuControl()
        client.attach(descriptor: descriptors[0])
        return (client, RuntimeLineChannel(descriptor: descriptors[1]))
    }
}
