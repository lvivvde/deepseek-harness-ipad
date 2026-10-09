import Foundation

/// ripgrep's default regex dialect (Rust `regex`, line-oriented) translated to ICU for
/// `NSRegularExpression` with `.useUnixLineSeparators`. Constructs Rust rejects are rejected
/// here with ripgrep's wording, so a pattern either means the same thing or fails the same
/// way. Declared differences: the `U` and `R` flags are refused, POSIX classes are ASCII as in
/// Rust but their negated `[:^name:]` forms follow ICU, and `~~` class differences are refused.
enum RustRegex {
    struct ParseError: Error, Equatable { let message: String }
    /// ripgrep refuses a pattern that can match a line terminator in line-oriented mode.
    static let newlineMessage = "the literal \"\\n\" is not allowed in a regex"

    static func translate(_ pattern: String) throws -> String {
        var parser = Parser(scalars: Array(pattern.unicodeScalars))
        return try parser.run()
    }

    static let posixClasses: [String: String] = [
        "alnum": "0-9A-Za-z", "alpha": "A-Za-z", "ascii": "\\x{00}-\\x{7F}", "blank": "\\t ",
        "cntrl": "\\x{00}-\\x{1F}\\x{7F}", "digit": "0-9", "graph": "!-~", "lower": "a-z", "print": " -~",
        "punct": "!-/:-@\\[-`{-~", "space": "\\t\\x{0A}\\x{0B}\\f\\r ", "upper": "A-Z", "word": "0-9A-Za-z_",
        "xdigit": "0-9A-Fa-f",
    ]

    struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0
        var output = ""
        /// Output offsets (in UTF-16 units of `output`) where each open group starts.
        var groups: [Int] = []
        /// Where the last repeatable item starts in `output`, nil when nothing can be repeated.
        var atomStart: Int?
        var afterQuantifier = false
        var lazyApplied = false

        init(scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var peek: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }
        func peek(_ offset: Int) -> Unicode.Scalar? { index + offset < scalars.count ? scalars[index + offset] : nil }
        var offset: Int { output.utf16.count }

        mutating func fail(_ message: String) -> ParseError { ParseError(message: message) }

        mutating func atom(_ text: String) {
            atomStart = offset
            output += text
            afterQuantifier = false
        }

        mutating func run() throws -> String {
            while let c = peek {
                index += 1
                switch c {
                case "\\": try escape()
                case "[": let start = offset; output += try characterClass(); atomStart = start; afterQuantifier = false
                case "(": try openGroup()
                case ")":
                    guard let start = groups.popLast() else { throw fail("unopened group") }
                    output += ")"; atomStart = start; afterQuantifier = false
                case "*", "+", "?": try quantifier(String(c))
                case "{": try counted()
                case "|": output += "|"; atomStart = nil; afterQuantifier = false
                case "^", "$", ".": atom(String(c))
                case "\n": throw fail(RustRegex.newlineMessage)
                default: atom(Self.literal(c))
                }
            }
            guard groups.isEmpty else { throw fail("unclosed group") }
            return output
        }

        static func literal(_ c: Unicode.Scalar) -> String {
            c.isASCII && !c.properties.isAlphabetic && !("0"..."9").contains(c) && c.value > 0x20 ? "\\" + String(c) : String(c)
        }

        mutating func quantifier(_ text: String) throws {
            if text == "?" && afterQuantifier && !lazyApplied {
                output += "?"; lazyApplied = true; return
            }
            guard let start = atomStart else { throw fail("repetition operator missing expression") }
            if afterQuantifier {
                // Rust repeats the repetition (`a*+` is `(?:a*)+`); ICU would read it as possessive.
                let prefix = String(output.utf16.prefix(start))!, rest = String(output.utf16.dropFirst(start))!
                output = prefix + "(?:" + rest + ")"
            }
            output += text
            afterQuantifier = true; lazyApplied = false
        }

        mutating func counted() throws {
            var body = ""
            while let c = peek, c != "}" { body.unicodeScalars.append(c); index += 1 }
            guard peek == "}" else { throw fail("repetition quantifier expects a valid decimal") }
            index += 1
            let parts = body.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, !first.isEmpty, first.allSatisfy(\.isASCIIDigit),
                  parts.count == 1 || parts[1].allSatisfy(\.isASCIIDigit) else {
                throw fail("repetition quantifier expects a valid decimal")
            }
            if parts.count == 2, let low = Int(first), let high = Int(parts[1]), high < low {
                throw fail("invalid repetition range: \(low) must be <= \(high)")
            }
            try quantifier("{" + body + "}")
        }

        mutating func openGroup() throws {
            guard peek == "?" else { groups.append(offset); output += "("; afterQuantifier = false; atomStart = nil; return }
            index += 1
            let named = peek == "P" && peek(1) == "<" ? 2 : peek == "<" && peek(1) != "=" && peek(1) != "!" ? 1 : 0
            if named > 0 {
                index += named
                var name = ""
                while let c = peek, c != ">" { name.unicodeScalars.append(c); index += 1 }
                guard peek == ">", !name.isEmpty else { throw fail("invalid capture group name") }
                index += 1
                groups.append(offset); output += "(?<" + name + ">"; afterQuantifier = false; atomStart = nil
                return
            }
            switch peek {
            case "=", "!": throw fail("look-around, including look-ahead and look-behind, is not supported")
            case "<": throw fail("look-around, including look-ahead and look-behind, is not supported")
            default: break
            }
            var flags = ""
            while let c = peek, c != ")" && c != ":" {
                switch c {
                case "i", "m", "s", "x", "-": flags.unicodeScalars.append(c)
                case "u": break
                case "U", "R": throw fail("flag \(c) is not supported by the native search")
                default: throw fail("unrecognized flag")
                }
                index += 1
            }
            guard let end = peek else { throw fail("unclosed group") }
            index += 1
            if flags.hasSuffix("-") { flags.removeLast() }
            if end == ":" {
                groups.append(offset); output += flags.isEmpty ? "(?:" : "(?" + flags + ":"; atomStart = nil
            } else if !flags.isEmpty {
                output += "(?" + flags + ")"
            }
            afterQuantifier = false
        }

        mutating func escape() throws {
            guard let e = peek else { throw fail("incomplete escape sequence") }
            index += 1
            switch e {
            case "1"..."9": throw fail("backreferences are not supported")
            case "0": throw fail("backreferences are not supported")
            case "d", "D", "s", "S", "w", "W", "r", "t", "f": atom("\\" + String(e))
            case "A", "z": atom("\\" + String(e))
            case "b" where peek == "{":
                var name = ""
                index += 1
                while let c = peek, c != "}" { name.unicodeScalars.append(c); index += 1 }
                index += 1
                switch name {
                case "start": atom("\\b(?=\\w)")
                case "end": atom("\\b(?<=\\w)")
                case "start-half": atom("(?<!\\w)")
                case "end-half": atom("(?!\\w)")
                default: throw fail("unrecognized word boundary assertion")
                }
            case "b", "B": atom("\\" + String(e))
            case "<": atom("\\b(?=\\w)")
            case ">": atom("\\b(?<=\\w)")
            case "v": atom("\\x{0B}")
            case "a": atom("\\x{07}")
            case "n": throw fail(RustRegex.newlineMessage)
            case "p", "P": atom(try property(e))
            case "x": atom(try hex())
            default:
                if e.properties.isAlphabetic || ("0"..."9").contains(e) { throw fail("unrecognized escape sequence") }
                atom(Self.literal(e))
            }
        }

        mutating func property(_ e: Unicode.Scalar) throws -> String {
            guard let first = peek else { throw fail("incomplete escape sequence") }
            index += 1
            guard first == "{" else { return "\\" + String(e) + String(first) }
            var body = ""
            while let c = peek, c != "}" { body.unicodeScalars.append(c); index += 1 }
            guard peek == "}" else { throw fail("unclosed Unicode class") }
            index += 1
            return "\\" + String(e) + "{" + body + "}"
        }

        mutating func hex() throws -> String {
            var digits = ""
            if peek == "{" {
                index += 1
                while let c = peek, c != "}" { digits.unicodeScalars.append(c); index += 1 }
                guard peek == "}" else { throw fail("invalid hexadecimal digit") }
                index += 1
            } else {
                for _ in 0..<2 {
                    guard let c = peek else { throw fail("incomplete escape sequence") }
                    digits.unicodeScalars.append(c); index += 1
                }
            }
            guard let value = UInt32(digits, radix: 16), Unicode.Scalar(value) != nil else { throw fail("invalid hexadecimal digit") }
            if value == 0x0A { throw fail(RustRegex.newlineMessage) }
            return "\\x{" + String(value, radix: 16) + "}"
        }

        /// A bracket class from just after `[` through its closing `]`, as an ICU set.
        mutating func characterClass() throws -> String {
            var text = "["
            if peek == "^" { text += "^"; index += 1 }
            var first = true
            while true {
                guard let c = peek else { throw fail("unclosed character class") }
                index += 1
                switch c {
                case "]" where !first: return text + "]"
                case "[" where peek == ":":
                    var name = ""
                    var probe = index + 1
                    while probe < scalars.count, scalars[probe] != ":" && scalars[probe] != "]" { name.unicodeScalars.append(scalars[probe]); probe += 1 }
                    if probe + 1 < scalars.count, scalars[probe] == ":", scalars[probe + 1] == "]" {
                        index = probe + 2
                        if let ascii = RustRegex.posixClasses[name] { text += ascii }
                        else if name.hasPrefix("^"), RustRegex.posixClasses[String(name.dropFirst())] != nil { text += "[:" + name + ":]" }
                        else { throw fail("invalid character class") }
                    } else {
                        text += try characterClass()
                    }
                case "[": text += try characterClass()
                case "\\":
                    guard let e = peek else { throw fail("incomplete escape sequence") }
                    index += 1
                    switch e {
                    case "d", "D", "s", "S", "w", "W", "r", "t", "f": text += "\\" + String(e)
                    case "v": text += "\\x{0B}"
                    case "a": text += "\\x{07}"
                    case "n": throw fail(RustRegex.newlineMessage)
                    case "p", "P": text += try property(e)
                    case "x": text += try hex()
                    default:
                        if e.properties.isAlphabetic || ("0"..."9").contains(e) { throw fail("unrecognized escape sequence") }
                        text += "\\" + String(e)
                    }
                case "~" where peek == "~": throw fail("class symmetric difference is not supported by the native search")
                case "&" where peek == "&": index += 1; text += "&&"
                case "-" where peek == "-": index += 1; text += "--"
                case "-" where first || peek == "]": text += "\\-"
                case "-": text += "-"
                case "\n": throw fail(RustRegex.newlineMessage)
                case "]", "^", "&", "{", "}", "$", ":": text += "\\" + String(c)
                default: text.unicodeScalars.append(c)
                }
                first = false
            }
        }
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
