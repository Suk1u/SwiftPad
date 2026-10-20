import Foundation

struct RuntimeError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    init(message: String) { self.message = message }
    var description: String { message }
}

// MARK: - Scope

final class Env {
    var vars: [String: Value] = [:]
    var parent: Env?
    var selfObj: ObjectInstance?
    var selfValue: Value?
    var args: [Value] = []

    init(parent: Env? = nil) { self.parent = parent }

    func get(_ n: String) -> Value? {
        if let v = vars[n] { return v }
        return parent?.get(n)
    }

    func define(_ n: String, _ v: Value) { vars[n] = v }

    func set(_ n: String, _ v: Value) -> Bool {
        if vars[n] != nil { vars[n] = v; return true }
        return parent?.set(n, v) ?? false
    }

    func selfInstance() -> ObjectInstance? {
        if let s = selfObj { return s }
        return parent?.selfInstance()
    }

    func selfBoundValue() -> Value? {
        if let s = selfValue { return s }
        return parent?.selfBoundValue()
    }

    func closureArgs() -> [Value]? {
        if !args.isEmpty { return args }
        return parent?.closureArgs()
    }
}

// MARK: - Run outcome

struct RunOutcome {
    var view: ViewNode?
    var output: [String] = []
    var mode: String = "none"      // "app" | "script" | "none"
}

struct SourceInput {
    let name: String
    let text: String
}

// MARK: - Interpreter

final class Interpreter {
    private(set) var types: [String: TypeDecl] = [:]
    private(set) var enums: [String: EnumDecl] = [:]
    private(set) var protocols: [String: ProtocolDecl] = [:]
    private(set) var functions: [String: FuncDecl] = [:]
    private(set) var globals: [String: Value] = [:]
    private(set) var output: [String] = []

    private var steps = 0
    private let stepLimit = 6_000_000
    private let store = StateStore.shared
    private var customOps: Set<String> = []
    weak var activeVM: VM?
    var engine: Engine = .tree

    private let mutatingMethods: Set<String> = [
        "append", "insert", "remove", "removeAll", "removeLast", "removeFirst",
        "removeValue", "sort", "reverse", "toggle", "formUnion"
    ]

    private let viewConstructors: Set<String> = [
        "Text", "Image", "VStack", "HStack", "ZStack", "ScrollView", "List",
        "Group", "ForEach", "Button", "Toggle", "TextField", "Slider", "Stepper",
        "Spacer", "Divider", "ProgressView", "Rectangle", "RoundedRectangle",
        "Circle", "Capsule", "Color", "Section", "Form", "Label",
        "NavigationStack", "NavigationView", "LazyVStack", "LazyHStack",
        "DisclosureGroup", "SecureField", "Link", "Grid", "WindowGroup", "Scene"
    ]

    // MARK: - Entry point

    func run(files: [SourceInput], entry: String? = nil) throws -> RunOutcome {
        types.removeAll()
        enums.removeAll()
        protocols.removeAll()
        functions.removeAll()
        globals.removeAll()
        output.removeAll()
        steps = 0

        var programs: [(name: String, program: Program)] = []

        customOps = []
        for file in files {
            customOps.formUnion(Lexer.declaredOperators(in: file.text))
        }

        for file in files {
            do {
                let tokens = try Lexer(file.text, customOps: customOps).tokenize()
                let prog = try Parser(tokens, customOps: customOps).parseProgram()
                programs.append((file.name, prog))
            } catch let e as ParseError {
                var err = e
                err.file = file.name
                throw err
            } catch let e as LexError {
                throw ParseError(message: e.message, line: e.line, file: file.name)
            }
        }

        var pendingExtensions: [ExtensionDecl] = []
        var globalProps: [PropertyDecl] = []

        // pass 1 — types, enums, functions, extensions
        for p in programs {
            for d in p.program.decls {
                switch d {
                case .typeDecl(let td): types[td.name] = td
                case .enumDecl(let ed): enums[ed.name] = ed
                case .protocolDecl(let pd): protocols[pd.name] = pd
                case .funcDecl(let f): functions[f.name] = f
                case .ext(let e): pendingExtensions.append(e)
                case .prop(let pd): globalProps.append(pd)
                case .importDecl: break
                }
            }
        }
        for ext in pendingExtensions { applyExtension(ext) }

        if engine == .vm {
            let vm = VM(runtime: self)
            vm.prepare()
            activeVM = vm
        } else {
            activeVM = nil
        }

        let diagnostics = Resolver.check(types: types, enums: enums, protocols: protocols)
        if !diagnostics.isEmpty {
            let body = diagnostics.map { "  • " + $0.message }.joined(separator: "\n")
            throw RuntimeError(message: "conformance check failed\n" + body)
        }

        // pass 2 — globals, now that every function and type exists
        for pd in globalProps {
            if let initE = pd.initializer {
                globals[pd.name] = try eval(initE, env: Env())
            } else {
                globals[pd.name] = .void
            }
        }

        // Which file runs?
        var entryName = entry
        if entryName == nil {
            if let scriptFile = programs.first(where: { !$0.program.topLevel.isEmpty }) {
                entryName = scriptFile.name
            }
        }
        let entryProgram = programs.first { $0.name == entryName } ?? programs.first

        if let ep = entryProgram, !ep.program.topLevel.isEmpty {
            let env = Env()
            if engine == .vm, let vm = activeVM {
                let c = Compiler()
                let idx = c.compileTopLevel(ep.program.topLevel, collecting: false)
                let base = vm.adopt(c.chunks)
                _ = try vm.run(base + idx, env)
            } else {
                _ = try execBlock(ep.program.topLevel, env: env)
            }
            return RunOutcome(view: nil, output: output, mode: "script")
        }

        guard let rootName = pickRoot() else {
            return RunOutcome(view: nil, output: output, mode: "none")
        }
        let obj = try instantiate(rootName, [], Env())
        let body = try evalBody(obj)
        return RunOutcome(view: body, output: output, mode: "app")
    }

    private func applyExtension(_ e: ExtensionDecl) {
        if var td = types[e.typeName] {
            for (k, v) in e.methods { td.methods[k] = v }
            for (k, v) in e.computed { td.computed[k] = v }
            for (k, v) in e.staticMethods { td.staticMethods[k] = v }
            td.properties.append(contentsOf: e.properties)
            if let g = e.subscriptGet { td.subscriptGet = g }
            if let s = e.subscriptSet { td.subscriptSet = s }
            td.conformances.append(contentsOf: e.conformances)
            types[e.typeName] = td
        } else if var ed = enums[e.typeName] {
            for (k, v) in e.methods { ed.methods[k] = v }
            for (k, v) in e.computed { ed.computed[k] = v }
            for (k, v) in e.staticMethods { ed.staticMethods[k] = v }
            enums[e.typeName] = ed
        }
    }

    private func pickRoot() -> String? {
        if let cv = types["ContentView"], cv.computed["body"] != nil || cv.methods["body"] != nil {
            return "ContentView"
        }
        if let main = types.values.first(where: { $0.isMain && ($0.computed["body"] != nil || $0.methods["body"] != nil) }) {
            return main.name
        }
        for name in types.keys.sorted() {
            if let td = types[name], td.computed["body"] != nil || td.methods["body"] != nil {
                return name
            }
        }
        return nil
    }

    // MARK: - Instantiation

    private func instantiate(_ typeName: String, _ args: [Arg], _ callerEnv: Env) throws -> ObjectInstance {
        guard let td = types[typeName] else {
            throw RuntimeError("unknown type '\(typeName)'")
        }
        let obj = ObjectInstance(typeName, isClass: td.isClass)
        obj.methods = td.methods
        obj.computed = td.computed

        let selfEnv = Env()
        selfEnv.selfObj = obj

        var labeled: [String: Value] = [:]
        var positional: [Value] = []
        for a in args {
            let v = try eval(a.value, env: callerEnv)
            if let l = a.label { labeled[l] = v } else { positional.append(v) }
        }

        var pi = 0
        for prop in td.properties where !isStateWrapper(prop.wrappers) && !prop.isStatic {
            registerObservers(obj, prop)

            if prop.isLazy {
                // value is produced on first read
                continue
            }

            var val: Value? = labeled[prop.name]
            if val == nil, pi < positional.count {
                val = positional[pi]
                pi += 1
            }
            if val == nil, let initE = prop.initializer {
                val = try eval(initE, env: selfEnv)
            }
            if prop.wrappers.contains("Binding"), let b = val, case .binding(let box) = b {
                obj.stateBoxes[prop.name] = box
                continue
            }
            obj.fields[prop.name] = coerce(val ?? .void, prop.typeName).copyForStorage
        }

        for prop in td.properties where isStateWrapper(prop.wrappers) {
            let key = "\(typeName).\(prop.name)"
            let initial: Value
            if let initE = prop.initializer {
                initial = coerce(try eval(initE, env: selfEnv), prop.typeName)
            } else {
                initial = .void
            }
            let box = store.box(key, initial)
            obj.stateBoxes[prop.name] = box
            registerObservers(obj, prop)

            if let did = prop.didSet {
                box.didSetHook = { [weak obj] old, new in
                    guard let obj = obj else { return }
                    let inner = Env()
                    inner.selfObj = obj
                    inner.define("oldValue", old)
                    inner.define("newValue", new)
                    _ = try? self.execBlock(did, env: inner)
                }
            }
        }

        if let initFn = td.initializer {
            let env = Env()
            env.selfObj = obj
            try bindParams(initFn.params, args, callerEnv, into: env)
            _ = try execBlock(initFn.body, env: env)
        }

        return obj
    }

    private func isStateWrapper(_ wrappers: [String]) -> Bool {
        wrappers.contains("State") || wrappers.contains("StateObject") || wrappers.contains("ObservedObject")
    }

    private func registerObservers(_ obj: ObjectInstance, _ prop: PropertyDecl) {
        if prop.willSet != nil || prop.didSet != nil {
            obj.observers[prop.name] = Observers(willSet: prop.willSet, didSet: prop.didSet)
        }
    }

    /// Single write path for object fields, so `willSet` / `didSet` always fire.
    func setField(_ o: ObjectInstance, _ name: String, _ v: Value, _ env: Env) throws {
        let obs = o.observers[name]

        if let will = obs?.willSet {
            let inner = Env(parent: env)
            inner.selfObj = o
            inner.define("newValue", v)
            _ = try execBlock(will, env: inner)
        }

        let old = o.stateBoxes[name]?.value ?? o.fields[name] ?? .void
        if let box = o.stateBoxes[name] {
            box.setSilent(v)
        } else {
            o.fields[name] = v
        }

        if let did = obs?.didSet {
            let inner = Env(parent: env)
            inner.selfObj = o
            inner.define("oldValue", old)
            inner.define("newValue", v)
            _ = try execBlock(did, env: inner)
        }
    }

    /// Honours `Set` type annotations, which otherwise look like array literals.
    private func coerce(_ v: Value, _ typeName: String?) -> Value {
        guard let t = typeName else { return v }
        if t.contains("Set"), case .array(let a) = v {
            var out: [Value] = []
            for x in a where !out.contains(where: { compareValues($0, x) == 0 }) {
                out.append(x)
            }
            return .set(out)
        }
        return v
    }

    private func evalBody(_ obj: ObjectInstance) throws -> ViewNode {
        guard let td = types[obj.typeName] else {
            throw RuntimeError("unknown type '\(obj.typeName)'")
        }
        guard let bodyFn = td.computed["body"] ?? td.methods["body"] else {
            throw RuntimeError("\(obj.typeName) has no `var body: some View { ... }`")
        }
        let env = Env()
        env.selfObj = obj

        if engine == .vm, let vm = activeVM {
            let c = Compiler()
            let idx = c.compileFunction(bodyFn, name: "\(obj.typeName).body")
            let base = vm.adopt(c.chunks)
            let values = try vm.runCollecting(base + idx, env)
            var views: [ViewNode] = []
            for v in values {
                if case .view(let n) = v { views += n.flattened }
            }
            if views.isEmpty { return .empty }
            if views.count == 1 { return views[0] }
            return ViewNode(base: .stack(.vertical, "center", nil, views))
        }

        let views = try collectViews(bodyFn.body, env: env)
        if views.isEmpty { return .empty }
        if views.count == 1 { return views[0] }
        return ViewNode(base: .stack(.vertical, "center", nil, views))
    }

    // MARK: - View collection (ViewBuilder semantics)

    func collectViews(_ stmts: [Stmt], env: Env) throws -> [ViewNode] {
        var out: [ViewNode] = []
        for s in stmts {
            switch s {
            case .expr(let e):
                appendView(try eval(e, env: env), to: &out)

            case .ifStmt(let c, let a, let b):
                if try eval(c, env: env).asBool() {
                    out += try collectViews(a, env: env)
                } else if let b = b {
                    out += try collectViews(b, env: env)
                }

            case .ifLet(let n, let e, let a, let b):
                let v = try eval(e, env: env)
                if v.isNil {
                    if let b = b { out += try collectViews(b, env: env) }
                } else {
                    let inner = Env(parent: env)
                    inner.define(n, v)
                    out += try collectViews(a, env: inner)
                }

            case .guardStmt, .guardLet:
                let f = try exec(s, env: env)
                if case .ret(let v) = f, let v = v { appendView(v, to: &out) }

            case .forIn(let n, let seq, let body):
                for item in try iterate(try eval(seq, env: env)) {
                    let inner = Env(parent: env)
                    inner.define(n, item)
                    out += try collectViews(body, env: inner)
                }

            case .forInTuple(let names, let seq, let body):
                for item in try iterate(try eval(seq, env: env)) {
                    guard case .tuple(let vals) = item, vals.count == names.count else { continue }
                    let inner = Env(parent: env)
                    for (i, n) in names.enumerated() { inner.define(n, vals[i]) }
                    out += try collectViews(body, env: inner)
                }

            case .switchStmt(let subject, let cases):
                let v = try eval(subject, env: env)
                for c in cases {
                    if c.isDefault {
                        out += try collectViews(c.body, env: env)
                        break
                    }
                    var matched = false
                    for p in c.patterns {
                        let binds = Env(parent: env)
                        if match(p, v, binds) {
                            out += try collectViews(c.body, env: binds)
                            matched = true
                            break
                        }
                    }
                    if matched { break }
                }

            case .prop(let p):
                if let initE = p.initializer {
                    env.define(p.name, try eval(initE, env: env))
                }

            case .tupleLet(let names, let e):
                let v = try eval(e, env: env)
                if case .tuple(let vals) = v, vals.count == names.count {
                    for (i, n) in names.enumerated() { env.define(n, vals[i]) }
                }

            case .returnStmt(let e):
                if let e = e { appendView(try eval(e, env: env), to: &out) }
                return out

            default:
                _ = try exec(s, env: env)
            }
        }
        return out
    }

    private func appendView(_ v: Value, to out: inout [ViewNode]) {
        switch v {
        case .view(let node):
            out += node.flattened
        case .array(let items):
            for i in items { appendView(i, to: &out) }
        default:
            break
        }
    }

    // MARK: - Statements

    func execBlock(_ stmts: [Stmt], env: Env) throws -> Flow {
        var deferred: [[Stmt]] = []
        defer {
            for block in deferred.reversed() {
                _ = try? execBlock(block, env: env)
            }
        }
        for s in stmts {
            if case .deferStmt(let body) = s {
                deferred.append(body)
                continue
            }
            let f = try exec(s, env: env)
            switch f {
            case .normal: continue
            default: return f
            }
        }
        return .normal(nil)
    }

    private func tick() throws {
        steps += 1
        if steps > stepLimit {
            throw RuntimeError("execution limit reached — check for an infinite loop")
        }
    }

    func exec(_ s: Stmt, env: Env) throws -> Flow {
        try tick()
        switch s {
        case .expr(let e):
            return .normal(try eval(e, env: env))

        case .prop(let p):
            if let initE = p.initializer {
                let v = coerce(try eval(initE, env: env), p.typeName)
                env.define(p.name, v)
            } else {
                env.define(p.name, .void)
            }
            return .normal(nil)

        case .funcDecl(let f):
            env.define(f.name, .function(f, env))
            return .normal(nil)

        case .ifStmt(let c, let a, let b):
            if try eval(c, env: env).asBool() {
                return try execBlock(a, env: env)
            } else if let b = b {
                return try execBlock(b, env: env)
            }
            return .normal(nil)

        case .ifLet(let n, let e, let a, let b):
            let v = try eval(e, env: env)
            if v.isNil {
                if let b = b { return try execBlock(b, env: env) }
                return .normal(nil)
            }
            let inner = Env(parent: env)
            inner.define(n, v)
            return try execBlock(a, env: inner)

        case .guardStmt(let c, let elseBody):
            if try eval(c, env: env).asBool() { return .normal(nil) }
            let f = try execBlock(elseBody, env: env)
            switch f {
            case .ret, .breakLoop, .continueLoop: return f
            default:
                throw RuntimeError("guard body must exit the scope (return / break / continue)")
            }

        case .guardLet(let n, let e, let elseBody):
            let v = try eval(e, env: env)
            if !v.isNil {
                env.define(n, v)
                return .normal(nil)
            }
            let f = try execBlock(elseBody, env: env)
            switch f {
            case .ret, .breakLoop, .continueLoop: return f
            default:
                throw RuntimeError("guard body must exit the scope (return / break / continue)")
            }

        case .forIn(let n, let seq, let body):
            for item in try iterate(try eval(seq, env: env)) {
                let inner = Env(parent: env)
                inner.define(n, item)
                let f = try execBlock(body, env: inner)
                switch f {
                case .breakLoop: return .normal(nil)
                case .continueLoop: continue
                case .ret: return f
                case .fallthroughFlow: return f
                default: continue
                }
            }
            return .normal(nil)

        case .forInTuple(let names, let seq, let body):
            for item in try iterate(try eval(seq, env: env)) {
                guard case .tuple(let vals) = item, vals.count == names.count else { continue }
                let inner = Env(parent: env)
                for (i, n) in names.enumerated() { inner.define(n, vals[i]) }
                let f = try execBlock(body, env: inner)
                switch f {
                case .breakLoop: return .normal(nil)
                case .continueLoop: continue
                case .ret: return f
                case .fallthroughFlow: return f
                default: continue
                }
            }
            return .normal(nil)

        case .whileStmt(let c, let body):
            while try eval(c, env: env).asBool() {
                try tick()
                let f = try execBlock(body, env: env)
                switch f {
                case .breakLoop: return .normal(nil)
                case .continueLoop: continue
                case .ret: return f
                case .fallthroughFlow: return f
                default: continue
                }
            }
            return .normal(nil)

        case .repeatStmt(let body, let cond):
            while true {
                try tick()
                let f = try execBlock(body, env: env)
                switch f {
                case .breakLoop: return .normal(nil)
                case .ret: return f
                case .continueLoop: break
                default: break
                }
                if try !eval(cond, env: env).asBool() { break }
            }
            return .normal(nil)

        case .switchStmt(let subject, let cases):
            let v = try eval(subject, env: env)
            var index = -1
            for (i, c) in cases.enumerated() {
                if c.isDefault {
                    index = i
                    break
                }
                for p in c.patterns {
                    let binds = Env(parent: env)
                    if match(p, v, binds) {
                        let f = try execBlock(c.body, env: binds)
                        if case .fallthroughFlow = f {
                            index = i
                            break
                        }
                        return f
                    }
                }
                if index >= 0 { break }
            }
            guard index >= 0, index < cases.count - 1 else {
                return .normal(nil)
            }
            var i = index + 1
            while i < cases.count {
                let f = try execBlock(cases[i].body, env: Env(parent: env))
                if case .fallthroughFlow = f {
                    i += 1
                    continue
                }
                return f
            }
            return .normal(nil)

        case .doCatch(let body, let catches):
            do {
                return try execBlock(body, env: env)
            } catch let thrown as ThrownError {
                for c in catches {
                    let inner = Env(parent: env)
                    if let p = c.pattern {
                        if !match(p, thrown.value, inner) { continue }
                    }
                    if let n = c.name {
                        inner.define(n, thrown.value)
                    } else if c.pattern == nil {
                        inner.define("error", thrown.value)
                    }
                    return try execBlock(c.body, env: inner)
                }
                throw thrown
            }

        case .throwStmt(let e):
            throw ThrownError(value: try eval(e, env: env))

        case .deferStmt:
            return .normal(nil)

        case .fallthroughStmt:
            return .fallthroughFlow

        case .returnStmt(let e):
            if let e = e { return .ret(try eval(e, env: env)) }
            return .ret(nil)

        case .breakStmt:
            return .breakLoop

        case .continueStmt:
            return .continueLoop

        case .tupleLet(let names, let e):
            let v = try eval(e, env: env)
            guard case .tuple(let vals) = v, vals.count == names.count else {
                throw RuntimeError("cannot destructure that value into \(names.count) names")
            }
            for (i, n) in names.enumerated() { env.define(n, vals[i]) }
            return .normal(nil)
        }
    }

    // MARK: - Pattern matching

    func match(_ p: Pattern, _ v: Value, _ binds: Env) -> Bool {
        switch p {
        case .wildcard:
            return true

        case .binding(let n):
            binds.define(n, v)
            return true

        case .literal(let e):
            guard let lv = try? eval(e, env: binds) else { return false }
            return compareValues(lv, v) == 0

        case .range(let a, let b, let closed):
            guard let lo = try? eval(a, env: binds), let hi = try? eval(b, env: binds) else { return false }
            let x = v.asDouble()
            return closed ? (x >= lo.asDouble() && x <= hi.asDouble())
                          : (x >= lo.asDouble() && x < hi.asDouble())

        case .tuple(let subs):
            guard case .tuple(let vals) = v, vals.count == subs.count else { return false }
            for (i, s) in subs.enumerated() where !match(s, vals[i], binds) { return false }
            return true

        case .enumCase(let typeName, let caseName, let subs):
            guard case .enumValue(let ev) = v else {
                if case .implicit(let n) = v { return n == caseName }
                return false
            }
            if let tn = typeName, tn != ev.typeName { return false }
            if ev.caseName != caseName { return false }
            if subs.count != ev.assoc.count { return false }
            for (i, s) in subs.enumerated() where !match(s, ev.assoc[i], binds) { return false }
            return true
        }
    }

    // MARK: - Expressions

    func eval(_ e: Expr, env: Env) throws -> Value {
        try tick()
        switch e {
        case .intLit(let i): return .int(i)
        case .doubleLit(let d): return .double(d)
        case .boolLit(let b): return .bool(b)
        case .nilLit: return .nilValue
        case .stringLit(let s): return .string(try interpolate(s, env: env))

        case .selfExpr:
            if let sv = env.selfBoundValue() { return sv }
            if let o = env.selfInstance() { return .object(o) }
            throw RuntimeError("'self' used outside of a type")

        case .ident(let n):
            if let v = try lookupVar(n, env) { return v }
            if types[n] != nil { return .namespace(n) }
            if enums[n] != nil { return .namespace(n) }
            if isNamespace(n) { return .namespace(n) }
            throw RuntimeError("unknown identifier '\(n)'")

        case .implicitMember(let n):
            return .implicit(n)

        case .dollar(let i):
            if let a = env.closureArgs(), i < a.count { return a[i] }
            throw RuntimeError("$\(i) used outside of a closure")

        case .binding(let inner):
            if case .ident(let n) = inner {
                if let o = env.selfInstance(), let box = o.stateBoxes[n] {
                    return .binding(box)
                }
                if let v = try lookupVar(n, env), case .binding(let b) = v {
                    return .binding(b)
                }
            }
            throw RuntimeError("cannot form a binding from that expression — use $someState")

        case .member(let b, let n):
            return try evalMember(b, n, env)

        case .subscriptExpr(let b, let idx):
            let base = try eval(b, env: env)
            let keys = try idx.map { try eval($0, env: env) }
            return try subscriptValue(base, keys)

        case .call(let callee, let args):
            return try evalCall(callee, args, env)

        case .closure(let cd):
            return .closure(cd, env)

        case .arrayLit(let items):
            return .array(try items.map { try eval($0, env: env) })

        case .dictLit(let pairs):
            var d: [String: Value] = [:]
            for (k, v) in pairs {
                d[try eval(k, env: env).str()] = try eval(v, env: env)
            }
            return .dict(d)

        case .tupleLit(let items):
            return .tuple(try items.map { try eval($0, env: env) })

        case .unary(let op, let x):
            let v = try eval(x, env: env)
            if op == "-" {
                switch v {
                case .int(let i): return .int(-i)
                case .double(let d): return .double(-d)
                default: throw RuntimeError("unary '-' needs a number")
                }
            }
            if op == "!" {
                return .bool(!v.asBool())
            }
            if customOps.contains(op), let f = functions[op] {
                let inner = Env()
                if let p0 = f.params.first { inner.define(p0.name, v) }
                let flow = try execBlock(f.body, env: inner)
                if case .ret(let r) = flow, let r = r { return r }
                return .void
            }
            return .bool(!v.asBool())

        case .binary(let op, let a, let b):
            return try evalBinary(op, a, b, env)

        case .ternary(let c, let a, let b):
            if try eval(c, env: env).asBool() {
                return try eval(a, env: env)
            }
            return try eval(b, env: env)

        case .assign(let target, let op, let rhs):
            return try evalAssign(target, op, rhs, env)

        case .forceUnwrap(let x):
            let v = try eval(x, env: env)
            if v.isNil { throw RuntimeError("unexpectedly found nil while unwrapping") }
            return v

        case .tryOptional(let x):
            do {
                return try eval(x, env: env)
            } catch is ThrownError {
                return .nilValue
            }

        case .tryForced(let x):
            do {
                return try eval(x, env: env)
            } catch let t as ThrownError {
                throw RuntimeError("try! failed: \(t.value.str())")
            }

        case .literal(let v):
            return v
        }
    }

    private func isNamespace(_ n: String) -> Bool {
        ["Color", "Font", "Edge", "Alignment", "TextAlignment", "Axis",
         "EdgeInsets", "UnitPoint", "Weight", "FontWeight", "Angle", "KeyboardType",
         "Task", "MainActor"].contains(n)
    }

    // MARK: - Variables

    func lookupVar(_ n: String, _ env: Env) throws -> Value? {
        if let v = env.get(n) { return v }
        if let o = env.selfInstance() {
            if let box = o.stateBoxes[n] { return box.value }
            if let v = o.fields[n] { return v }
            if let v = try evaluateLazy(o, n) { return v }
        }
        return globals[n]
    }

    /// `lazy var` — evaluated the first time it is read, then memoised in `fields`.
    private func evaluateLazy(_ o: ObjectInstance, _ name: String) throws -> Value? {
        guard let prop = types[o.typeName]?.properties.first(where: { $0.name == name && $0.isLazy }),
              let initE = prop.initializer else { return nil }
        let inner = Env()
        inner.selfObj = o
        let v = coerce(try eval(initE, env: inner), prop.typeName)
        o.fields[name] = v.copyForStorage
        return v
    }

    func assignVar(_ n: String, _ v: Value, _ env: Env) throws {
        let stored = v.copyForStorage
        if env.set(n, stored) { return }
        if let o = env.selfInstance() {
            if o.stateBoxes[n] != nil || o.fields[n] != nil || o.observers[n] != nil {
                try setField(o, n, stored, env)
                return
            }
            if try evaluateLazy(o, n) != nil {
                try setField(o, n, stored, env)
                return
            }
        }
        if globals[n] != nil { globals[n] = stored; return }
        throw RuntimeError("cannot assign to '\(n)' — it is not declared")
    }

    private func evalAssign(_ target: Expr, _ op: String, _ rhs: Expr, _ env: Env) throws -> Value {
        let newRaw = try eval(rhs, env: env)
        let current = try? eval(target, env: env)

        var final = newRaw
        if op != "=" {
            let base = current ?? .int(0)
            switch op {
            case "+=": final = try arith("+", base, newRaw)
            case "-=": final = try arith("-", base, newRaw)
            case "*=": final = try arith("*", base, newRaw)
            case "/=": final = try arith("/", base, newRaw)
            default: break
            }
        }

        try writeBack(target, final, env)
        return .void
    }

    private func writeBack(_ target: Expr, _ v: Value, _ env: Env) throws {
        switch target {
        case .ident(let n):
            try assignVar(n, v, env)

        case .member(let b, let n):
            if case .object(let o) = try eval(b, env: env) {
                try setField(o, n, v.copyForStorage, env)
                return
            }
            throw RuntimeError("cannot assign to member '\(n)'")

        case .subscriptExpr(let b, let idx):
            guard idx.count == 1 else { throw RuntimeError("bad subscript assignment") }
            let base = try eval(b, env: env)
            let key = try eval(idx[0], env: env)
            if case .array(var arr) = base {
                let i = key.asInt()
                guard i >= 0, i < arr.count else { throw RuntimeError("index \(i) out of range") }
                arr[i] = v.copyForStorage
                try writeBack(b, .array(arr), env)
                return
            }
            if case .dict(var d) = base {
                d[key.str()] = v.copyForStorage
                try writeBack(b, .dict(d), env)
                return
            }
            if case .object(let o) = base,
               let f = types[o.typeName]?.subscriptSet {
                let inner = Env()
                inner.selfObj = o
                for (i, p) in f.params.enumerated() {
                    if i < idx.count {
                        inner.define(p.name, try eval(idx[i], env: env))
                    } else {
                        inner.define(p.name, v.copyForStorage)
                    }
                }
                _ = try execBlock(f.body, env: inner)
                return
            }
            throw RuntimeError("cannot subscript-assign this value")

        default:
            throw RuntimeError("expression is not assignable")
        }
    }

    // MARK: - Member access

    private func evalMember(_ baseExpr: Expr, _ name: String, _ env: Env) throws -> Value {
        let base = try eval(baseExpr, env: env)
        return try memberValue(base, name, env)
    }

    func memberValue(_ base: Value, _ name: String, _ env: Env) throws -> Value {
        switch base {
        case .object(let o):
            if let box = o.stateBoxes[name] { return box.value }
            if let v = o.fields[name] { return v }
            if let v = try evaluateLazy(o, name) { return v }
            if let f = o.computed[name] {
                let inner = Env()
                inner.selfObj = o
                let flow = try execBlock(f.body, env: inner)
                if case .ret(let v) = flow, let v = v { return v }
                return .void
            }
            throw RuntimeError("'\(o.typeName)' has no member '\(name)'")

        case .namespace(let ns):
            if let ed = enums[ns], let c = ed.cases.first(where: { $0.name == name }) {
                return try makeEnumValue(ed, c, [], env)
            }
            if let td = types[ns] {
                if let f = td.staticMethods[name] {
                    return try invoke(f, [], env, nil)
                }
                if let prop = td.properties.first(where: { $0.name == name && $0.isStatic }) {
                    if let initE = prop.initializer { return try eval(initE, env: Env()) }
                    return .void
                }
            }
            if ns == "Color" { return .color(name) }
            if ns == "Font" { return .fontSpec(name) }
            return .implicit(name)

        case .enumValue(let ev):
            switch name {
            case "rawValue": return ev.raw ?? .string(ev.caseName)
            default:
                if let ed = enums[ev.typeName], let f = ed.computed[name] {
                    let inner = Env()
                    inner.selfValue = .enumValue(ev)
                    let flow = try execBlock(f.body, env: inner)
                    if case .ret(let v) = flow, let v = v { return v }
                    return .void
                }
                throw RuntimeError("'\(ev.typeName)' has no member '\(name)'")
            }

        case .array(let a):
            switch name {
            case "count": return .int(a.count)
            case "isEmpty": return .bool(a.isEmpty)
            case "first": return a.first ?? .nilValue
            case "last": return a.last ?? .nilValue
            default: throw RuntimeError("Array has no member '\(name)'")
            }

        case .string(let s):
            switch name {
            case "count": return .int(s.count)
            case "isEmpty": return .bool(s.isEmpty)
            case "first": return s.first.map { .string(String($0)) } ?? .nilValue
            case "last": return s.last.map { .string(String($0)) } ?? .nilValue
            default: throw RuntimeError("String has no member '\(name)'")
            }

        case .dict(let d):
            switch name {
            case "count": return .int(d.count)
            case "isEmpty": return .bool(d.isEmpty)
            case "keys": return .array(d.keys.sorted().map { .string($0) })
            case "values": return .array(d.keys.sorted().map { d[$0]! })
            default: throw RuntimeError("Dictionary has no member '\(name)'")
            }

        case .set(let s):
            switch name {
            case "count": return .int(s.count)
            case "isEmpty": return .bool(s.isEmpty)
            case "first": return s.first ?? .nilValue
            default: throw RuntimeError("Set has no member '\(name)'")
            }

        case .tuple(let vals):
            if let i = Int(name), i >= 0, i < vals.count { return vals[i] }
            throw RuntimeError("tuple has no element '\(name)'")

        case .int, .double, .bool:
            if name == "description" { return .string(base.str()) }
            if name == "isNil" { return .bool(false) }
            throw RuntimeError("\(base.typeLabel) has no member '\(name)'")

        case .nilValue:
            if name == "description" { return .string("nil") }
            throw RuntimeError("cannot access '\(name)' on nil")

        default:
            throw RuntimeError("\(base.typeLabel) has no member '\(name)'")
        }
    }

    func subscriptValue(_ base: Value, _ keys: [Value]) throws -> Value {
        guard let k = keys.first else { throw RuntimeError("empty subscript") }
        switch base {
        case .array(let a):
            let i = k.asInt()
            guard i >= 0, i < a.count else {
                throw RuntimeError("index \(i) out of range (count \(a.count))")
            }
            return a[i]
        case .dict(let d):
            return d[k.str()] ?? .nilValue
        case .string(let s):
            let i = k.asInt()
            let chars = Array(s)
            guard i >= 0, i < chars.count else { throw RuntimeError("index out of range") }
            return .string(String(chars[i]))
        case .object(let o):
            if let f = types[o.typeName]?.subscriptGet {
                let inner = Env()
                inner.selfObj = o
                for (i, p) in f.params.enumerated() {
                    inner.define(p.name, i < keys.count ? keys[i] : .void)
                }
                let flow = try execBlock(f.body, env: inner)
                if case .ret(let v) = flow, let v = v { return v }
                return .void
            }
            throw RuntimeError("'\(o.typeName)' has no subscript")
        default:
            throw RuntimeError("\(base.typeLabel) is not subscriptable")
        }
    }

    // MARK: - Enum construction

    private func makeEnumValue(_ ed: EnumDecl, _ c: EnumCaseDecl, _ args: [Value], _ env: Env) throws -> Value {
        var raw: Value? = nil
        if let rawExpr = c.rawValue {
            raw = try eval(rawExpr, env: env)
        }
        let ev = EnumValue(typeName: ed.name, caseName: c.name, assoc: args, raw: raw)
        return .enumValue(ev)
    }

    // MARK: - Calls

    private func evalCall(_ callee: Expr, _ args: [Arg], _ env: Env) throws -> Value {
        switch callee {
        case .ident(let name):
            return try callNamed(name, args, env)

        case .member(let baseExpr, let name):
            if mutatingMethods.contains(name) {
                if let r = try callMutating(baseExpr, name, args, env) { return r }
            }
            let base = try eval(baseExpr, env: env)
            return try callMember(base, name, args, env)

        default:
            let f = try eval(callee, env: env)
            return try callValue(f, args, env)
        }
    }

    func callNamed(_ name: String, _ args: [Arg], _ env: Env) throws -> Value {
        if name == "print" {
            let parts = try args.map { try eval($0.value, env: env).str() }
            output.append(parts.joined(separator: " "))
            return .void
        }
        if name == "abs" {
            let v = try posArg(args, 0, env) ?? .int(0)
            switch v {
            case .int(let i): return .int(Swift.abs(i))
            case .double(let d): return .double(Swift.abs(d))
            default: return v
            }
        }
        if name == "max" || name == "min" {
            let vals = try args.map { try eval($0.value, env: env) }
            guard let first = vals.first else { return .nilValue }
            var best = first
            for v in vals.dropFirst() {
                let c = compareValues(v, best)
                let takeIt = (name == "max") ? (c > 0) : (c < 0)
                if takeIt { best = v }
            }
            return best
        }
        if name == "Int" {
            return .int((try posArg(args, 0, env) ?? .int(0)).asInt())
        }
        if name == "Double" {
            return .double((try posArg(args, 0, env) ?? .int(0)).asDouble())
        }
        if name == "String" {
            return .string((try posArg(args, 0, env) ?? .string("")).str())
        }
        if name == "Bool" {
            return .bool((try posArg(args, 0, env) ?? .bool(false)).asBool())
        }
        if name == "Array" {
            return try posArg(args, 0, env) ?? .array([])
        }
        if ["sqrt", "sin", "cos", "tan", "floor", "ceil", "round"].contains(name) {
            let v = (try posArg(args, 0, env) ?? .double(0)).asDouble()
            let r: Double
            switch name {
            case "sqrt": r = v.squareRoot()
            case "sin": r = sin(v)
            case "cos": r = cos(v)
            case "tan": r = tan(v)
            case "floor": r = v.rounded(.down)
            case "ceil": r = v.rounded(.up)
            default: r = v.rounded()
            }
            return .double(r)
        }
        if name == "pow" {
            let a = (try posArg(args, 0, env) ?? .double(0)).asDouble()
            let b = (try posArg(args, 1, env) ?? .double(0)).asDouble()
            return .double(pow(a, b))
        }

        if name == "Set" {
            if let v = try posArg(args, 0, env), case .array(let a) = v {
                var out: [Value] = []
                for x in a where !out.contains(where: { compareValues($0, x) == 0 }) {
                    out.append(x.copyForStorage)
                }
                return .set(out)
            }
            if let v = try posArg(args, 0, env), case .set(let s) = v {
                return .set(s)
            }
            return .set([])
        }
        if name == "Task" || name == "MainActor" {
            if let cd = trailingClosureExpr(args) {
                _ = try? execBlock(cd.body, env: Env(parent: env))
            }
            return .void
        }

        if types[name] != nil {
            return .object(try instantiate(name, args, env))
        }
        if let ed = enums[name] {
            _ = ed
            throw RuntimeError("'\(name)' is an enum — build cases as \(name).caseName")
        }
        if let f = functions[name] {
            return try invoke(f, args, env, nil)
        }
        if let o = env.selfInstance(), let f = o.methods[name] {
            return try invoke(f, args, env, o)
        }
        if let g = try lookupVar(name, env) {
            return try callValue(g, args, env)
        }
        if viewConstructors.contains(name) {
            return try viewConstructor(name, args, env)
        }
        throw RuntimeError("unknown function '\(name)'")
    }

    func callValue(_ f: Value, _ args: [Arg], _ env: Env) throws -> Value {
        switch f {
        case .function(let fd, let closureEnv):
            return try invoke(fd, args, env, nil, definingEnv: closureEnv)
        case .closure(let cd, let closureEnv):
            let inner = Env(parent: closureEnv)
            let vals = try args.map { try eval($0.value, env: env) }
            for (i, p) in cd.params.enumerated() {
                inner.define(p.name, i < vals.count ? vals[i] : .void)
            }
            inner.args = vals
            let flow = try execBlock(cd.body, env: inner)
            if case .ret(let v) = flow, let v = v { return v }
            return .void
        case .vmClosure(let idx, let closureEnv):
            guard let vm = activeVM else {
                throw RuntimeError("no VM is active for that closure")
            }
            let vals = try args.map { try eval($0.value, env: env) }
            return try vm.runClosure(idx, captured: closureEnv, args: vals)
        default:
            throw RuntimeError("\(f.typeLabel) is not callable")
        }
    }

    private func invoke(_ f: FuncDecl, _ args: [Arg], _ callerEnv: Env,
                        _ selfObj: ObjectInstance?, definingEnv: Env? = nil) throws -> Value {
        let env = Env(parent: definingEnv)
        env.selfObj = selfObj
        try bindParams(f.params, args, callerEnv, into: env)

        if f.returnsView {
            let views = try collectViews(f.body, env: env)
            if views.count == 1 { return .view(views[0]) }
            if views.isEmpty { return .void }
            return .view(ViewNode(base: .group(views)))
        }

        let flow = try execBlock(f.body, env: env)
        if case .ret(let v) = flow, let v = v { return v }
        return .void
    }

    private func bindParams(_ params: [Param], _ args: [Arg], _ callerEnv: Env, into env: Env) throws {
        var filled = [Bool](repeating: false, count: params.count)
        var values = [Value?](repeating: nil, count: params.count)
        var cursor = 0

        for a in args {
            let v = try eval(a.value, env: callerEnv).copyForStorage
            if let l = a.label {
                var hit = -1
                for i in 0..<params.count where params[i].label == l && !filled[i] {
                    hit = i
                    break
                }
                if hit >= 0 {
                    values[hit] = v
                    filled[hit] = true
                    continue
                }
            }
            while cursor < params.count && filled[cursor] { cursor += 1 }
            if cursor < params.count {
                values[cursor] = v
                filled[cursor] = true
                cursor += 1
            }
        }

        for i in 0..<params.count {
            if let v = values[i] {
                env.define(params[i].name, v)
            } else if let d = params[i].defaultValue {
                env.define(params[i].name, try eval(d, env: env))
            } else {
                env.define(params[i].name, .void)
            }
        }
    }

    // MARK: - Mutating collection methods

    private func callMutating(_ target: Expr, _ name: String, _ args: [Arg], _ env: Env) throws -> Value? {
        let current = try eval(target, env: env)

        if case .array(var arr) = current {
            switch name {
            case "append":
                if let v = try posArg(args, 0, env) { arr.append(v.copyForStorage) }
            case "insert":
                if let v = try posArg(args, 0, env), let i = try posArg(args, 1, env)?.asInt() {
                    if i >= 0 && i <= arr.count { arr.insert(v.copyForStorage, at: i) }
                }
            case "remove":
                if let i = try posArg(args, 0, env)?.asInt(), i >= 0, i < arr.count {
                    arr.remove(at: i)
                }
            case "removeAll":
                arr.removeAll()
            case "removeLast":
                if !arr.isEmpty { arr.removeLast() }
            case "removeFirst":
                if !arr.isEmpty { arr.removeFirst() }
            case "sort":
                arr = arr.sorted { compareValues($0, $1) < 0 }
            case "reverse":
                arr.reverse()
            default:
                return nil
            }
            try writeBack(target, .array(arr), env)
            return .void
        }

        if case .dict(var d) = current {
            switch name {
            case "removeValue":
                if let k = try posArg(args, 0, env)?.str() { d.removeValue(forKey: k) }
            case "removeAll":
                d.removeAll()
            default:
                return nil
            }
            try writeBack(target, .dict(d), env)
            return .void
        }

        if case .set(var s) = current {
            switch name {
            case "insert":
                if let v = try posArg(args, 0, env),
                   !s.contains(where: { compareValues($0, v) == 0 }) {
                    s.append(v.copyForStorage)
                }
            case "remove":
                if let v = try posArg(args, 0, env) {
                    s.removeAll { compareValues($0, v) == 0 }
                }
            case "removeAll":
                s.removeAll()
            case "formUnion":
                if let v = try posArg(args, 0, env) {
                    for x in try iterate(v) where !s.contains(where: { compareValues($0, x) == 0 }) {
                        s.append(x.copyForStorage)
                    }
                }
            default:
                return nil
            }
            try writeBack(target, .set(s), env)
            return .void
        }

        if name == "toggle", case .bool(let b) = current {
            try writeBack(target, .bool(!b), env)
            return .void
        }

        return nil
    }

    // MARK: - Builtin members

    func callMember(_ base: Value, _ name: String, _ args: [Arg], _ env: Env) throws -> Value {
        // 1. View modifiers
        if case .view(var node) = base {
            let vals = try args.map { try eval($0.value, env: env) }
            node.mods.append(Mod(name: name, args: vals, labels: args.map { $0.label }))
            return .view(node)
        }

        // 2. Color helpers
        if case .color(let n) = base, name == "opacity" {
            let a = try posArg(args, 0, env)?.asDouble() ?? 1
            return .colorAlpha(n, a)
        }
        if case .implicit(let n) = base, name == "opacity" {
            let a = try posArg(args, 0, env)?.asDouble() ?? 1
            return .colorAlpha(n, a)
        }

        // 3. Namespace: enum case with payload, static method, color, font
        if case .namespace(let ns) = base {
            if let ed = enums[ns], let c = ed.cases.first(where: { $0.name == name }) {
                let vals = try args.map { try eval($0.value, env: env) }
                return try makeEnumValue(ed, c, vals, env)
            }
            if let td = types[ns], let f = td.staticMethods[name] {
                return try invoke(f, args, env, nil)
            }
            if ns == "Font", name == "system" {
                let size = (try labeledArg(args, "size", env))?.asDouble() ?? 17
                let weight = (try labeledArg(args, "weight", env))?.str() ?? "regular"
                return .fontSpec("system|\(size)|\(weight)")
            }
            if ns == "Color" { return .color(name) }
            if ns == "Task" || ns == "MainActor" { return .void }
            return .implicit(name)
        }

        // 4. Enum instance methods
        if case .enumValue(let ev) = base {
            if name == "rawValue" { return ev.raw ?? .string(ev.caseName) }
            if let ed = enums[ev.typeName], let f = ed.methods[name] {
                let inner = Env()
                inner.selfValue = .enumValue(ev)
                try bindParams(f.params, args, env, into: inner)
                let flow = try execBlock(f.body, env: inner)
                if case .ret(let v) = flow, let v = v { return v }
                return .void
            }
            throw RuntimeError("'\(ev.typeName)' has no method '\(name)'")
        }

        // 5. User methods on interpreted types
        if case .object(let o) = base {
            if let f = o.methods[name] {
                return try invoke(f, args, env, o)
            }
        }

        // 6. Array methods
        if case .array(let a) = base {
            switch name {
            case "contains":
                let v = try posArg(args, 0, env) ?? .void
                if let cl = trailingClosureExpr(args) {
                    for item in a where try callClosureValue(cl, env, [item]).asBool() { return .bool(true) }
                    return .bool(false)
                }
                return .bool(a.contains { compareValues($0, v) == 0 })
            case "joined":
                let sep = (try labeledArg(args, "separator", env))?.str() ?? ""
                return .string(a.map { $0.str() }.joined(separator: sep))
            case "map", "compactMap":
                guard let cl = trailingClosureExpr(args) else { return .array([]) }
                var out: [Value] = []
                for item in a {
                    let r = try callClosureValue(cl, env, [item])
                    if name == "compactMap" && r.isNil { continue }
                    out.append(r)
                }
                return .array(out)
            case "flatMap":
                guard let cl = trailingClosureExpr(args) else { return .array([]) }
                var out: [Value] = []
                for item in a {
                    let r = try callClosureValue(cl, env, [item])
                    if case .array(let sub) = r { out.append(contentsOf: sub) } else { out.append(r) }
                }
                return .array(out)
            case "filter":
                guard let cl = trailingClosureExpr(args) else { return base }
                var out: [Value] = []
                for item in a where try callClosureValue(cl, env, [item]).asBool() {
                    out.append(item)
                }
                return .array(out)
            case "reduce":
                let seed = try posArg(args, 0, env) ?? .int(0)
                guard let cl = trailingClosureExpr(args) else { return seed }
                var acc = seed
                for item in a { acc = try callClosureValue(cl, env, [acc, item]) }
                return acc
            case "sorted":
                if let cl = trailingClosureExpr(args) {
                    var arr = a
                    // simple insertion sort using the comparator (stable enough for small arrays)
                    var out: [Value] = []
                    for item in arr {
                        var inserted = false
                        for i in 0..<out.count {
                            if try callClosureValue(cl, env, [item, out[i]]).asBool() {
                                out.insert(item, at: i)
                                inserted = true
                                break
                            }
                        }
                        if !inserted { out.append(item) }
                    }
                    arr = out
                    return .array(arr)
                }
                return .array(a.sorted { compareValues($0, $1) < 0 })
            case "reversed":
                return .array(a.reversed())
            case "enumerated":
                return .array(a.enumerated().map { .tuple([.int($0.offset), $0.element]) })
            case "firstIndex":
                let v = try posArg(args, 0, env) ?? .void
                if let i = a.firstIndex(where: { compareValues($0, v) == 0 }) { return .int(i) }
                return .nilValue
            case "prefix":
                return .array(Array(a.prefix(try posArg(args, 0, env)?.asInt() ?? a.count)))
            case "suffix":
                return .array(Array(a.suffix(try posArg(args, 0, env)?.asInt() ?? a.count)))
            case "dropFirst":
                return .array(Array(a.dropFirst(try posArg(args, 0, env)?.asInt() ?? 1)))
            case "dropLast":
                return .array(Array(a.dropLast(try posArg(args, 0, env)?.asInt() ?? 1)))
            case "allSatisfy":
                guard let cl = trailingClosureExpr(args) else { return .bool(true) }
                for item in a where try !callClosureValue(cl, env, [item]).asBool() { return .bool(false) }
                return .bool(true)
            case "min":
                return a.min { compareValues($0, $1) < 0 } ?? .nilValue
            case "max":
                return a.max { compareValues($0, $1) < 0 } ?? .nilValue
            default:
                throw RuntimeError("Array has no method '\(name)'")
            }
        }

        // 7. String methods
        if case .string(let s) = base {
            switch name {
            case "uppercased": return .string(s.uppercased())
            case "lowercased": return .string(s.lowercased())
            case "capitalized": return .string(s.capitalized)
            case "hasPrefix": return .bool(s.hasPrefix((try posArg(args, 0, env) ?? .string("")).str()))
            case "hasSuffix": return .bool(s.hasSuffix((try posArg(args, 0, env) ?? .string("")).str()))
            case "contains": return .bool(s.contains((try posArg(args, 0, env) ?? .string("")).str()))
            case "replacingOccurrences":
                let target = (try labeledArg(args, "of", env))?.str() ?? ""
                let repl = (try labeledArg(args, "with", env))?.str() ?? ""
                return .string(s.replacingOccurrences(of: target, with: repl))
            case "trimmingCharacters":
                return .string(s.trimmingCharacters(in: .whitespacesAndNewlines))
            case "components":
                let sep = (try labeledArg(args, "separatedBy", env))?.str() ?? " "
                return .array(s.components(separatedBy: sep).map { .string($0) })
            case "split":
                let sep = (try posArg(args, 0, env))?.str() ?? " "
                return .array(s.components(separatedBy: CharacterSet(charactersIn: sep))
                    .filter { !$0.isEmpty }
                    .map { .string($0) })
            case "prefix":
                let n = try posArg(args, 0, env)?.asInt() ?? s.count
                return .string(String(s.prefix(n)))
            case "suffix":
                let n = try posArg(args, 0, env)?.asInt() ?? s.count
                return .string(String(s.suffix(n)))
            default:
                throw RuntimeError("String has no method '\(name)'")
            }
        }

        // 8. Set methods
        if case .set(let s) = base {
            switch name {
            case "contains":
                let v = try posArg(args, 0, env) ?? .void
                return .bool(s.contains { compareValues($0, v) == 0 })
            case "union":
                let other = try posArg(args, 0, env) ?? .set([])
                var out = s
                for x in try iterate(other) where !out.contains(where: { compareValues($0, x) == 0 }) {
                    out.append(x)
                }
                return .set(out)
            case "intersection":
                let other = try posArg(args, 0, env) ?? .set([])
                let list = try iterate(other)
                return .set(s.filter { a in list.contains { compareValues($0, a) == 0 } })
            case "subtracting":
                let other = try posArg(args, 0, env) ?? .set([])
                let list = try iterate(other)
                return .set(s.filter { a in !list.contains { compareValues($0, a) == 0 } })
            case "isSubset":
                let other = try posArg(args, 0, env) ?? .set([])
                let list = try iterate(other)
                return .bool(s.allSatisfy { a in list.contains { compareValues($0, a) == 0 } })
            case "sorted":
                return .array(s.sorted { compareValues($0, $1) < 0 })
            default:
                throw RuntimeError("Set has no method '\(name)'")
            }
        }

        // 9. Dictionary methods
        if case .dict(let d) = base {
            switch name {
            case "contains":
                let k = (try posArg(args, 0, env))?.str() ?? ""
                return .bool(d[k] != nil)
            case "updateValue":
                throw RuntimeError("Dictionary.updateValue needs a mutable dictionary — use `dict[key] = value`")
            default:
                throw RuntimeError("Dictionary has no method '\(name)'")
            }
        }

        // 9. Number methods
        if case .int(let i) = base {
            switch name {
            case "isMultiple": return .bool(i % (try posArg(args, 0, env)?.asInt() ?? 1) == 0)
            case "advanced": return .int(i + (try posArg(args, 0, env)?.asInt() ?? 0))
            default: break
            }
        }
        if case .double(let dv) = base {
            switch name {
            case "rounded": return .double(dv.rounded())
            case "squareRoot": return .double(dv.squareRoot())
            case "magnitude": return .double(Swift.abs(dv))
            default: break
            }
        }

        throw RuntimeError("\(base.typeLabel) has no method '\(name)'")
    }

    private func trailingClosureExpr(_ args: [Arg]) -> ClosureDef? {
        for a in args.reversed() {
            if a.label == nil, case .closure(let cd) = a.value { return cd }
        }
        return nil
    }

    private func callClosureValue(_ cd: ClosureDef, _ env: Env, _ values: [Value]) throws -> Value {
        let inner = Env(parent: env)
        for (i, p) in cd.params.enumerated() {
            inner.define(p.name, i < values.count ? values[i] : .void)
        }
        inner.args = values
        let flow = try execBlock(cd.body, env: inner)
        if case .ret(let v) = flow, let v = v { return v }
        return .void
    }

    // MARK: - View construction

    private func posArg(_ args: [Arg], _ i: Int, _ env: Env) throws -> Value? {
        let positional = args.filter {
            if $0.label != nil { return false }
            if case .closure = $0.value { return false }
            return true
        }
        guard i < positional.count else { return nil }
        return try eval(positional[i].value, env: env)
    }

    private func labeledArg(_ args: [Arg], _ label: String, _ env: Env) throws -> Value? {
        guard let a = args.first(where: { $0.label == label }) else { return nil }
        return try eval(a.value, env: env)
    }

    private func childViews(_ args: [Arg], _ env: Env) throws -> [ViewNode] {
        if let cd = trailingClosureExpr(args) {
            let inner = Env(parent: env)
            return try collectViews(cd.body, env: inner)
        }
        if let (idx, cap) = trailingVMClosure(args), let vm = activeVM {
            let values = try vm.runClosureCollecting(idx, captured: cap, args: [])
            var out: [ViewNode] = []
            for v in values {
                if case .view(let n) = v { out += n.flattened }
            }
            return out
        }
        return []
    }

    private func trailingVMClosure(_ args: [Arg]) -> (Int, Env)? {
        for a in args.reversed() where a.label == nil {
            if case .literal(.vmClosure(let idx, let cap)) = a.value { return (idx, cap) }
        }
        return nil
    }

    private func viewConstructor(_ name: String, _ args: [Arg], _ env: Env) throws -> Value {
        switch name {
        case "Text":
            return .view(.text((try posArg(args, 0, env) ?? .string("")).str()))

        case "Label":
            return .view(.text((try posArg(args, 0, env) ?? .string("")).str()))

        case "Link":
            return .view(.text((try posArg(args, 0, env) ?? .string("")).str()))

        case "Image":
            var imageName = "questionmark"
            if let a = try labeledArg(args, "systemName", env) {
                imageName = a.str()
            } else if let b = try posArg(args, 0, env) {
                imageName = b.str()
            }
            return .view(ViewNode(base: .image(imageName)))

        case "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack", "Grid":
            var axis: StackAxis = .vertical
            if name == "HStack" || name == "LazyHStack" { axis = .horizontal }
            if name == "ZStack" { axis = .depth }
            let align = (try labeledArg(args, "alignment", env))?.str() ?? "center"
            let spacing = (try labeledArg(args, "spacing", env))?.asDouble()
            let kids = try childViews(args, env)
            return .view(ViewNode(base: .stack(axis, align, spacing, kids)))

        case "NavigationStack", "NavigationView":
            let kids = try childViews(args, env)
            return .view(ViewNode(base: .nav(nil, kids)))

        case "ScrollView":
            return .view(ViewNode(base: .scroll(try childViews(args, env))))

        case "List", "Form":
            return .view(ViewNode(base: .list(try childViews(args, env))))

        case "Section", "Group", "DisclosureGroup", "WindowGroup", "Scene":
            return .view(ViewNode(base: .group(try childViews(args, env))))

        case "ForEach":
            guard let seq = try posArg(args, 0, env) else {
                throw RuntimeError("ForEach needs a collection")
            }
            if trailingClosureExpr(args) == nil,
               let (idx, cap) = trailingVMClosure(args), let vm = activeVM {
                var out: [ViewNode] = []
                for item in try iterate(seq) {
                    let values = try vm.runClosureCollecting(idx, captured: cap, args: [item])
                    for v in values {
                        if case .view(let n) = v { out += n.flattened }
                    }
                }
                return .view(ViewNode(base: .group(out)))
            }
            guard let cd = trailingClosureExpr(args) else {
                throw RuntimeError("ForEach needs a content closure")
            }
            var out: [ViewNode] = []
            for item in try iterate(seq) {
                let inner = Env(parent: env)
                if let p = cd.params.first { inner.define(p.name, item) }
                inner.args = [item]
                out += try collectViews(cd.body, env: inner)
            }
            return .view(ViewNode(base: .group(out)))

        case "Button":
            let title = try posArg(args, 0, env)?.str()
            let label: [ViewNode] = title.map { [ViewNode.text($0)] } ?? []
            if trailingClosureExpr(args) == nil, let (idx, cap) = trailingVMClosure(args) {
                let action: () -> Void = { [weak self] in
                    guard let self = self, let vm = self.activeVM else { return }
                    _ = try? vm.runClosure(idx, captured: cap, args: [])
                }
                return .view(ViewNode(base: .button(label, action)))
            }
            guard let cd = trailingClosureExpr(args) else {
                return .view(ViewNode(base: .button(label, {})))
            }
            let captured = Env(parent: env)
            let action: () -> Void = { [weak self] in
                guard let self = self else { return }
                _ = try? self.execBlock(cd.body, env: Env(parent: captured))
            }
            return .view(ViewNode(base: .button(label, action)))

        case "Toggle":
            let label = (try posArg(args, 0, env))?.str() ?? ""
            guard let b = try labeledArg(args, "isOn", env), case .binding(let box) = b else {
                throw RuntimeError("Toggle needs `isOn: $someBoolState`")
            }
            return .view(ViewNode(base: .toggle(label, box)))

        case "TextField", "SecureField":
            let placeholder = (try posArg(args, 0, env))?.str() ?? ""
            guard let b = try labeledArg(args, "text", env), case .binding(let box) = b else {
                throw RuntimeError("\(name) needs `text: $someStringState`")
            }
            return .view(ViewNode(base: .textField(placeholder, box)))

        case "Slider":
            guard let b = try labeledArg(args, "value", env), case .binding(let box) = b else {
                throw RuntimeError("Slider needs `value: $someNumberState`")
            }
            var lo = 0.0, hi = 1.0
            if let r = try labeledArg(args, "in", env), case .range(let a, let z, _) = r {
                lo = Double(a); hi = Double(z)
            }
            return .view(ViewNode(base: .slider(box, lo, hi)))

        case "Stepper":
            let label = (try posArg(args, 0, env))?.str() ?? ""
            guard let b = try labeledArg(args, "value", env), case .binding(let box) = b else {
                throw RuntimeError("Stepper needs `value: $someNumberState`")
            }
            return .view(ViewNode(base: .stepper(label, box)))

        case "Spacer":
            return .view(ViewNode(base: .spacer))

        case "Divider":
            return .view(ViewNode(base: .divider))

        case "ProgressView":
            return .view(ViewNode(base: .progress((try labeledArg(args, "value", env))?.asDouble())))

        case "Rectangle", "Circle", "Capsule":
            return .view(ViewNode(base: .shape(name, 0)))

        case "RoundedRectangle":
            let r = (try labeledArg(args, "cornerRadius", env))?.asDouble() ?? 12
            return .view(ViewNode(base: .shape(name, r)))

        case "Color":
            if let s = try posArg(args, 0, env) {
                return .color(s.str())
            }
            return .color("gray")

        default:
            throw RuntimeError("unknown view '\(name)'")
        }
    }

    // MARK: - Operators

    private func evalBinary(_ op: String, _ a: Expr, _ b: Expr, _ env: Env) throws -> Value {
        switch op {
        case "&&":
            if try !eval(a, env: env).asBool() { return .bool(false) }
            return .bool(try eval(b, env: env).asBool())
        case "||":
            if try eval(a, env: env).asBool() { return .bool(true) }
            return .bool(try eval(b, env: env).asBool())
        case "??":
            let l = try eval(a, env: env)
            if l.isNil { return try eval(b, env: env) }
            return l
        default:
            break
        }

        let l = try eval(a, env: env)
        let r = try eval(b, env: env)

        switch op {
        case "...":
            return .range(l.asInt(), r.asInt(), true)
        case "..<":
            return .range(l.asInt(), r.asInt(), false)
        case "==":
            return .bool(compareValues(l, r) == 0)
        case "!=":
            return .bool(compareValues(l, r) != 0)
        case "<":
            return .bool(compareValues(l, r) < 0)
        case ">":
            return .bool(compareValues(l, r) > 0)
        case "<=":
            return .bool(compareValues(l, r) <= 0)
        case ">=":
            return .bool(compareValues(l, r) >= 0)
        default:
            if customOps.contains(op), let f = functions[op] {
                let inner = Env()
                if f.params.count > 0 { inner.define(f.params[0].name, l) }
                if f.params.count > 1 { inner.define(f.params[1].name, r) }
                let flow = try execBlock(f.body, env: inner)
                if case .ret(let v) = flow, let v = v { return v }
                return .void
            }
            return try arith(op, l, r)
        }
    }

    private func arith(_ op: String, _ l: Value, _ r: Value) throws -> Value {
        if op == "+" {
            if case .string(let s) = l { return .string(s + r.str()) }
            if case .string(let s) = r { return .string(l.str() + s) }
            if case .array(let a) = l, case .array(let b) = r { return .array(a + b) }
        }

        let bothInt: Bool
        if case .int = l, case .int = r { bothInt = true } else { bothInt = false }

        if bothInt {
            let x = l.asInt(), y = r.asInt()
            switch op {
            case "+": return .int(x + y)
            case "-": return .int(x - y)
            case "*": return .int(x * y)
            case "/":
                if y == 0 { throw RuntimeError("division by zero") }
                return .int(x / y)
            case "%":
                if y == 0 { throw RuntimeError("division by zero") }
                return .int(x % y)
            default: throw RuntimeError("unsupported operator '\(op)'")
            }
        }

        let x = l.asDouble(), y = r.asDouble()
        switch op {
        case "+": return .double(x + y)
        case "-": return .double(x - y)
        case "*": return .double(x * y)
        case "/":
            if y == 0 { throw RuntimeError("division by zero") }
            return .double(x / y)
        default: throw RuntimeError("unsupported operator '\(op)'")
        }
    }

    private func compareValues(_ l: Value, _ r: Value) -> Int {
        switch (l, r) {
        case (.int(let a), .int(let b)):
            return a == b ? 0 : (a < b ? -1 : 1)
        case (.string(let a), .string(let b)):
            return a == b ? 0 : (a < b ? -1 : 1)
        case (.bool(let a), .bool(let b)):
            return a == b ? 0 : (a ? 1 : -1)
        case (.nilValue, .nilValue):
            return 0
        case (.nilValue, _):
            return -1
        case (_, .nilValue):
            return 1
        case (.enumValue(let a), .enumValue(let b)):
            if a.typeName != b.typeName { return a.typeName < b.typeName ? -1 : 1 }
            if a.caseName != b.caseName { return a.caseName < b.caseName ? -1 : 1 }
            return 0
        case (.enumValue(let a), .implicit(let n)):
            return a.caseName == n ? 0 : (a.caseName < n ? -1 : 1)
        case (.implicit(let n), .enumValue(let b)):
            return n == b.caseName ? 0 : (n < b.caseName ? -1 : 1)
        case (.int, .double), (.double, .int), (.double, .double):
            let a = l.asDouble(), b = r.asDouble()
            return a == b ? 0 : (a < b ? -1 : 1)
        default:
            return l.str() == r.str() ? 0 : (l.str() < r.str() ? -1 : 1)
        }
    }

    // MARK: - Iteration

    func iterate(_ v: Value) throws -> [Value] {
        switch v {
        case .array(let a):
            return a
        case .set(let s):
            return s
        case .range(let lo, let hi, let closed):
            let top = closed ? hi : hi - 1
            if top < lo { return [] }
            if top - lo > 20000 { throw RuntimeError("range is too large to iterate") }
            return (lo...top).map { .int($0) }
        case .string(let s):
            return s.map { .string(String($0)) }
        case .dict(let d):
            return d.keys.sorted().map { .string($0) }
        case .int(let n):
            if n <= 0 { return [] }
            return (0..<min(n, 20000)).map { .int($0) }
        default:
            throw RuntimeError("\(v.typeLabel) is not iterable")
        }
    }

    // MARK: - String interpolation

    private func interpolate(_ raw: String, env: Env) throws -> String {
        var out = ""
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "(" {
                    var depth = 1
                    var j = i + 2
                    var inner = ""
                    while j < chars.count, depth > 0 {
                        let x = chars[j]
                        if x == "(" { depth += 1 }
                        if x == ")" {
                            depth -= 1
                            if depth == 0 { break }
                        }
                        inner.append(x)
                        j += 1
                    }
                    out += try evalSnippet(inner, env).str()
                    i = j + 1
                    continue
                }
                switch n {
                case "n": out += "\n"
                case "t": out += "\t"
                case "\"": out += "\""
                case "\\": out += "\\"
                default: out.append(n)
                }
                i += 2
                continue
            }
            out.append(ch)
            i += 1
        }
        return out
    }

    private func evalSnippet(_ src: String, _ env: Env) throws -> Value {
        let toks = try Lexer(src, customOps: customOps).tokenize()
        let parser = Parser(toks, customOps: customOps)
        let expr = try parser.parseExpr()
        return try eval(expr, env: env)
    }

    // MARK: - External invocation (renderer callbacks)

    func invokeValue(_ v: Value) {
        switch v {
        case .closure(let cd, let closureEnv):
            _ = try? execBlock(cd.body, env: Env(parent: closureEnv))
        case .function(let fd, let closureEnv):
            _ = try? invoke(fd, [], Env(), nil, definingEnv: closureEnv)
        default:
            break
        }
    }
}

// MARK: - VM bridge
//
// These are the only entry points the bytecode VM uses. Everything below is a thin
// wrapper over the tree-walker's own primitives, so both engines share one definition
// of every semantic rule.

extension Interpreter {

    func selfValue(_ env: Env) throws -> Value {
        if let sv = env.selfBoundValue() { return sv }
        if let o = env.selfInstance() { return .object(o) }
        throw RuntimeError(message: "'self' used outside of a type")
    }

    func dollarValue(_ i: Int, _ env: Env) throws -> Value {
        if let a = env.closureArgs(), i < a.count { return a[i] }
        throw RuntimeError(message: "$\(i) used outside of a closure")
    }

    func bindingValue(_ n: String, _ env: Env) throws -> Value {
        if let o = env.selfInstance(), let box = o.stateBoxes[n] { return .binding(box) }
        if let v = try lookupVar(n, env), case .binding(let b) = v { return .binding(b) }
        throw RuntimeError(message: "cannot form a binding from '\(n)'")
    }

    func subscriptAssign(_ container: Value, _ keys: [Value], _ v: Value) throws -> Value {
        guard let k = keys.first else { throw RuntimeError(message: "bad subscript") }
        if case .array(var arr) = container {
            let i = k.asInt()
            guard i >= 0, i < arr.count else {
                throw RuntimeError(message: "index \(i) out of range (count \(arr.count))")
            }
            arr[i] = v.copyForStorage
            return .array(arr)
        }
        if case .dict(var d) = container {
            d[k.str()] = v.copyForStorage
            return .dict(d)
        }
        if case .object(let o) = container, let f = types[o.typeName]?.subscriptSet {
            let inner = Env()
            inner.selfObj = o
            for (i, p) in f.params.enumerated() {
                if i < keys.count {
                    inner.define(p.name, keys[i])
                } else {
                    inner.define(p.name, v.copyForStorage)
                }
            }
            _ = try execBlock(f.body, env: inner)
            return container
        }
        throw RuntimeError(message: "cannot subscript-assign this value")
    }

    func binaryValues(_ op: String, _ l: Value, _ r: Value, _ env: Env) throws -> Value {
        switch op {
        case "...": return .range(l.asInt(), r.asInt(), true)
        case "..<": return .range(l.asInt(), r.asInt(), false)
        case "==": return .bool(compareValues(l, r) == 0)
        case "!=": return .bool(compareValues(l, r) != 0)
        case "<": return .bool(compareValues(l, r) < 0)
        case ">": return .bool(compareValues(l, r) > 0)
        case "<=": return .bool(compareValues(l, r) <= 0)
        case ">=": return .bool(compareValues(l, r) >= 0)
        default:
            if customOps.contains(op), let f = functions[op] {
                let inner = Env()
                if f.params.count > 0 { inner.define(f.params[0].name, l) }
                if f.params.count > 1 { inner.define(f.params[1].name, r) }
                let flow = try execBlock(f.body, env: inner)
                if case .ret(let v) = flow, let v = v { return v }
                return .void
            }
            return try arith(op, l, r)
        }
    }

    func unaryValue(_ op: String, _ v: Value, _ env: Env) throws -> Value {
        if op == "-" {
            switch v {
            case .int(let i): return .int(-i)
            case .double(let d): return .double(-d)
            default: throw RuntimeError(message: "unary '-' needs a number")
            }
        }
        if op == "!" { return .bool(!v.asBool()) }
        if customOps.contains(op), let f = functions[op] {
            let inner = Env()
            if let p0 = f.params.first { inner.define(p0.name, v) }
            let flow = try execBlock(f.body, env: inner)
            if case .ret(let r) = flow, let r = r { return r }
            return .void
        }
        return .bool(!v.asBool())
    }

    func bindValues(_ params: [Param], _ values: [Value], _ labels: [String?], into env: Env) throws {
        var filled = [Bool](repeating: false, count: params.count)
        var slots = [Value?](repeating: nil, count: params.count)
        var cursor = 0

        for (i, v) in values.enumerated() {
            let label = i < labels.count ? labels[i] : nil
            if let l = label {
                var hit = -1
                for j in 0..<params.count where params[j].label == l && !filled[j] {
                    hit = j
                    break
                }
                if hit >= 0 {
                    slots[hit] = v
                    filled[hit] = true
                    continue
                }
            }
            while cursor < params.count && filled[cursor] { cursor += 1 }
            if cursor < params.count {
                slots[cursor] = v
                filled[cursor] = true
                cursor += 1
            }
        }

        for i in 0..<params.count {
            if let v = slots[i] {
                env.define(params[i].name, v)
            } else if let d = params[i].defaultValue {
                env.define(params[i].name, try eval(d, env: env))
            } else {
                env.define(params[i].name, .void)
            }
        }
    }
}
