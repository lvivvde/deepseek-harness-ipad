import Darwin
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
    /// The loopback port forwarded to the guest's preview forwarder (#23), when the VM has one.
    var previewPort: UInt16? { get }
}

public extension GuestMachine {
    var previewPort: UInt16? { nil }
}

/// The guest both platforms boot: TCG, one vCPU, the read-only system disk, the agent forwarded to a
/// loopback port, IPv4 user networking out to the internet (#18: clone, install, push), and the
/// workspace as the 9P share (`security_model=none`). A second loopback port reaches the agent's preview
/// forwarder (guest port 4501), which connects to the dev server the user picked (#23).
enum GuestArguments {
    static func machine(inputs: String, workspace: String, port: UInt16, preview: UInt16, serial: String) -> [String] {
        [
            "-machine", "virt", "-cpu", "cortex-a72", "-smp", "1", "-m", "1024", "-accel", "tcg",
            "-nodefaults", "-display", "none", "-monitor", "none",
            "-chardev", serial, "-serial", "chardev:serial",
            "-kernel", inputs + "/Image", "-initrd", inputs + "/initramfs.gz", "-append", "console=ttyAMA0 rdinit=/init",
            "-drive", "file=" + option(inputs + "/system.raw") + ",if=none,id=system,format=raw,readonly=on",
            "-device", "virtio-blk-pci,drive=system",
            "-netdev", "user,id=net,ipv6=off,hostfwd=tcp:127.0.0.1:\(port)-:4500,hostfwd=tcp:127.0.0.1:\(preview)-:4501", "-device", "virtio-net-pci,netdev=net,romfile=",
            "-fsdev", "local,id=workspace,path=" + option(workspace) + ",security_model=none,writeout=immediate",
            "-device", "virtio-9p-pci,fsdev=workspace,mount_tag=workspace",
        ]
    }

    /// QEMU option values split on commas; a literal comma is doubled.
    static func option(_ value: String) -> String { value.replacingOccurrences(of: ",", with: ",,") }

    /// A free loopback port other than `taken`, for the second forward.
    static func freePort(besides taken: UInt16) throws -> UInt16 {
        for _ in 0..<8 { let port = try freePort(); if port != taken { return port } }
        throw CandidateError("PORT_UNAVAILABLE")
    }

    /// A loopback port free now, for one of the guest's forwards.
    static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CandidateError("PORT_UNAVAILABLE") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0 }
        }
        guard bound else { throw CandidateError("PORT_UNAVAILABLE") }
        return UInt16(bigEndian: address.sin_port)
    }
}
