// Equivalence probe for the macOS suites: runs a native tool over a real directory mounted at
// its own path, so the output can be compared byte for byte with rg, git and the official
// Node tools over the same fixture. Never used by the app.
import Foundation
import NativeTools

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: native-tools-probe rg <workspace> <cwd> [rg arguments...]\n".utf8))
    exit(64)
}
let workspace = URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath().path
switch arguments[0] {
case "rg":
    let search = NativeSearch(workspace: workspace, mount: workspace, busy: { false })
    let output = search.run(Array(arguments.dropFirst(3)), cwd: URL(fileURLWithPath: arguments[2]).resolvingSymlinksInPath().path)
    FileHandle.standardOutput.write(output.stdout)
    FileHandle.standardError.write(output.stderr)
    exit(output.exitCode)
default:
    FileHandle.standardError.write(Data("unknown tool \(arguments[0])\n".utf8))
    exit(64)
}
