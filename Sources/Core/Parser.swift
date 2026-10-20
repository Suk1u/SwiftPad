import Foundation

struct ParseError: Error, CustomStringConvertible {
    let message: String
    let line: Int
    var file: String = ""
    var description: String {
        if file.isEmpty { return "line \(line): \(message)" }
        return "\(file):\(line): \(message)"
    }
}

private struct MemberBuckets {
    var properties: [PropertyDecl] = []
    var methods: [String: FuncDecl] = [:]
    var staticMethods: [String: FuncDecl] = [:]
    var computed: [String: FuncDecl] = [:]
    var initializer: FuncDecl? = nil
    var subscriptGet: FuncDecl? = nil
    var subscriptSet: FuncDecl? = nil
    var order: [String] = []
}

final class Parser {
    private let t: [Token]
    private let customOps: Set<String>
    private var p = 0
    private var noTrailing = false

    init(_ tokens: [Token], customOps: Set<String> = []) {
        t = tokens
        self.customOps = customOps
    }

    // MARK: - token helpers

    private var cur: Token { t[min(p, t.count - 1)] }
    private func ahead(_ k: Int) -> Token { t[min(p + k, t.count - 1)] }
    private var prevLine: Int { p > 0 ? t[p - 1].line : 0 }

    private func isKw(_ s: String) -> Bool {
        if case .kw(let k) = cur.tok { return k == s }
        return false
    }
    private func isOp(_ s: String) -> Bool {
        if case .op(let o) = cur.tok { return o == s }
        return false
    }
    private func isPunct(_ s: String) -> Bool {
        if case .punct(let x) = cur.tok { return x == s }
        return false
    }
    private func isIdent(_ s: String) -> Bool {
        if case .ident(let x) = cur.tok { return x == s }
        return false
    }
    private var atEnd: Bool {
        if case .eof = cur.tok { return true }
        return false
    }

    private func err(_ m: String) -> ParseError { ParseError(message: m, line: cur.line) }

    @discardableResult
    private func eatPunct(_ s: String) throws -> Token {
        guard isPunct(s) else { throw err("expected '\(s)' but found \(describe(cur.tok))") }
        let tk = cur; p += 1; return tk
    }
    @discardableResult
    private func eatKw(_ s: String) throws -> Token {
        guard isKw(s) else { throw err("expected '\(s)' but found \(describe(cur.tok))") }
        let tk = cur; p += 1; return tk
    }
    private func matchPunct(_ s: String) -> Bool {
        if isPunct(s) { p += 1; return true }
        return false
    }
    private func matchKw(_ s: String) -> Bool {
        if isKw(s) { p += 1; return true }
        return false
    }
    private func matchOp(_ s: String) -> Bool {
        if isOp(s) { p += 1; return true }
        return false
    }

    private func skipModifiers() {
        let mods: Set<String> = ["private", "public", "internal", "fileprivate", "static",
                                 "final", "override", "mutating", "nonmutating", "lazy",
                                 "weak", "unowned", "open", "convenience", "required",
                                 "indirect", "optional"]
        while case .kw(let k) = cur.tok, mods.contains(k) {
            p += 1
        }
    }

    // MARK: - program

    func parseProgram() throws -> Program {
        var decls: [Decl] = []
        var top: [Stmt] = []

        while !atEnd {
            if matchPunct(";") { continue }
            var attrs: [String] = []
            while case .attr(let a) = cur.tok {
                attrs.append(a)
                p += 1
            }
            if isKw("import") {
                p += 1
                var name = ""
                while case .ident(let id) = cur.tok {
                    name += id
                    p += 1
                    if isPunct(".") { p += 1 } else { break }
                }
                decls.append(.importDecl(name))
                continue
            }
            skipModifiers()

            if isKw("struct") || isKw("class") {
                decls.append(.typeDecl(try parseTypeDecl(attrs: attrs)))
            } else if isKw("enum") {
                decls.append(.enumDecl(try parseEnumDecl()))
            } else if isKw("extension") {
                decls.append(.ext(try parseExtension()))
            } else if isKw("protocol") {
                decls.append(.protocolDecl(try parseProtocolDecl()))
            } else if isKw("typealias") {
                try skipToLineEnd()
            } else if isKw("infix") || isKw("prefix") || isKw("postfix") || isKw("operator") {
                try skipToLineEnd()
            } else if isKw("precedencegroup") {
                try skipBraceBlock()
            } else if isKw("func") {
                decls.append(.funcDecl(try parseFunc()))
            } else if isKw("var") || isKw("let") {
                decls.append(.prop(try parseProperty(attrs: attrs, isStatic: false)))
            } else if isKw("deinit") {
                try skipToLineEnd()
            } else {
                top.append(try parseStatement())
            }
        }
        return Program(decls: decls, topLevel: top)
    }

    private func skipToLineEnd() throws {
        let start = cur.line
        while !atEnd, cur.line == start, !isPunct("}") {
            p += 1
        }
    }

    private func skipBraceBlock() throws {
        while !isPunct("{") && !atEnd { p += 1 }
        try eatPunct("{")
        var depth = 1
        while depth > 0 && !atEnd {
            if isPunct("{") { depth += 1 }
            if isPunct("}") { depth -= 1 }
            p += 1
        }
    }

    // MARK: - types

    private func parseTypeDecl(attrs: [String]) throws -> TypeDecl {
        let isClass = isKw("class")
        p += 1
        guard case .ident(let name) = cur.tok else { throw err("expected a type name") }
        p += 1
        if isOp("<") { skipGenericArgs() }

        var conformances: [String] = []
        if matchPunct(":") {
            while case .ident(let s) = cur.tok {
                conformances.append(s)
                p += 1
                if isOp("<") { skipGenericArgs() }
                if !matchPunct(",") { break }
            }
        }
        while !isPunct("{") && !atEnd { p += 1 }

        var td = TypeDecl(name: name, isClass: isClass)
        td.isMain = attrs.contains("main")
        td.conformances = conformances
        let b = try parseMemberBlock()
        td.properties = b.properties
        td.methods = b.methods
        td.staticMethods = b.staticMethods
        td.computed = b.computed
        td.initializer = b.initializer
        td.subscriptGet = b.subscriptGet
        td.subscriptSet = b.subscriptSet
        td.order = b.order
        return td
    }

    private func parseEnumDecl() throws -> EnumDecl {
        try eatKw("enum")
        guard case .ident(let name) = cur.tok else { throw err("expected an enum name") }
        p += 1
        var e = EnumDecl(name: name)
        if matchPunct(":") {
            while case .ident(let s) = cur.tok {
                e.conformances.append(s)
                if e.rawType == nil { e.rawType = s }
                p += 1
                if !matchPunct(",") { break }
            }
        }
        try eatPunct("{")
        while !isPunct("}") && !atEnd {
            if matchPunct(";") { continue }
            var attrs: [String] = []
            while case .attr(let a) = cur.tok { attrs.append(a); p += 1 }
            let isStatic = isKw("static")
            skipModifiers()
            if isKw("case") {
                p += 1
                while true {
                    guard case .ident(let cname) = cur.tok else {
                        throw err("expected an enum case name")
                    }
                    p += 1
                    var labels: [String?] = []
                    var types: [String] = []
                    if isPunct("(") {
                        p += 1
                        while !isPunct(")") && !atEnd {
                            var label: String? = nil
                            if case .ident(let s) = cur.tok, case .punct(":") = ahead(1).tok {
                                label = s
                                p += 2
                            }
                            let tn = try parseTypeName()
                            labels.append(label)
                            types.append(tn)
                            if !matchPunct(",") { break }
                        }
                        try eatPunct(")")
                    }
                    var raw: Expr? = nil
                    if matchOp("=") { raw = try parseExpr() }
                    e.cases.append(EnumCaseDecl(name: cname,
                                                assocLabels: labels,
                                                assocTypes: types,
                                                rawValue: raw))
                    if !matchPunct(",") { break }
                }
            } else if isKw("func") {
                let f = try parseFunc()
                if isStatic { e.staticMethods[f.name] = f } else { e.methods[f.name] = f }
            } else if isKw("var") || isKw("let") {
                let prop = try parseProperty(attrs: attrs, isStatic: isStatic)
                if let body = prop.computedBody {
                    e.computed[prop.name] = FuncDecl(name: prop.name, params: [],
                                                     returnType: prop.typeName,
                                                     body: body, isStatic: isStatic)
                }
            } else if isKw("init") {
                try skipBraceBlock()
            } else {
                throw err("unexpected \(describe(cur.tok)) inside enum body")
            }
        }
        try eatPunct("}")
        return e
    }

    private func parseProtocolDecl() throws -> ProtocolDecl {
        try eatKw("protocol")
        guard case .ident(let name) = cur.tok else { throw err("expected a protocol name") }
        p += 1
        var inherits: [String] = []
        if matchPunct(":") {
            while case .ident(let s) = cur.tok {
                inherits.append(s)
                p += 1
                if !matchPunct(",") { break }
            }
        }
        while !isPunct("{") && !atEnd { p += 1 }
        try eatPunct("{")

        var reqs: [String] = []
        while !isPunct("}") && !atEnd {
            if matchPunct(";") { continue }
            skipModifiers()
            if isKw("var") || isKw("let") {
                p += 1
                if case .ident(let n) = cur.tok { reqs.append(n); p += 1 }
                try skipProtocolMember()
            } else if isKw("func") {
                p += 1
                switch cur.tok {
                case .ident(let n): reqs.append(n); p += 1
                case .op(let n): reqs.append(n); p += 1
                default: break
                }
                try skipProtocolMember()
            } else if isKw("init") {
                p += 1
                reqs.append("init")
                try skipProtocolMember()
            } else if isKw("subscript") {
                p += 1
                reqs.append("subscript")
                try skipProtocolMember()
            } else {
                throw err("unexpected \(describe(cur.tok)) in protocol body")
            }
        }
        try eatPunct("}")
        return ProtocolDecl(name: name, inherits: inherits, requirements: reqs)
    }

    /// Skips the rest of a protocol requirement: type annotation, `{ get set }`, parameter list.
    private func skipProtocolMember() throws {
        var depth = 0
        while !atEnd {
            if isPunct("{") {
                depth += 1
                p += 1
                continue
            }
            if isPunct("}") {
                if depth == 0 { return }
                depth -= 1
                p += 1
                if depth == 0 { return }
                continue
            }
            if depth == 0,
               isKw("var") || isKw("let") || isKw("func") || isKw("init") || isKw("subscript") {
                return
            }
            p += 1
        }
    }

    private func parseExtension() throws -> ExtensionDecl {
        try eatKw("extension")
        guard case .ident(let name) = cur.tok else { throw err("expected a type name") }
        p += 1
        var conformances: [String] = []
        if matchPunct(":") {
            while case .ident(let s) = cur.tok {
                conformances.append(s)
                p += 1
                if !matchPunct(",") { break }
            }
        }
        while !isPunct("{") && !atEnd { p += 1 }
        let b = try parseMemberBlock()
        return ExtensionDecl(typeName: name,
                             properties: b.properties,
                             methods: b.methods,
                             computed: b.computed,
                             staticMethods: b.staticMethods,
                             subscriptGet: b.subscriptGet,
                             subscriptSet: b.subscriptSet,
                             conformances: conformances)
    }

    private func parseMemberBlock() throws -> MemberBuckets {
        try eatPunct("{")
        var b = MemberBuckets()
        while !isPunct("}") && !atEnd {
            if matchPunct(";") { continue }
            var attrs: [String] = []
            while case .attr(let a) = cur.tok {
                attrs.append(a)
                p += 1
            }
            var isStatic = isKw("static")
            if isKw("class"),
               case .kw(let next) = ahead(1).tok,
               next == "func" || next == "var" || next == "let" {
                isStatic = true
                p += 1
            }
            let isLazy = isKw("lazy")
            skipModifiers()
            if isKw("var") || isKw("let") {
                let prop = try parseProperty(attrs: attrs, isStatic: isStatic, isLazy: isLazy)
                if let body = prop.computedBody {
                    let fd = FuncDecl(name: prop.name, params: [], returnType: prop.typeName,
                                      body: body, isStatic: isStatic)
                    b.computed[prop.name] = fd
                    b.order.append(prop.name)
                } else {
                    b.properties.append(prop)
                    b.order.append(prop.name)
                }
            } else if isKw("func") {
                let f = try parseFunc()
                if isStatic { b.staticMethods[f.name] = f } else { b.methods[f.name] = f }
            } else if isKw("init") {
                p += 1
                if isOp("?") || isOp("!") { p += 1 }
                var params: [Param] = []
                if isPunct("(") { params = try parseParams() }
                let body = try parseBlock()
                b.initializer = FuncDecl(name: "init", params: params, returnType: nil,
                                         body: body, isStatic: false)
            } else if isKw("deinit") {
                p += 1
                try skipBraceBlock()
            } else if isKw("subscript") {
                p += 1
                var params: [Param] = []
                if isPunct("(") { params = try parseParams() }
                var ret: String? = nil
                if matchOp("->") { ret = try parseTypeName() }
                try eatPunct("{")

                if isIdent("get") || isIdent("set") {
                    var getter: [Stmt]? = nil
                    var setter: [Stmt]? = nil
                    while !isPunct("}") && !atEnd {
                        if matchPunct(";") { continue }
                        if isIdent("get") {
                            p += 1
                            getter = try parseBlock()
                        } else if isIdent("set") {
                            p += 1
                            if isPunct("(") {
                                var d = 0
                                repeat {
                                    if isPunct("(") { d += 1 }
                                    if isPunct(")") { d -= 1 }
                                    p += 1
                                } while d > 0 && !atEnd
                            }
                            setter = try parseBlock()
                        } else {
                            throw err("expected 'get' or 'set' in a subscript")
                        }
                    }
                    try eatPunct("}")
                    if let g = getter {
                        b.subscriptGet = FuncDecl(name: "subscript", params: params,
                                                  returnType: ret, body: g, isStatic: isStatic)
                    }
                    if let s = setter {
                        var sp = params
                        sp.append(Param(label: nil, name: "newValue", typeName: ret, defaultValue: nil))
                        b.subscriptSet = FuncDecl(name: "subscript", params: sp,
                                                  returnType: nil, body: s, isStatic: isStatic)
                    }
                } else {
                    var body: [Stmt] = []
                    while !isPunct("}") && !atEnd {
                        if matchPunct(";") { continue }
                        body.append(try parseStatement())
                    }
                    try eatPunct("}")
                    b.subscriptGet = FuncDecl(name: "subscript", params: params,
                                              returnType: ret, body: body, isStatic: isStatic)
                }
            } else if isKw("case") {
                throw err("'case' is only valid inside an enum body")
            } else {
                throw err("unexpected \(describe(cur.tok)) inside a type body")
            }
        }
        try eatPunct("}")
        return b
    }

    // MARK: - properties

    private func parseProperty(attrs: [String], isStatic: Bool, isLazy: Bool = false) throws -> PropertyDecl {
        let isVar = isKw("var")
        p += 1
        guard case .ident(let name) = cur.tok else { throw err("expected a property name") }
        p += 1
        var typeName: String? = nil
        if matchPunct(":") {
            typeName = try parseTypeName()
        }
        var initExpr: Expr? = nil
        var computed: [Stmt]? = nil
        var willSet: [Stmt]? = nil
        var didSet: [Stmt]? = nil

        if matchOp("=") {
            initExpr = try parseExpr()
            if isPunct("{"), isObserverBlock() {
                (willSet, didSet) = try parseObservers()
            }
        } else if isPunct("{") {
            if isObserverBlock() {
                (willSet, didSet) = try parseObservers()
            } else {
                computed = try parseBlock()
            }
        }

        return PropertyDecl(name: name,
                            isVar: isVar,
                            typeName: typeName,
                            wrappers: attrs,
                            initializer: initExpr,
                            computedBody: computed,
                            isStatic: isStatic,
                            willSet: willSet,
                            didSet: didSet,
                            isLazy: isLazy)
    }

    private func isObserverBlock() -> Bool {
        guard isPunct("{") else { return false }
        switch ahead(1).tok {
        case .ident("willSet"), .ident("didSet"): return true
        default: return false
        }
    }

    private func parseObservers() throws -> ([Stmt]?, [Stmt]?) {
        try eatPunct("{")
        var willSet: [Stmt]? = nil
        var didSet: [Stmt]? = nil
        while !isPunct("}") && !atEnd {
            if matchPunct(";") { continue }
            if isIdent("willSet") {
                p += 1
                if isPunct("(") { try skipBalancedParens() }
                willSet = try parseBlock()
            } else if isIdent("didSet") {
                p += 1
                if isPunct("(") { try skipBalancedParens() }
                didSet = try parseBlock()
            } else {
                throw err("expected 'willSet' or 'didSet' in a property observer block")
            }
        }
        try eatPunct("}")
        return (willSet, didSet)
    }

    private func skipBalancedParens() throws {
        var depth = 0
        repeat {
            if isPunct("(") { depth += 1 }
            if isPunct(")") { depth -= 1 }
            p += 1
        } while depth > 0 && !atEnd
    }

    // MARK: - functions

    private func parseFunc() throws -> FuncDecl {
        try eatKw("func")
        let name: String
        switch cur.tok {
        case .ident(let s): name = s
        case .op(let s): name = s
        default: throw err("expected a function name")
        }
        p += 1
        if isOp("<") {
            var depth = 0
            repeat {
                if isOp("<") { depth += 1 }
                if isOp(">") { depth -= 1 }
                p += 1
            } while depth > 0 && !atEnd
        }
        var params: [Param] = []
        if isPunct("(") { params = try parseParams() }
        var isAsync = false
        while isKw("async") || isKw("throws") || isKw("rethrows") || isKw("nonisolated") {
            if isKw("async") { isAsync = true }
            p += 1
        }
        var ret: String? = nil
        if matchOp("->") { ret = try parseTypeName() }
        if isKw("where") {
            while !isPunct("{") && !atEnd { p += 1 }
        }
        let body = try parseBlock()
        return FuncDecl(name: name, params: params, returnType: ret,
                        body: body, isStatic: false, isAsync: isAsync)
    }

    private func parseParams() throws -> [Param] {
        try eatPunct("(")
        var out: [Param] = []
        while !isPunct(")") && !atEnd {
            guard case .ident(let first) = cur.tok else {
                throw err("expected a parameter name")
            }
            p += 1
            var label: String? = first
            var name = first
            if case .ident(let second) = cur.tok {
                label = (first == "_") ? nil : first
                name = second
                p += 1
            } else if first == "_" {
                label = nil
                name = "_"
            }
            if isKw("inout") { p += 1 }
            try eatPunct(":")
            let typeName = try parseTypeName()
            var def: Expr? = nil
            if matchOp("=") { def = try parseExpr() }
            out.append(Param(label: label, name: name, typeName: typeName, defaultValue: def))
            if !matchPunct(",") { break }
        }
        try eatPunct(")")
        return out
    }

    private func parseTypeName() throws -> String {
        var depth = 0
        var parts: [String] = []
        let startLine = cur.line
        while !atEnd {
            if depth == 0 {
                if isPunct("{") || isPunct("}") || isPunct(",") || isPunct(")") || isOp("=") || isOp("->") {
                    break
                }
                if isKw("in") { break }
                if cur.line > startLine { break }
            }
            if isPunct("[") || isPunct("(") || isOp("<") { depth += 1 }
            if isPunct("]") || isPunct(")") || isOp(">") { depth -= 1 }
            parts.append(describe(cur.tok))
            p += 1
        }
        if parts.isEmpty { throw err("expected a type") }
        return parts.joined(separator: " ")
    }

    // MARK: - statements

    private func parseBlock() throws -> [Stmt] {
        try eatPunct("{")
        var out: [Stmt] = []
        while !isPunct("}") && !atEnd {
            if matchPunct(";") { continue }
            out.append(try parseStatement())
        }
        try eatPunct("}")
        return out
    }

    private func parseStatement() throws -> Stmt {
        var attrs: [String] = []
        while case .attr(let a) = cur.tok {
            attrs.append(a)
            p += 1
        }
        skipModifiers()

        if isKw("var") || isKw("let"), case .punct("(") = ahead(1).tok {
            p += 1
            let names = try parseNameTuple()
            try eatPunct("=")
            let value = try parseExpr()
            return .tupleLet(names, value)
        }
        if isKw("var") || isKw("let") {
            return .prop(try parseProperty(attrs: attrs, isStatic: false))
        }
        if isKw("func") {
            return .funcDecl(try parseFunc())
        }
        if isKw("if") {
            return try parseIf()
        }
        if isKw("guard") {
            return try parseGuard()
        }
        if isKw("for") {
            return try parseFor()
        }
        if isKw("while") {
            try eatKw("while")
            let save = noTrailing
            noTrailing = true
            let cond = try parseExpr()
            noTrailing = save
            let body = try parseBlock()
            return .whileStmt(cond, body)
        }
        if isKw("repeat") {
            return try parseRepeat()
        }
        if isKw("switch") {
            return try parseSwitch()
        }
        if isKw("do") {
            return try parseDoCatch()
        }
        if isKw("throw") {
            p += 1
            return .throwStmt(try parseExpr())
        }
        if isKw("defer") {
            p += 1
            return .deferStmt(try parseBlock())
        }
        if isKw("fallthrough") {
            p += 1
            return .fallthroughStmt
        }
        if isKw("return") {
            let tk = cur
            p += 1
            if isPunct("}") || atEnd { return .returnStmt(nil) }
            if cur.line > tk.line { return .returnStmt(nil) }
            return .returnStmt(try parseExpr())
        }
        if isKw("break") { p += 1; return .breakStmt }
        if isKw("continue") { p += 1; return .continueStmt }
        return .expr(try parseExpr())
    }

    private func parseDoCatch() throws -> Stmt {
        try eatKw("do")
        let body = try parseBlock()
        var catches: [CatchClause] = []
        while isKw("catch") {
            p += 1
            var pattern: Pattern? = nil
            var name: String? = nil
            if isKw("let") || isKw("var") {
                p += 1
                guard case .ident(let n) = cur.tok else { throw err("expected a name after 'catch let'") }
                p += 1
                name = n
            } else if !isPunct("{") {
                let pat = try parsePattern()
                if case .binding(let n) = pat {
                    name = n
                } else {
                    pattern = pat
                }
            }
            if isKw("where") {
                while !isPunct("{") && !atEnd { p += 1 }
            }
            let cb = try parseBlock()
            catches.append(CatchClause(pattern: pattern, name: name, body: cb))
        }
        if catches.isEmpty {
            throw err("'do' requires at least one 'catch' block")
        }
        return .doCatch(body, catches)
    }

    private func parseNameTuple() throws -> [String] {
        try eatPunct("(")
        var names: [String] = []
        while !isPunct(")") && !atEnd {
            if case .ident(let s) = cur.tok {
                names.append(s)
                p += 1
            } else {
                throw err("expected a binding name")
            }
            if !matchPunct(",") { break }
        }
        try eatPunct(")")
        return names
    }

    private func parseIf() throws -> Stmt {
        try eatKw("if")
        if isKw("let") {
            p += 1
            guard case .ident(let name) = cur.tok else { throw err("expected a binding name") }
            p += 1
            try eatPunct("=")
            let save = noTrailing
            noTrailing = true
            let value = try parseExpr()
            noTrailing = save
            let thenB = try parseBlock()
            var elseB: [Stmt]? = nil
            if matchKw("else") {
                if isKw("if") { elseB = [try parseIf()] } else { elseB = try parseBlock() }
            }
            return .ifLet(name, value, thenB, elseB)
        }
        let save = noTrailing
        noTrailing = true
        let cond = try parseExpr()
        noTrailing = save
        let thenB = try parseBlock()
        var elseB: [Stmt]? = nil
        if matchKw("else") {
            if isKw("if") { elseB = [try parseIf()] } else { elseB = try parseBlock() }
        }
        return .ifStmt(cond, thenB, elseB)
    }

    private func parseGuard() throws -> Stmt {
        try eatKw("guard")
        if isKw("let") {
            p += 1
            guard case .ident(let name) = cur.tok else { throw err("expected a binding name") }
            p += 1
            try eatPunct("=")
            let save = noTrailing
            noTrailing = true
            let value = try parseExpr()
            noTrailing = save
            try eatKw("else")
            let body = try parseBlock()
            return .guardLet(name, value, body)
        }
        let save = noTrailing
        noTrailing = true
        let cond = try parseExpr()
        noTrailing = save
        try eatKw("else")
        let body = try parseBlock()
        return .guardStmt(cond, body)
    }

    private func parseFor() throws -> Stmt {
        try eatKw("for")
        if isPunct("(") {
            let names = try parseNameTuple()
            try eatKw("in")
            let save = noTrailing
            noTrailing = true
            let seq = try parseExpr()
            noTrailing = save
            let body = try parseBlock()
            return .forInTuple(names, seq, body)
        }
        guard case .ident(let name) = cur.tok else {
            throw err("expected a loop variable")
        }
        p += 1
        try eatKw("in")
        let save = noTrailing
        noTrailing = true
        let seq = try parseExpr()
        noTrailing = save
        let body = try parseBlock()
        return .forIn(name, seq, body)
    }

    private func parseRepeat() throws -> Stmt {
        try eatKw("repeat")
        let body = try parseBlock()
        try eatKw("while")
        let save = noTrailing
        noTrailing = true
        let cond = try parseExpr()
        noTrailing = save
        return .repeatStmt(body, cond)
    }

    private func parseSwitch() throws -> Stmt {
        try eatKw("switch")
        let save = noTrailing
        noTrailing = true
        let subject = try parseExpr()
        noTrailing = save
        try eatPunct("{")
        var cases: [SwitchCase] = []
        while !isPunct("}") && !atEnd {
            if matchPunct(";") { continue }
            var patterns: [Pattern] = []
            var isDefault = false
            if matchKw("default") {
                isDefault = true
            } else {
                try eatKw("case")
                patterns.append(try parsePattern())
                while matchPunct(",") {
                    patterns.append(try parsePattern())
                }
            }
            try eatPunct(":")
            var body: [Stmt] = []
            while !isPunct("}") && !isKw("case") && !isKw("default") && !atEnd {
                if matchPunct(";") { continue }
                body.append(try parseStatement())
            }
            cases.append(SwitchCase(patterns: patterns, body: body, isDefault: isDefault))
        }
        try eatPunct("}")
        return .switchStmt(subject, cases)
    }

    private func parsePattern(_ bindingMode: Bool = false) throws -> Pattern {
        if matchKw("let") || matchKw("var") {
            return try parsePattern(true)
        }
        if case .ident(let s) = cur.tok, s == "_" {
            p += 1
            return .wildcard
        }
        if isPunct("(") {
            p += 1
            var subs: [Pattern] = []
            while !isPunct(")") && !atEnd {
                subs.append(try parsePattern(bindingMode))
                if !matchPunct(",") { break }
            }
            try eatPunct(")")
            return .tuple(subs)
        }
        if isPunct(".") {
            p += 1
            guard case .ident(let n) = cur.tok else { throw err("expected a case name after '.'") }
            p += 1
            var subs: [Pattern] = []
            if isPunct("(") { subs = try parseSubPatterns(bindingMode) }
            return .enumCase(nil, n, subs)
        }
        if case .ident(let s) = cur.tok, case .punct(".") = ahead(1).tok {
            p += 2
            guard case .ident(let n) = cur.tok else { throw err("expected a case name") }
            p += 1
            var subs: [Pattern] = []
            if isPunct("(") { subs = try parseSubPatterns(bindingMode) }
            return .enumCase(s, n, subs)
        }
        if case .ident(let s) = cur.tok {
            p += 1
            return .binding(s)
        }
        let lo = try parseUnary()
        if isOp("...") || isOp("..<") {
            let closed = isOp("...")
            p += 1
            let hi = try parseUnary()
            return .range(lo, hi, closed)
        }
        return .literal(lo)
    }

    private func parseSubPatterns(_ bindingMode: Bool) throws -> [Pattern] {
        try eatPunct("(")
        var subs: [Pattern] = []
        while !isPunct(")") && !atEnd {
            subs.append(try parsePattern(bindingMode))
            if !matchPunct(",") { break }
        }
        try eatPunct(")")
        return subs
    }

    // MARK: - expressions

    func parseExpr(_ minPrec: Int = 0) throws -> Expr {
        var lhs = try parseUnary()

        while true {
            if isKw("as") || isKw("is") {
                p += 1
                if isOp("?") || isOp("!") { p += 1 }
                if case .ident = cur.tok { p += 1 }
                continue
            }
            if minPrec == 0, isOp("?") {
                p += 1
                let a = try parseExpr()
                try eatPunct(":")
                let b = try parseExpr()
                lhs = .ternary(lhs, a, b)
                continue
            }
            guard let (opName, prec, rightAssoc) = binaryOp() else { break }
            if prec < minPrec { break }
            p += 1
            let nextMin = rightAssoc ? prec : prec + 1
            let rhs = try parseExpr(nextMin)
            if opName == "=" || opName == "+=" || opName == "-=" || opName == "*=" || opName == "/=" {
                lhs = .assign(lhs, opName, rhs)
            } else {
                lhs = .binary(opName, lhs, rhs)
            }
        }
        return lhs
    }

    private func binaryOp() -> (String, Int, Bool)? {
        guard case .op(let o) = cur.tok else { return nil }
        switch o {
        case "=", "+=", "-=", "*=", "/=": return (o, 1, true)
        case "??": return (o, 2, true)
        case "||": return (o, 3, false)
        case "&&": return (o, 4, false)
        case "==", "!=", "<", ">", "<=", ">=": return (o, 5, false)
        case "...", "..<": return (o, 6, false)
        case "+", "-": return (o, 7, false)
        case "*", "/", "%": return (o, 8, false)
        default:
            if customOps.contains(o) { return (o, 7, false) }
            return nil
        }
    }

    private func parseUnary() throws -> Expr {
        if isKw("try") {
            p += 1
            if isOp("?") { p += 1; return .tryOptional(try parseUnary()) }
            if isOp("!") { p += 1; return .tryForced(try parseUnary()) }
            return try parseUnary()
        }
        if isKw("await") {
            p += 1
            return try parseUnary()
        }
        if isOp("-") { p += 1; return .unary("-", try parseUnary()) }
        if isOp("!") { p += 1; return .unary("!", try parseUnary()) }
        if isOp("&") { p += 1; return try parseUnary() }
        if isOp("$") {
            p += 1
            let inner = try parsePostfix()
            return .binding(inner)
        }
        if case .op(let o) = cur.tok, customOps.contains(o) {
            p += 1
            return .unary(o, try parseUnary())
        }
        return try parsePostfix()
    }

    private func parsePostfix() throws -> Expr {
        var e = try parsePrimary()
        while true {
            if isPunct(".") {
                p += 1
                let name: String
                switch cur.tok {
                case .ident(let s): name = s
                case .kw(let s): name = s
                case .intLit(let i): name = String(i)
                default: throw err("expected a member name after '.'")
                }
                p += 1
                e = .member(e, name)
                continue
            }
            if isPunct("(") {
                let args = try parseArgs()
                e = .call(e, args)
                continue
            }
            if isPunct("[") {
                p += 1
                var idx: [Expr] = []
                while !isPunct("]") && !atEnd {
                    idx.append(try parseExpr())
                    if !matchPunct(",") { break }
                }
                try eatPunct("]")
                e = .subscriptExpr(e, idx)
                continue
            }
            if isOp("!"), isCalleeLike(e), bangIsPostfix() {
                p += 1
                e = .forceUnwrap(e)
                continue
            }
            if isOp("<"), looksLikeGenericCall() {
                skipGenericArgs()
                continue
            }
            if isPunct("{"), !noTrailing, cur.line == prevLine, isCalleeLike(e) {
                let cl = try parseClosure()
                if case .call(let callee, var args) = e {
                    args.append(Arg(label: nil, value: .closure(cl)))
                    e = .call(callee, args)
                } else {
                    e = .call(e, [Arg(label: nil, value: .closure(cl))])
                }
                continue
            }
            break
        }
        return e
    }

    private func looksLikeGenericCall() -> Bool {
        var j = p
        var depth = 0
        var scanned = 0
        while j < t.count, scanned < 24 {
            switch t[j].tok {
            case .op("<"):
                depth += 1
            case .op(">"):
                depth -= 1
                if depth == 0 {
                    let nxt = t[min(j + 1, t.count - 1)].tok
                    if case .punct("(") = nxt { return true }
                    return false
                }
            case .punct("{"), .punct("}"), .punct(";"), .eof:
                return false
            default:
                break
            }
            j += 1
            scanned += 1
        }
        return false
    }

    private func skipGenericArgs() {
        var depth = 0
        repeat {
            if isOp("<") { depth += 1 }
            if isOp(">") { depth -= 1 }
            p += 1
        } while depth > 0 && !atEnd
    }

    private func bangIsPostfix() -> Bool {
        let next = ahead(1)
        if next.line > cur.line { return true }
        switch next.tok {
        case .punct("."), .punct(")"), .punct(","), .punct("]"), .punct("}"), .punct(":"):
            return true
        case .eof:
            return true
        default:
            return false
        }
    }

    private func isCalleeLike(_ e: Expr) -> Bool {
        switch e {
        case .ident, .member, .call, .implicitMember, .subscriptExpr, .forceUnwrap:
            return true
        default:
            return false
        }
    }

    private func parseArgs() throws -> [Arg] {
        try eatPunct("(")
        var out: [Arg] = []
        while !isPunct(")") && !atEnd {
            var label: String? = nil
            var candidate: String? = nil
            switch cur.tok {
            case .ident(let s): candidate = s
            case .kw(let s): candidate = s
            default: break
            }
            if let c = candidate, case .punct(":") = ahead(1).tok {
                label = c
                p += 2
            }
            let value = try parseExpr()
            out.append(Arg(label: label, value: value))
            if !matchPunct(",") { break }
        }
        try eatPunct(")")
        return out
    }

    private func parseClosure() throws -> ClosureDef {
        try eatPunct("{")
        var params: [Param] = []

        if looksLikeClosureParams() {
            if isPunct("[") {
                var depth = 0
                repeat {
                    if isPunct("[") { depth += 1 }
                    if isPunct("]") { depth -= 1 }
                    p += 1
                } while depth > 0 && !atEnd
            }
            if isPunct("(") {
                params = try parseParams()
            } else {
                var names: [Param] = []
                while case .ident(let s) = cur.tok {
                    names.append(Param(label: nil, name: s, typeName: nil, defaultValue: nil))
                    p += 1
                    if !matchPunct(",") { break }
                }
                params = names
            }
            if matchOp("->") { _ = try parseTypeName() }
            try eatKw("in")
        }

        var body: [Stmt] = []
        while !isPunct("}") && !atEnd {
            if matchPunct(";") { continue }
            body.append(try parseStatement())
        }
        try eatPunct("}")
        return ClosureDef(params: params, body: body)
    }

    private func looksLikeClosureParams() -> Bool {
        var j = p
        var depth = 0
        var scanned = 0
        while j < t.count, scanned < 48 {
            switch t[j].tok {
            case .punct("{"), .punct("}"), .punct(";"):
                return false
            case .punct("("):
                depth += 1
            case .punct(")"):
                depth -= 1
            case .kw("in"):
                return depth == 0
            case .kw(let k):
                if j == p, ["for", "if", "while", "let", "var", "return", "switch", "guard"].contains(k) {
                    return false
                }
            default:
                break
            }
            j += 1
            scanned += 1
        }
        return false
    }

    private func parsePrimary() throws -> Expr {
        switch cur.tok {
        case .intLit(let i):
            p += 1
            return .intLit(i)
        case .doubleLit(let d):
            p += 1
            return .doubleLit(d)
        case .strLit(let s):
            p += 1
            return .stringLit(s)
        case .kw("true"):
            p += 1
            return .boolLit(true)
        case .kw("false"):
            p += 1
            return .boolLit(false)
        case .kw("nil"):
            p += 1
            return .nilLit
        case .kw("self"):
            p += 1
            return .selfExpr
        case .ident(let s):
            p += 1
            if s.hasPrefix("$"), let n = Int(s.dropFirst()) {
                return .dollar(n)
            }
            return .ident(s)
        case .punct("("):
            p += 1
            if isPunct(")") {
                p += 1
                return .tupleLit([])
            }
            let first = try parseExpr()
            if matchPunct(",") {
                var items = [first]
                while !isPunct(")") && !atEnd {
                    items.append(try parseExpr())
                    if !matchPunct(",") { break }
                }
                try eatPunct(")")
                return .tupleLit(items)
            }
            try eatPunct(")")
            return first
        case .punct("["):
            p += 1
            if matchPunct("]") { return .arrayLit([]) }
            let first = try parseExpr()
            if matchPunct(":") {
                var pairs: [(Expr, Expr)] = [(first, try parseExpr())]
                while matchPunct(",") {
                    let k = try parseExpr()
                    try eatPunct(":")
                    pairs.append((k, try parseExpr()))
                }
                try eatPunct("]")
                return .dictLit(pairs)
            }
            var items: [Expr] = [first]
            while matchPunct(",") {
                if isPunct("]") { break }
                items.append(try parseExpr())
            }
            try eatPunct("]")
            return .arrayLit(items)
        case .punct("{"):
            return .closure(try parseClosure())
        case .punct("."):
            p += 1
            guard case .ident(let s) = cur.tok else {
                throw err("expected a member name after '.'")
            }
            p += 1
            return .implicitMember(s)
        default:
            throw err("unexpected \(describe(cur.tok)) in expression")
        }
    }
}
