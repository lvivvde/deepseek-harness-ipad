import Foundation

struct PreviewServer: Identifiable, Equatable, Sendable {
    let port: Int
    let hostPort: Int
    var id: Int { port }
    var url: URL { URL(string: "http://127.0.0.1:\(hostPort)/")! }

    static func accepts(port: Int) -> Bool {
        (1024...65535).contains(port) && ![2999, 3001, 3002, 3003, 28080, 28081, 28082, 28083, 28084].contains(port)
    }
}

struct PreviewRequest: Identifiable {
    let id = UUID()
    let url: URL
}
