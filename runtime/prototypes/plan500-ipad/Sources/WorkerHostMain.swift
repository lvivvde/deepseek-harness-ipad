#if os(macOS)
import Cocoa
import Foundation

@main
struct WorkerHostMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count == 6, ["none", "mapped-xattr"].contains(args[4]), ["first", "resume"].contains(args[5]) else { exit(2) }
        let application = NSApplication.shared; application.setActivationPolicy(.accessory)
        do {
            let probe = try ResearchProbe(model: args[4], inputs: URL(fileURLWithPath: args[1]),
                projectRoot: URL(fileURLWithPath: args[3])) { print($0) }
            let coordinator = try WorkerCoordinator(probe: probe)
            let host = WorkerWebHost(coordinator: coordinator, webRoot: URL(fileURLWithPath: args[2]), resume: args[5] == "resume") { passed in
                probe.stopHostVM(); print(passed ? "WORKER_HOST_PASS" : "WORKER_HOST_FAIL"); exit(passed ? 0 : 1)
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host.view
            try host.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 750) { probe.stopHostVM(); print("WORKER_HOST_TIMEOUT"); exit(2) }
            withExtendedLifetime((host, window)) { application.run() }
        } catch { print("WORKER_HOST_PREPARE_FAILED"); exit(1) }
    }
}
#endif
