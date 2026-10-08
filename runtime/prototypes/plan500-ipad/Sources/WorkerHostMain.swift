#if os(macOS)
import Cocoa
import Foundation

@main
struct WorkerHostMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard (6...7).contains(args.count), ["none", "mapped-xattr"].contains(args[4]),
              ["first", "resume", "gate2-missing", "gate3", "gate4", "gate5", "gate5-unavailable",
               "gate5-prepare-failed"].contains(args[5]) else { exit(2) }
        setvbuf(stdout, nil, _IOLBF, 0)  // Line-buffered, so a stuck run still leaves its progress in the log.
        let application = NSApplication.shared; application.setActivationPolicy(.accessory)
        do {
            // #39 gate 4: the model gateway talks to the local fault server, never the network, with a fake key.
            // #39 gate 3 scripts its model turns on the same local server.
            if args[5] == "gate4" || args[5] == "gate3" {
                guard args.count == 7, let target = URL(string: args[6]), target.host == "127.0.0.1" else { exit(2) }
                WorkerCoordinator.modelFaultTarget = target
            }
            let probe = try ResearchProbe(model: args[4], inputs: URL(fileURLWithPath: args[1]),
                projectRoot: URL(fileURLWithPath: args[3])) { print($0) }
            let coordinator = try WorkerCoordinator(probe: probe, injectMissingPrivateSymbol: ["gate2-missing", "gate5-unavailable"].contains(args[5]),
                                                    injectPrepareFailure: args[5] == "gate5-prepare-failed")
            if args[5] == "gate4" || args[5] == "gate3" { coordinator.setModelKey("sk-plan500-fault-injection-only") }
            let host = WorkerWebHost(coordinator: coordinator, webRoot: URL(fileURLWithPath: args[2]), resume: args[5] == "resume",
                                     gate3: args[5] == "gate3", gate5: args[5].hasPrefix("gate5")) { passed in
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
