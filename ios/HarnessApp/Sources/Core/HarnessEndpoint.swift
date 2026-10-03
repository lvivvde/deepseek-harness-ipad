import Foundation

enum HarnessEndpoint {
    static func fromSerialLine(_ line: String) -> URL? {
        guard let marker = line.range(of: "dsh web: "),
              let text = line[marker.upperBound...].split(whereSeparator: { $0.isWhitespace }).first,
              var url = URLComponents(string: String(text)),
              url.scheme == "http", url.host == "127.0.0.1", url.port == 3001,
              url.user == nil, url.password == nil,
              let tokens = url.queryItems?.filter({ $0.name == "token" }),
              tokens.count == 1, let token = tokens[0].value, !token.isEmpty else { return nil }
        url.port = 28080
        return url.url
    }

    static func isLocalPage(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && url.port == 28080 && url.user == nil && url.password == nil
    }

    static func isReady(status: Int, body: Data) -> Bool {
        status == 200 && String(decoding: body, as: UTF8.self).contains("__DSH_BOOT__")
    }
}
