import Foundation

/// Stack VM. Runs compiled chunks with an explicit frame stack; every structural
/// operation is delegated back to the runtime, so semantics stay identical to the
/// tree-walker. Because the frame stack lives on the heap, a run can be stopped and
/// resumed — that is the property the tree-walker cannot offer.
final class VM {
    unowned let rt: Interpreter

    private(set) var chunks: [Chunk] = []
    private(set) var functionChunks: [String: Int] = [:]
    private(set) var methodChunks: [String: Int] = [:]
    private(set) var closureChunks: [String: Int] = [:]

    private var stack: [Value] = []
    private var frames: [Frame] = []
    private var steps = 0
    private var limit = 6_000_000

    init(runtime: Interpreter) {
        self.rt = runtime
    }

    // MARK: - compilation of the declaration set

    func prepare() {
        chunks.removeAll()
        functionChunks.removeAll()
        methodChunks.removeAll()

        for (name, f) in rt.functions {
            let c = Compiler()
            let idx = c.compileFunction(f, name: name)
            let base = chunks.count
            chunks.append(contentsOf: c.chunks)
            functionChunks[name] = base + idx
        }

        for (typeName, td) in rt.types {
            for (name, f) in td.methods {
                let c = Compiler()
                let idx = c.compileFunction(f, name: "\(typeName).\(name)")
                let base = chunks.count
                chunks.append(contentsOf: c.chunks)
                methodChunks["\(typeName).\(name)"] = base + idx
            }
            for (name, f) in td.computed {
                let c = Compiler()
                let idx = c.compileFunction(f, name: "\(typeName).\(name)")
                let base = chunks.count
                chunks.append(contentsOf: c.chunks)
                methodChunks["\(typeName).\(name)#get"] = base + idx
            }
            if let initFn = td.initializer {
                let c = Compiler()
                let idx = c.compileFunction(initFn, name: "\(typeName).init")
                let base = chunks.count
                chunks.append(contentsOf: c.chunks)
                methodChunks["\(typeName).init"] = base + idx
            }
        }

        for (enumName, ed) in rt.enums {
            for (name, f) in ed.methods {
                let c = Compiler()
                let idx = c.compileFunction(f, name: "\(enumName).\(name)")
                let base = chunks.count
                chunks.append(contentsOf: c.chunks)
                methodChunks["\(enumName).\(name)"] = base + idx
            }
        }
    }

    // MARK: - entry

    /// Runs a fresh chunk to completion. Re-entrant: a nested run (from a native
    /// callback or a `defer` body) gets its own stack and restores the outer one.
    func run(_ entry: Int, _ env: Env) throws -> Value {
        let savedStack = stack
        let savedFrames = frames
        let savedSteps = steps

        stack = []
        frames = [Frame(chunkIndex: entry, env: env, stackBase: 0)]
        steps = 0

        defer {
            stack = savedStack
            frames = savedFrames
            steps = savedSteps
        }

        try loop()
        return stack.last ?? .void
    }

    func runCollecting(_ entry: Int, _ env: Env) throws -> [Value] {
        let result = try run(entry, env)
        if case .array(let items) = result { return items }
        if case .void = result { return [] }
        return [result]
    }

    /// Installs externally compiled chunks (view bodies, top-level scripts).
    func adopt(_ extra: [Chunk]) -> Int {
        let base = chunks.count
        chunks.append(contentsOf: extra)
        return base
    }

    func runClosureCollecting(_ chunkIndex: Int, captured: Env, args: [Value]) throws -> [Value] {
        let env = Env(parent: captured)
        for (i, p) in chunks[chunkIndex].params.enumerated() {
            env.define(p.name, i < args.count ? args[i] : .void)
        }
        env.args = args
        let result = try run(chunkIndex, env)
        if case .array(let items) = result { return items }
        if case .void = result { return [] }
        return [result]
    }

    func runClosure(_ chunkIndex: Int, captured: Env, args: [Value]) throws -> Value {
        let env = Env(parent: captured)
        let params = chunks[chunkIndex].params
        for (i, p) in params.enumerated() {
            env.define(p.name, i < args.count ? args[i] : .void)
        }
        env.args = args
        return try run(chunkIndex, env)
    }

    // MARK: - loop

    private func loop() throws {
        while !frames.isEmpty {
            steps += 1
            if steps > limit { throw RuntimeError(message: "execution limit reached") }

            guard let top = frames.last else { return }
            let chunk = chunks[top.chunkIndex]

            if top.ip >= chunk.ops.count {
                try popFrame(.void)
                continue
            }

            let op = chunk.ops[top.ip]
            frames[frames.count - 1].ip += 1

            switch op {
            case .pushConst(let i):
                push(chunk.consts[i])
            case .pushNil:
                push(.nilValue)
            case .pushTrue:
                push(.bool(true))
            case .pushFalse:
                push(.bool(false))
            case .pushVoid:
                push(.void)

            case .pop:
                _ = pop()
            case .dup:
                if let v = stack.last { push(v) }

            case .load(let n):
                if let v = try rt.lookupVar(n, frames[frames.count - 1].env) {
                    push(v)
                } else {
                    throw RuntimeError(message: "unknown identifier '\(n)'")
                }
            case .loadSelf:
                push(try rt.selfValue(frames[frames.count - 1].env))
            case .loadDollar(let i):
                push(try rt.dollarValue(i, frames[frames.count - 1].env))
            case .loadBinding(let n):
                push(try rt.bindingValue(n, frames[frames.count - 1].env))

            case .loadMember(let n):
                let base = pop()
                push(try rt.memberValue(base, n, frames[frames.count - 1].env))

            case .define(let n):
                let v = pop()
                frames[frames.count - 1].env.define(n, v)
                push(.void)

            case .store(let n):
                let v = pop()
                try rt.assignVar(n, v, frames[frames.count - 1].env)
                push(.void)

            case .storeMember(let n):
                let v = pop()
                let base = pop()
                if case .object(let o) = base {
                    try rt.setField(o, n, v.copyForStorage, frames[frames.count - 1].env)
                } else {
                    throw RuntimeError(message: "cannot assign to member '\(n)'")
                }
                push(.void)

            case .storeSubscriptNamed(let n, let kc):
                let v = pop()
                let keys = popN(kc)
                let env = frames[frames.count - 1].env
                let cur = try rt.lookupVar(n, env) ?? .void
                let updated = try rt.subscriptAssign(cur, keys, v)
                try rt.assignVar(n, updated, env)
                push(.void)

            case .storeSubscriptMember(let field, let kc):
                let v = pop()
                let keys = popN(kc)
                let obj = pop()
                let env = frames[frames.count - 1].env
                guard case .object(let o) = obj else {
                    throw RuntimeError(message: "cannot assign through member '\(field)'")
                }
                let cur = o.stateBoxes[field]?.value ?? o.fields[field] ?? .void
                let updated = try rt.subscriptAssign(cur, keys, v)
                try rt.setField(o, field, updated, env)
                push(.void)

            case .binary(let opName):
                let r = pop()
                let l = pop()
                push(try rt.binaryValues(opName, l, r, frames[frames.count - 1].env))

            case .unary(let opName):
                let v = pop()
                push(try rt.unaryValue(opName, v, frames[frames.count - 1].env))

            case .jump(let target):
                frames[frames.count - 1].ip = target

            case .jumpIfFalse(let target):
                if !pop().asBool() { frames[frames.count - 1].ip = target }

            case .jumpIfTrue(let target):
                if pop().asBool() { frames[frames.count - 1].ip = target }

            case .jumpIfNil(let target):
                if pop().isNil { frames[frames.count - 1].ip = target }

            case .subscriptGet(let n):
                let keys = popN(n)
                let base = pop()
                push(try rt.subscriptValue(base, keys))

            case .makeArray(let n):
                let items = popN(n)
                push(.array(items))

            case .makeTuple(let n):
                let items = popN(n)
                push(.tuple(items))

            case .makeDict(let n):
                var d: [String: Value] = [:]
                for _ in 0..<n {
                    let v = pop()
                    let k = pop()
                    d[k.str()] = v
                }
                push(.dict(d))

            case .makeClosure(let idx):
                push(.vmClosure(idx, frames[frames.count - 1].env))

            case .callNamed(let name, let argc, let labelIdx):
                try callNamed(name, argc, chunk.argLabels[labelIdx])

            case .callMember(let name, let argc, let labelIdx):
                try callMember(name, argc, chunk.argLabels[labelIdx])

            case .callValue(let argc):
                try callValue(argc)

            case .ret:
                let v = pop()
                try popFrame(v)
            case .retVoid:
                try popFrame(.void)

            case .pushHandler(let target):
                frames[frames.count - 1].handlers.append((ip: target, stackDepth: stack.count))
            case .popHandler:
                if !frames[frames.count - 1].handlers.isEmpty {
                    frames[frames.count - 1].handlers.removeLast()
                }

            case .throwTop:
                try raise(pop())

            case .switchDispatch(let tableIdx):
                let subject = pop()
                guard tableIdx < chunk.switchTables.count else { break }
                var matched = false
                for arm in chunk.switchTables[tableIdx] {
                    if arm.isDefault {
                        frames[frames.count - 1].ip = arm.target
                        matched = true
                        break
                    }
                    for p in arm.patterns {
                        let binds = Env(parent: frames[frames.count - 1].env)
                        if rt.match(p, subject, binds) {
                            frames[frames.count - 1].env = binds
                            frames[frames.count - 1].ip = arm.target
                            matched = true
                            break
                        }
                    }
                    if matched { break }
                }

            case .catchDispatch(let tableIdx):
                let error = pop()
                guard tableIdx < chunk.catchTables.count else { throw ThrownError(value: error) }
                for arm in chunk.catchTables[tableIdx] {
                    if let p = arm.pattern {
                        let binds = Env(parent: frames[frames.count - 1].env)
                        if !rt.match(p, error, binds) { continue }
                        frames[frames.count - 1].env = binds
                        frames[frames.count - 1].ip = arm.target
                        break
                    }
                    if let n = arm.name {
                        frames[frames.count - 1].env.define(n, error)
                    } else {
                        frames[frames.count - 1].env.define("error", error)
                    }
                    frames[frames.count - 1].ip = arm.target
                    break
                }

            case .tryOptional(let target):
                frames[frames.count - 1].ip = target
            case .tryForced:
                break

            case .forceUnwrap:
                let v = pop()
                if v.isNil { throw RuntimeError(message: "unexpectedly found nil while unwrapping") }
                push(v)

            case .awaitTop:
                // Values are already resolved; suspension lands here in the next increment.
                break

            case .fallthroughJump:
                break
            }
        }
    }

    // MARK: - stack helpers

    private func push(_ v: Value) { stack.append(v) }

    @discardableResult
    private func pop() -> Value {
        guard let v = stack.popLast() else { return .void }
        return v
    }

    private func popN(_ n: Int) -> [Value] {
        guard n > 0, n <= stack.count else { return [] }
        let items = Array(stack.suffix(n))
        stack.removeLast(n)
        return items
    }

    private func popFrame(_ value: Value) throws {
        guard let f = frames.popLast() else { return }
        let chunk = chunks[f.chunkIndex]

        for idx in f.deferred.reversed() {
            _ = try? run(idx, f.env)
        }

        var result = value
        if chunk.collectsValues {
            let base = min(f.stackBase, stack.count)
            let collected = Array(stack[base...])
            result = .array(collected)
        }

        let base = min(f.stackBase, stack.count)
        if base < stack.count { stack.removeSubrange(base..<stack.count) }

        if !frames.isEmpty { push(result) }
    }

    private func raise(_ error: Value) throws {
        while let top = frames.last {
            if let h = top.handlers.last {
                frames[frames.count - 1].handlers.removeLast()
                if h.stackDepth <= stack.count {
                    stack.removeSubrange(h.stackDepth..<stack.count)
                }
                push(error)
                frames[frames.count - 1].ip = h.ip
                return
            }
            _ = frames.popLast()
        }
        throw ThrownError(value: error)
    }

    // MARK: - calls

    private func argsFromStack(_ argc: Int) -> [Value] {
        popN(argc)
    }

    private func literalArgs(_ values: [Value], _ labels: [String?]) -> [Arg] {
        var out: [Arg] = []
        for (i, v) in values.enumerated() {
            out.append(Arg(label: i < labels.count ? labels[i] : nil, value: .literal(v)))
        }
        return out
    }

    private func callNamed(_ name: String, _ argc: Int, _ labels: [String?]) throws {
        let values = argsFromStack(argc)

        if name == "__iterate" {
            let seq = values.first ?? .void
            push(.array(try rt.iterate(seq)))
            return
        }

        if let idx = functionChunks[name], let f = rt.functions[name] {
            let env = Env()
            try rt.bindValues(f.params, values, labels, into: env)
            frames.append(Frame(chunkIndex: idx, env: env, stackBase: stack.count))
            return
        }

        let args = literalArgs(values, labels)
        push(try rt.callNamed(name, args, frames[frames.count - 1].env))
    }

    private func callMember(_ name: String, _ argc: Int, _ labels: [String?]) throws {
        let values = argsFromStack(argc)
        let base = pop()
        let env = frames[frames.count - 1].env

        if case .object(let o) = base,
           let idx = methodChunks["\(o.typeName).\(name)"],
           let f = o.methods[name] {
            let inner = Env()
            inner.selfObj = o
            try rt.bindValues(f.params, values, labels, into: inner)
            frames.append(Frame(chunkIndex: idx, env: inner, stackBase: stack.count))
            return
        }

        let args = literalArgs(values, labels)
        push(try rt.callMember(base, name, args, env))
    }

    private func callValue(_ argc: Int) throws {
        let values = argsFromStack(argc)
        let callee = pop()
        let env = frames[frames.count - 1].env

        switch callee {
        case .vmClosure(let idx, let captured):
            let inner = Env(parent: captured)
            for (i, p) in chunks[idx].params.enumerated() {
                inner.define(p.name, i < values.count ? values[i] : .void)
            }
            inner.args = values
            frames.append(Frame(chunkIndex: idx, env: inner, stackBase: stack.count))
        default:
            let args = literalArgs(values, [])
            push(try rt.callValue(callee, args, env))
        }
    }

    // MARK: - disassembly

    func disassemble(_ chunkIndex: Int) -> String {
        guard chunkIndex < chunks.count else { return "<no chunk>" }
        let c = chunks[chunkIndex]
        var out = "── chunk \(chunkIndex) \(c.name) ──\n"
        for (i, op) in c.ops.enumerated() {
            out += String(format: "%4d  ", i) + describe(op) + "\n"
        }
        return out
    }

    private func describe(_ op: Op) -> String {
        switch op {
        case .pushConst(let i): return "const #\(i)"
        case .pushNil: return "nil"
        case .pushTrue: return "true"
        case .pushFalse: return "false"
        case .pushVoid: return "void"
        case .load(let n): return "load \(n)"
        case .loadSelf: return "self"
        case .loadMember(let n): return "member \(n)"
        case .loadDollar(let i): return "dollar \(i)"
        case .loadBinding(let n): return "binding $\(n)"
        case .store(let n): return "store \(n)"
        case .define(let n): return "define \(n)"
        case .storeMember(let n): return "storeMember \(n)"
        case .storeSubscriptNamed(let n, let c): return "storeSubscript \(n)/\(c)"
        case .storeSubscriptMember(let n, let c): return "storeSubscriptMember \(n)/\(c)"
        case .pop: return "pop"
        case .dup: return "dup"
        case .binary(let o): return "binary \(o)"
        case .unary(let o): return "unary \(o)"
        case .jump(let t): return "jump \(t)"
        case .jumpIfFalse(let t): return "jumpIfFalse \(t)"
        case .jumpIfTrue(let t): return "jumpIfTrue \(t)"
        case .jumpIfNil(let t): return "jumpIfNil \(t)"
        case .subscriptGet(let n): return "subscript \(n)"
        case .makeArray(let n): return "array \(n)"
        case .makeTuple(let n): return "tuple \(n)"
        case .makeDict(let n): return "dict \(n)"
        case .makeClosure(let i): return "closure #\(i)"
        case .callNamed(let n, let c, _): return "call \(n)/\(c)"
        case .callMember(let n, let c, _): return "callMember \(n)/\(c)"
        case .callValue(let c): return "callValue/\(c)"
        case .ret: return "ret"
        case .retVoid: return "retVoid"
        case .pushHandler(let t): return "handler \(t)"
        case .popHandler: return "popHandler"
        case .throwTop: return "throw"
        case .tryOptional(let t): return "try? \(t)"
        case .tryForced: return "try!"
        case .awaitTop: return "await"
        case .forceUnwrap: return "forceUnwrap"
        case .fallthroughJump: return "fallthrough"
        case .switchDispatch(let i): return "switch #\(i)"
        case .catchDispatch(let i): return "catch #\(i)"
        }
    }
}
