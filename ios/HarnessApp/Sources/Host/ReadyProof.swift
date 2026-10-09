import LinuxPlugin

/// Checks the guest's `/ready` answer. Linux is ready only when the guest proves every condition;
/// an absent field is a refusal, never an assumption.
public enum ReadyProof {
    public static let protocolVersion = 1

    public static func verify(_ answer: [String: Any], project: String) throws {
        func refuse(_ code: String) -> LinuxPlugin.LaunchFailure { LinuxPlugin.LaunchFailure(code) }
        guard answer["protocol"] as? Int == protocolVersion else { throw refuse("READY_PROTOCOL_REFUSED") }
        guard answer["projectId"] as? String == project else { throw refuse("READY_PROJECT_MISMATCH") }
        // Outside a lease the guest sees the shared workspace only through a read-only 9P view.
        guard answer["mount"] as? String == "9p", answer["workspaceReadOnly"] as? Bool == true else {
            throw refuse("READY_MOUNT_REFUSED")
        }
        // Without cgroup kill a writer cannot be drained, so a lease could never be confirmed released.
        guard answer["cgroupKill"] as? Bool == true else { throw refuse("READY_CGROUP_KILL_MISSING") }
    }
}
