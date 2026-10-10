import Foundation
import LinuxPlugin
import NativeWorkspace

/// Proves the guest's `/workspace` is this project's live share: the host writes a fresh nonce to the
/// reserved sentinel, and an unleased guest reader must read the same bytes back. The sentinel is
/// removed whatever the outcome.
public struct MountCheck {
    public static let failure = "MOUNT_CHECK_FAILED"
    private let rpc: GuestRPC
    private let workspace: String
    private let project: String
    private let timeoutMs: Int

    public init(rpc: GuestRPC, workspace: String, project: String, timeoutMs: Int = 15_000) {
        self.rpc = rpc; self.workspace = workspace; self.project = project; self.timeoutMs = timeoutMs
    }

    public func verify() throws {
        let name = String(decoding: WorkspaceFiles.mountCheck, as: UTF8.self)
        let sentinel = workspace + "/" + name
        let nonce = UUID().uuidString.lowercased()
        defer { try? FileManager.default.removeItem(atPath: sentinel) }
        guard FileManager.default.createFile(atPath: sentinel, contents: Data(nonce.utf8), attributes: [.posixPermissions: 0o644])
        else { throw LinuxPlugin.LaunchFailure(Self.failure) }
        let request: [String: Any] = ["id": "mount-check-" + nonce, "projectId": project, "timeoutMs": timeoutMs,
                                      "argv": ["/bin/sh", "-c", "cat /workspace/" + name], "cwd": "/workspace"]
        guard let answer = try? rpc.call("/execute", request), answer["code"] as? Int == 0,
              answer["stdout"] as? String == nonce else { throw LinuxPlugin.LaunchFailure(Self.failure) }
    }
}
