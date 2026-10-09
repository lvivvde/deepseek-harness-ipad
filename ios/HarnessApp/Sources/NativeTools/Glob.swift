import Foundation

/// One gitignore-style glob as ripgrep's `ignore` crate compiles it (overrides and ignore files
/// share the rules): `!` whitelists, a leading or inner `/` anchors to the base directory, a
/// trailing `/` matches directories only, and a slash-free glob matches at any depth.
struct IgnoreGlob {
    struct Invalid: Error { let glob: String; let message: String }

    let original: String
    let isWhitelist: Bool
    let isOnlyDirectory: Bool
    let regex: NSRegularExpression

    /// nil for comments and blank lines. Throws for a glob globset would reject.
    init?(line raw: String) throws {
        if raw.hasPrefix("#") { return nil }
        var line = raw.hasSuffix("\\ ") ? Substring(raw) : Substring(raw).trimmingTrailingWhitespace()
        if line.isEmpty { return nil }
        var whitelist = false, absolute = false, onlyDirectory = false
        if line.hasPrefix("\\!") || line.hasPrefix("\\#") {
            line = line.dropFirst()
            absolute = line.first == "/"
        } else {
            if line.hasPrefix("!") { whitelist = true; line = line.dropFirst() }
            if line.hasPrefix("/") { line = line.dropFirst(); absolute = true }
        }
        if line.hasSuffix("/") {
            onlyDirectory = true
            line = line.dropLast()
            if line.hasSuffix("\\") { line = line.dropLast() }
        }
        var actual = String(line)
        if !absolute && !actual.contains("/") && !actual.hasPrefix("**/") { actual = "**/" + actual }
        if actual.hasSuffix("/**") { actual += "/*" }
        original = raw
        isWhitelist = whitelist
        isOnlyDirectory = onlyDirectory
        do {
            regex = try NSRegularExpression(pattern: try GlobTranslator.regex(actual), options: [.dotMatchesLineSeparators])
        } catch let error as GlobTranslator.Invalid {
            throw Invalid(glob: raw, message: error.message)
        }
    }

    func matches(_ path: String) -> Bool {
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, options: [.anchored], range: range).map { $0.range == range } ?? false
    }
}

enum IgnoreMatch: Equatable { case none, ignore, whitelist }

/// The globs of one ignore file (or one override set), relative to `base`. The last matching
/// glob decides, and a directory-only glob never matches a file.
struct IgnoreRules {
    let base: [[UInt8]]
    let globs: [IgnoreGlob]

    /// Overrides are strict (a bad glob fails the search); ignore files skip a bad line, as the
    /// `ignore` crate does.
    init(base: [[UInt8]], lines: [String], strict: Bool) throws {
        self.base = base
        globs = try lines.compactMap { line in
            do { return try IgnoreGlob(line: line) } catch where !strict { return nil }
        }
    }

    var isEmpty: Bool { globs.isEmpty }
    /// As an override set, plain globs are the whitelists; any of them hides unmatched files.
    var hasOverrideWhitelist: Bool { globs.contains { !$0.isWhitelist } }

    func match(_ path: [[UInt8]], isDirectory: Bool) -> IgnoreMatch {
        guard path.starts(with: base) else { return .none }
        return match(text: String(decoding: Array(path.dropFirst(base.count).joined(separator: [0x2F])), as: UTF8.self), isDirectory: isDirectory)
    }

    func match(text candidate: String, isDirectory: Bool) -> IgnoreMatch {
        for glob in globs.reversed() where !glob.isOnlyDirectory || isDirectory {
            if glob.matches(candidate) { return glob.isWhitelist ? .whitelist : .ignore }
        }
        return .none
    }
}

/// globset's translation of a glob to a regex with `literal_separator` and backslash escapes.
enum GlobTranslator {
    struct Invalid: Error { let message: String }

    static func regex(_ glob: String) throws -> String {
        let characters = Array(glob)
        var output = "", index = 0, inAlternation = false
        func literal(_ c: Character) { output += c == "/" ? "/" : NSRegularExpression.escapedPattern(for: String(c)) }
        while index < characters.count {
            let c = characters[index]
            switch c {
            case "\\":
                index += 1
                guard index < characters.count else { throw Invalid(message: "dangling '\\'") }
                literal(characters[index])
            case "?":
                output += "[^/]"
            case "*":
                var stars = 1
                while index + 1 < characters.count && characters[index + 1] == "*" { stars += 1; index += 1 }
                let previousIsSeparator = index - stars < 0 || characters[index - stars] == "/" || (inAlternation && [",", "{"].contains(characters[index - stars]))
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if stars >= 2 && previousIsSeparator && (next == nil || next == "/" || (inAlternation && (next == "," || next == "}"))) {
                    let atStart = index - stars < 0
                    if next == "/" {
                        index += 1
                        if atStart {
                            output += "(?:/?|.*/)"
                        } else {
                            // `a/**/b`: the separator before `**` is already emitted.
                            output.removeLast(1)
                            output += "(?:/|/.*/)"
                        }
                    } else if atStart {
                        output += ".*"
                    } else {
                        output.removeLast(1)
                        output += "/.*"
                    }
                } else {
                    output += "[^/]*"
                }
            case "[":
                guard let end = classEnd(characters, from: index) else { throw Invalid(message: "unclosed character class; missing ']'") }
                var body = Array(characters[(index + 1)..<end]), negated = false
                if let first = body.first, first == "!" || first == "^" { negated = true; body.removeFirst() }
                var classText = negated ? "[^" : "["
                for member in body {
                    classText += member == "\\" || member == "[" || member == "]" || member == "^" || member == "&" || member == "~" ? "\\" + String(member) : String(member)
                }
                output += classText + "]"
                index = end
            case "{":
                guard !inAlternation else { throw Invalid(message: "nested alternate groups are not allowed") }
                inAlternation = true
                output += "(?:"
            case "}" where inAlternation:
                inAlternation = false
                output += ")"
            case "," where inAlternation:
                output += "|"
            default:
                literal(c)
            }
            index += 1
        }
        guard !inAlternation else { throw Invalid(message: "unclosed alternate group; missing '}' (maybe escape '{' with '[{]'?)") }
        return "^" + output + "$"
    }

    /// Index of the `]` closing the class opened at `start`; a `]` right after `[` or `[!` is literal.
    static func classEnd(_ characters: [Character], from start: Int) -> Int? {
        var index = start + 1
        if index < characters.count, characters[index] == "!" || characters[index] == "^" { index += 1 }
        if index < characters.count, characters[index] == "]" { index += 1 }
        while index < characters.count {
            if characters[index] == "]" { return index }
            index += 1
        }
        return nil
    }
}

extension Substring {
    func trimmingTrailingWhitespace() -> Substring {
        var end = endIndex
        while end > startIndex, let scalar = self[index(before: end)].unicodeScalars.first, CharacterSet.whitespaces.contains(scalar) {
            end = index(before: end)
        }
        return self[startIndex..<end]
    }
}
