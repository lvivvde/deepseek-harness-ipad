import Foundation

/// macOS preflight of the exact app checks; never claims iPad verification.
@main
struct HostMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, ["none", "mapped-xattr"].contains(arguments[3]) else { exit(2) }
        do {
            let probe = try ResearchProbe(model: arguments[3], scratch: URL(fileURLWithPath: arguments[2]),
                                          inputs: URL(fileURLWithPath: arguments[1])) { print($0) }
            var failed = false
            do { try probe.run(); print("HOST_CHECKS_COMPLETE:NOT_IPAD_VERIFIED") }
            catch { print("HOST_CHECKS_FAILED:SEE_PRIVATE_RECEIPT"); failed = true }
            probe.stopHostVM()
            if failed { exit(1) }
        } catch { print("HOST_PREPARE_FAILED"); exit(1) }
    }
}
