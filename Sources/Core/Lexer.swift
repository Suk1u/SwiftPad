import Foundation

// MARK: - Tokens

enum Tok: Equatable {
    case ident(String)
    case kw(String)
    case intLit(Int)
    case doubleLit(Double)
    case strLit(String)      // raw body, escapes + \( ) kept intact
    case op(String)
    case punct(String)
    case attr(String)
    case eof
}

struct Token: Equatable {
    let tok: Tok
    let line: Int
    let col: Int
}

func describe(_ t: Tok) -> String {
    switch t {
    case .ident(let s): return "identifier '\(s)'"
    case .kw(let s): return "'\(s)'"
    case .intLit(let i): return "\(i)"
    case .doubleLit(let d): return "\(d)"
    case .strLit: return "string literal"
    case .op(let s): return "'\(s)'"
    case .punct(let s): return "'\(s)'"
    case .attr(let s): return "'@\(s)'"
    case .eof: return "end of file"
    }
}

struct LexError: Error, CustomStringConvertible {
    let message: String
    let line: Int
    var description: String { "line \(line): \(message)" }
}

let swiftKeywords: Set<String> = [
    "import", "struct", "class", "enum", "protocol", "extension", "func", "init", "deinit",
    "var", "let", "if", "else", "for", "in", "while", "repeat", "return", "break", "continue",
    "true", "false", "nil", "self", "super", "some", "any", "static", "private", "public",
    "internal", "fileprivate", "mutating", "nonmutating", "override", "final", "lazy",
    "switch", "case", "default", "guard", "do", "catch", "throw", "throws", "try", "where",
    "typealias", "inout", "async", "await", "subscript", "operator", "as", "is",
    "defer", "fallthrough", "escaping", "autoclosure",
    "convenience", "required", "indirect", "weak", "unowned", "open",
    "infix", "prefix", "postfix", "nonisolated", "rethrows", "sending", "precedencegroup"
]

// MARK: - Lexer

final class Lexer {
    private let c: [Character]
    private var i = 0
    private var line = 1
    private var col = 1

    private let customOps: Set<String>

    init(_ source: String, customOps: Set<String> = []) {
        c = Array(source)
        self.customOps = customOps
    }

    /// Pre-scan for `infix operator <+>` and `func <+>(...)` so the tokenizer can
    /// recognise operator names that aren't part of the built-in set.
    static func declaredOperators(in source: String) -> Set<String> {
        var out: Set<String> = []
        let patterns = [
            "(?:infix|prefix|postfix)\\s+operator\\s+([^\\s:(]+)",
            "func\\s+([^\\sA-Za-z0-9_(]+)\\s*\\("
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = source as NSString
            re.enumerateMatches(in: source, options: [],
                                range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m = m, m.numberOfRanges > 1 else { return }
                let s = ns.substring(with: m.range(at: 1))
                if !s.isEmpty { out.insert(s) }
            }
        }
        return out
    }

    func tokenize() throws -> [Token] {
        var out: [Token] = []
        while true {
            let tk = try next()
            out.append(tk)
            if case .eof = tk.tok { break }
        }
        return out
    }

    // MARK: primitives

    private func at(_ k: Int) -> Character? {
        let j = i + k
        guard j >= 0, j < c.count else { return nil }
        return c[j]
    }

    private func bump() {
        if c[i] == "\n" {
            line += 1
            col = 1
        } else {
            col += 1
        }
        i += 1
    }

    private func skipTrivia() {
        while i < c.count {
            let ch = c[i]
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                bump()
                continue
            }
            if ch == "/", at(1) == "/" {
                while i < c.count, c[i] != "\n" { bump() }
                continue
            }
            if ch == "/", at(1) == "*" {
                bump(); bump()
                var depth = 1
                while i < c.count, depth > 0 {
                    if c[i] == "/", at(1) == "*" { depth += 1; bump(); bump(); continue }
                    if c[i] == "*", at(1) == "/" { depth -= 1; bump(); bump(); continue }
                    bump()
                }
                continue
            }
            break
        }
    }

    // MARK: scanner

    private func next() throws -> Token {
        skipTrivia()
        if i >= c.count { return Token(tok: .eof, line: line, col: col) }

        let sl = line, sc = col
        let ch = c[i]

        if ch == "@" {
            bump()
            var name = ""
            while let d = at(0), d.isLetter || d.isNumber || d == "_" {
                name.append(d); bump()
            }
            return Token(tok: .attr(name), line: sl, col: sc)
        }

        if ch == "\"" || ch == "#" {
            var hashCount = 0
            while at(0) == "#" {
                hashCount += 1
                bump()
            }
            if at(0) == "\"" {
                return Token(tok: .strLit(try scanString(hashCount: hashCount)), line: sl, col: sc)
            }
            if hashCount > 0 {
                throw LexError(message: "expected a raw string after '#'", line: sl)
            }
        }

        if ch.isNumber {
            return Token(tok: scanNumber(), line: sl, col: sc)
        }

        if ch.isLetter || ch == "_" {
            var name = ""
            while let d = at(0), d.isLetter || d.isNumber || d == "_" {
                name.append(d); bump()
            }
            if swiftKeywords.contains(name) {
                return Token(tok: .kw(name), line: sl, col: sc)
            }
            return Token(tok: .ident(name), line: sl, col: sc)
        }

        if ch == "$" {
            bump()
            var name = "$"
            while let d = at(0), d.isNumber {
                name.append(d); bump()
            }
            if name == "$" {
                return Token(tok: .op("$"), line: sl, col: sc)
            }
            return Token(tok: .ident(name), line: sl, col: sc)
        }

        if "(){}[],:;".contains(ch) {
            bump()
            return Token(tok: .punct(String(ch)), line: sl, col: sc)
        }

        if ch == "." {
            if at(1) == ".", at(2) == "." {
                bump(); bump(); bump()
                return Token(tok: .op("..."), line: sl, col: sc)
            }
            if at(1) == ".", at(2) == "<" {
                bump(); bump(); bump()
                return Token(tok: .op("..<"), line: sl, col: sc)
            }
            bump()
            return Token(tok: .punct("."), line: sl, col: sc)
        }

        // Custom operators declared with `infix operator <+>` — longest match first.
        if !customOps.isEmpty {
            let longest = customOps.map(\.count).max() ?? 0
            let maxLen = min(longest, c.count - i)
            if maxLen >= 1 {
                var len = maxLen
                while len >= 1 {
                    let s = String(c[i..<(i + len)])
                    if customOps.contains(s) {
                        for _ in 0..<len { bump() }
                        return Token(tok: .op(s), line: sl, col: sc)
                    }
                    len -= 1
                }
            }
        }

        let two = String([ch, at(1) ?? " "])
        let twoCharOps: Set<String> = ["==", "!=", "<=", ">=", "&&", "||", "??",
                                       "+=", "-=", "*=", "/=", "%=", "->", ".."]
        if twoCharOps.contains(two) {
            bump(); bump()
            return Token(tok: .op(two), line: sl, col: sc)
        }

        if "+-*/%=<>!&|^~?".contains(ch) {
            bump()
            return Token(tok: .op(String(ch)), line: sl, col: sc)
        }

        throw LexError(message: "unexpected character '\(ch)'", line: sl)
    }

    private func scanNumber() -> Tok {
        if at(0) == "0", at(1) == "x" || at(1) == "X" {
            bump()
            bump()
            var digits = ""
            while let d = at(0), d.isHexDigit || d == "_" {
                if d != "_" { digits.append(d) }
                bump()
            }
            return .intLit(Int(digits, radix: 16) ?? 0)
        }

        var s = ""
        while let d = at(0), d.isNumber || d == "_" {
            if d != "_" { s.append(d) }
            bump()
        }
        if at(0) == ".", let n = at(1), n.isNumber {
            s.append("."); bump()
            while let d = at(0), d.isNumber || d == "_" {
                if d != "_" { s.append(d) }
                bump()
            }
            return .doubleLit(Double(s) ?? 0)
        }
        return .intLit(Int(s) ?? 0)
    }

    private func scanString(hashCount: Int) throws -> String {
        var out = ""
        let triple = at(0) == "\"" && at(1) == "\"" && at(2) == "\""
        let quoteCount = triple ? 3 : 1
        for _ in 0..<quoteCount { bump() }

        while i < c.count {
            let d = c[i]

            if isStringTerminator(triple: triple, hashCount: hashCount) {
                for _ in 0..<(quoteCount + hashCount) { bump() }
                return out
            }

            if d == "\\" {
                if hashCount == 0 {
                    out.append(d); bump()
                    guard i < c.count else { break }
                    let n = c[i]
                    if n == "(" {
                        out.append(n); bump()
                        var depth = 1
                        while i < c.count, depth > 0 {
                            let x = c[i]
                            if x == "(" { depth += 1 }
                            else if x == ")" { depth -= 1 }
                            out.append(x); bump()
                        }
                    } else {
                        out.append(n); bump()
                    }
                    continue
                }

                var hashIndex = 1
                while hashIndex <= hashCount, at(hashIndex) == "#" {
                    hashIndex += 1
                }
                if hashIndex == hashCount + 1, at(hashIndex) == "(" {
                    // Normalize raw interpolation `\#(` to the parser's `\(` form.
                    out.append("\\")
                    bump()
                    for _ in 0..<hashCount { bump() }
                    continue
                }

                out.append(d)
                bump()
                continue
            }

            if !triple, d == "\n" || d == "\r" { break }
            out.append(d); bump()
        }
        throw LexError(message: "unterminated string literal", line: line)
    }

    private func isStringTerminator(triple: Bool, hashCount: Int) -> Bool {
        if triple {
            guard at(0) == "\"", at(1) == "\"", at(2) == "\"" else { return false }
            for offset in 0..<hashCount where at(3 + offset) != "#" {
                return false
            }
            return true
        }
        guard at(0) == "\"" else { return false }
        for offset in 0..<hashCount where at(1 + offset) != "#" {
            return false
        }
        return true
    }
}
