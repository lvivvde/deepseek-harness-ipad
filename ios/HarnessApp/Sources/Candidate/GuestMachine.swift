import HarnessHost

/// The one Linux VM of this process: QEMU on macOS, the embedded runtime on iPad. It shares exactly
/// one project directory over 9P and starts at most once.
public protocol GuestMachine: AnyObject {
    /// The guest agent behind the VM's forwarded port.
    var rpc: GuestRPC { get }
    /// Starts the VM with `workspace` as its 9P share. Throws when it cannot start, or was started before.
    func boot(workspace: String) throws
    /// True once the VM process has ended.
    var exited: Bool { get }
    /// Ends the VM; idempotent.
    func stop()
    /// Called once when the VM process ends, with its exit status. Set before `boot`.
    var onExit: ((Int32?) -> Void)? { get set }
}
