import Foundation

/// AST -> bytecode. A structural recursion: every `expr` leaves exactly one value on
/// the stack, every `stmt` leaves the stack balanced.
final class Compiler {
    private(set) var chunks: [Chunk] = []
    private var cur = 0
    private var parents: [Int] = []
    private var hiddenCounter = 0

    private final class LoopCtx {
        var breaks: [Int] = []
        var continues: [Int] = []
    }
    private final class SwitchCtx {
        var tableIndex = 0
        var armStarts: [Int] = []
        var fallthroughs: [[Int]] = []
        var breaks: [Int] = []
        var endJumps: [Int] = []
    }

    private var loops: [LoopCtx] = []
    private var switches: [SwitchCtx] = []

    // MARK: - entry points

    func compileTopLevel(_ stmts: [Stmt], collecting: Bool) -> Int {
        let idx = beginChunk(name: "<top>", collecting: collecting)
        for s in stmts { stmt(s) }
        emit(.pushVoid)
        emit(collecting ? .ret : .retVoid)
        endChunk()
        return idx
    }

    func compileFunction(_ f: FuncDecl, name: String) -> Int {
        let idx = beginChunk(name: name, collecting: f.returnsView)
        chunks[idx].params = f.params
        chunks[idx].isViewFunction = f.returnsView
        for s in f.body { stmt(s) }
        emit(.pushVoid)
        emit(f.returnsView ? .ret : .retVoid)
        endChunk()
        return idx
    }

    func compileClosure(_ cd: ClosureDef) -> Int {
        let idx = beginChunk(name: "<closure>", collecting: false)
        chunks[idx].params = cd.params
        for s in cd.body { stmt(s) }
        emit(.pushVoid)
        emit(.retVoid)
        endChunk()
        return idx
    }

    func compileExpression(_ e: Expr) -> Int {
        let idx = beginChunk(name: "<expr>", collecting: false)
        expr(e)
        emit(.ret)
        endChunk()
        return idx
    }

    // MARK: - chunk plumbing

    private func beginChunk(name: String, collecting: Bool) -> Int {
        var c = Chunk()
        c.name = name
        c.collectsValues = collecting
        chunks.append(c)
        parents.append(cur)
        cur = chunks.count - 1
        return cur
    }

    private func endChunk() {
        cur = parents.popLast() ?? 0
    }

    @discardableResult
    private func emit(_ op: Op) -> Int {
        chunks[cur].ops.append(op)
        return chunks[cur].ops.count - 1
    }

    private func here() -> Int { chunks[cur].ops.count }

    private func patch(_ at: Int, _ target: Int) {
        guard at >= 0, at < chunks[cur].ops.count else { return }
        switch chunks[cur].ops[at] {
        case .jump: chunks[cur].ops[at] = .jump(target)
        case .jumpIfFalse: chunks[cur].ops[at] = .jumpIfFalse(target)
        case .jumpIfNil: chunks[cur].ops[at] = .jumpIfNil(target)
        case .pushHandler: chunks[cur].ops[at] = .pushHandler(target)
        default: break
        }
    }

    private func constant(_ v: Value) -> Int {
        chunks[cur].consts.append(v)
        return chunks[cur].consts.count - 1
    }

    private func labelTable(_ labels: [String?]) -> Int {
        chunks[cur].argLabels.append(labels)
        return chunks[cur].argLabels.count - 1
    }

    private func hidden(_ tag: String) -> String {
        hiddenCounter += 1
        return "__\(tag)\(hiddenCounter)"
    }

    private var collecting: Bool { chunks[cur].collectsValues }

    // MARK: - statements

    private func stmt(_ s: Stmt) {
        switch s {
        case .expr(let e):
            expr(e)
            if !collecting { emit(.pop) }

        case .prop(let p):
            if let initE = p.initializer { expr(initE) } else { emit(.pushVoid) }
            emit(.define(p.name))
            emit(.pop)

        case .funcDecl(let f):
            let idx = compileFunction(f, name: f.name)
            emit(.makeClosure(idx))
            emit(.define(f.name))
            emit(.pop)

        case .ifStmt(let c, let a, let b):
            expr(c)
            let toElse = emit(.jumpIfFalse(0))
            block(a)
            if let b = b {
                let toEnd = emit(.jump(0))
                patch(toElse, here())
                block(b)
                patch(toEnd, here())
            } else {
                patch(toElse, here())
            }

        case .ifLet(let name, let e, let a, let b):
            expr(e)
            emit(.dup)
            let toElse = emit(.jumpIfNil(0))
            emit(.store(name))
            emit(.pop)
            block(a)
            let toEnd = emit(.jump(0))
            patch(toElse, here())
            emit(.pop)
            if let b = b { block(b) }
            patch(toEnd, here())

        case .guardStmt(let c, let elseBody):
            expr(c)
            let toElse = emit(.jumpIfFalse(0))
            let toEnd = emit(.jump(0))
            patch(toElse, here())
            block(elseBody)
            patch(toEnd, here())

        case .guardLet(let name, let e, let elseBody):
            expr(e)
            emit(.dup)
            let toElse = emit(.jumpIfNil(0))
            emit(.store(name))
            emit(.pop)
            let toEnd = emit(.jump(0))
            patch(toElse, here())
            emit(.pop)
            block(elseBody)
            patch(toEnd, here())

        case .forIn(let name, let seq, let body):
            compileFor(names: [name], seq: seq, body: body)

        case .forInTuple(let names, let seq, let body):
            compileFor(names: names, seq: seq, body: body)

        case .whileStmt(let c, let body):
            let start = here()
            expr(c)
            let toEnd = emit(.jumpIfFalse(0))
            loops.append(LoopCtx())
            block(body)
            emit(.jump(start))
            let end = here()
            patch(toEnd, end)
            closeLoop(end: end, cont: start)

        case .repeatStmt(let body, let cond):
            let start = here()
            loops.append(LoopCtx())
            block(body)
            let cont = here()
            expr(cond)
            emit(.jumpIfTrue(start))
            let end = here()
            closeLoop(end: end, cont: cont)

        case .switchStmt(let subject, let cases):
            compileSwitch(subject, cases)

        case .doCatch(let body, let catches):
            compileDoCatch(body, catches)

        case .throwStmt(let e):
            expr(e)
            emit(.throwTop)

        case .deferStmt(let body):
            let idx = beginChunk(name: "<defer>", collecting: false)
            for s in body { stmt(s) }
            emit(.pushVoid)
            emit(.retVoid)
            endChunk()
            chunks[cur].deferred.append(idx)

        case .fallthroughStmt:
            let j = emit(.jump(0))
            if let sw = switches.last, !sw.fallthroughs.isEmpty {
                sw.fallthroughs[sw.fallthroughs.count - 1].append(j)
            }

        case .returnStmt(let e):
            if let e = e {
                expr(e)
                emit(.ret)
            } else {
                emit(.pushVoid)
                emit(.retVoid)
            }

        case .breakStmt:
            let j = emit(.jump(0))
            loops.last?.breaks.append(j)
            switches.last?.breaks.append(j)

        case .continueStmt:
            let j = emit(.jump(0))
            loops.last?.continues.append(j)

        case .tupleLet(let names, let e):
            expr(e)
            let tmp = hidden("t")
            emit(.define(tmp))
            emit(.pop)
            for (i, n) in names.enumerated() {
                emit(.load(tmp))
                emit(.loadMember("\(i)"))
                emit(.define(n))
                emit(.pop)
            }
        }
    }

    private func block(_ stmts: [Stmt]) {
        for s in stmts { stmt(s) }
    }

    private func closeLoop(end: Int, cont: Int) {
        guard let ctx = loops.popLast() else { return }
        for j in ctx.breaks { patch(j, end) }
        for j in ctx.continues { patch(j, cont) }
    }

    private func compileFor(names: [String], seq: Expr, body: [Stmt]) {
        let listVar = hidden("seq")
        let idxVar = hidden("i")

        expr(seq)
        emit(.callNamed("__iterate", 1, labelTable([nil])))
        emit(.define(listVar))
        emit(.pop)

        emit(.pushConst(constant(.int(0))))
        emit(.define(idxVar))
        emit(.pop)

        let start = here()
        emit(.load(idxVar))
        emit(.load(listVar))
        emit(.loadMember("count"))
        emit(.binary("<"))
        let toEnd = emit(.jumpIfFalse(0))

        emit(.load(listVar))
        emit(.load(idxVar))
        emit(.subscriptGet(1))

        if names.count == 1 {
            emit(.define(names[0]))
            emit(.pop)
        } else {
            let tmp = hidden("el")
            emit(.define(tmp))
            emit(.pop)
            for (i, n) in names.enumerated() {
                emit(.load(tmp))
                emit(.loadMember("\(i)"))
                emit(.define(n))
                emit(.pop)
            }
        }

        loops.append(LoopCtx())
        block(body)
        let cont = here()
        emit(.load(idxVar))
        emit(.pushConst(constant(.int(1))))
        emit(.binary("+"))
        emit(.store(idxVar))
        emit(.pop)
        emit(.jump(start))

        let end = here()
        patch(toEnd, end)
        closeLoop(end: end, cont: cont)
    }

    private func compileSwitch(_ subject: Expr, _ cases: [SwitchCase]) {
        expr(subject)

        let ctx = SwitchCtx()
        ctx.tableIndex = chunks[cur].switchTables.count
        chunks[cur].switchTables.append([])
        ctx.fallthroughs = Array(repeating: [], count: cases.count)

        emit(.switchDispatch(ctx.tableIndex))
        let noMatch = emit(.jump(0))
        switches.append(ctx)

        for (i, c) in cases.enumerated() {
            if i > 0 {
                for j in ctx.fallthroughs[i - 1] { patch(j, here()) }
            }
            ctx.armStarts.append(here())
            block(c.body)
            ctx.endJumps.append(emit(.jump(0)))
        }

        let end = here()
        patch(noMatch, end)

        var table: [SwitchArm] = []
        for (i, c) in cases.enumerated() {
            table.append(SwitchArm(patterns: c.patterns,
                                   target: ctx.armStarts[i],
                                   isDefault: c.isDefault))
        }
        chunks[cur].switchTables[ctx.tableIndex] = table

        for j in ctx.endJumps { patch(j, end) }
        for j in ctx.breaks { patch(j, end) }
        for (i, list) in ctx.fallthroughs.enumerated() {
            let target = i + 1 < ctx.armStarts.count ? ctx.armStarts[i + 1] : end
            for j in list { patch(j, target) }
        }

        _ = switches.popLast()
    }

    private func compileDoCatch(_ body: [Stmt], _ catches: [CatchClause]) {
        let handler = emit(.pushHandler(0))
        block(body)
        emit(.popHandler)
        let toEnd = emit(.jump(0))

        patch(handler, here())

        let tableIdx = chunks[cur].catchTables.count
        chunks[cur].catchTables.append([])
        emit(.catchDispatch(tableIdx))

        var arms: [CatchArm] = []
        var endJumps: [Int] = []
        for c in catches {
            arms.append(CatchArm(pattern: c.pattern, name: c.name, target: here()))
            block(c.body)
            endJumps.append(emit(.jump(0)))
        }
        chunks[cur].catchTables[tableIdx] = arms

        let end = here()
        patch(toEnd, end)
        for j in endJumps { patch(j, end) }
    }

    // MARK: - expressions

    private func expr(_ e: Expr) {
        switch e {
        case .intLit(let i): emit(.pushConst(constant(.int(i))))
        case .doubleLit(let d): emit(.pushConst(constant(.double(d))))
        case .boolLit(let b): emit(b ? .pushTrue : .pushFalse)
        case .nilLit: emit(.pushNil)
        case .stringLit(let s): emit(.pushConst(constant(.string(s))))
        case .ident(let n): emit(.load(n))
        case .selfExpr: emit(.loadSelf)
        case .implicitMember(let n): emit(.pushConst(constant(.implicit(n))))
        case .dollar(let i): emit(.loadDollar(i))

        case .binding(let inner):
            if case .ident(let n) = inner {
                emit(.loadBinding(n))
            } else {
                emit(.pushNil)
            }

        case .member(let b, let n):
            expr(b)
            emit(.loadMember(n))

        case .subscriptExpr(let b, let idx):
            expr(b)
            for i in idx { expr(i) }
            emit(.subscriptGet(idx.count))

        case .call(let callee, let args):
            let labels = args.map { $0.label }
            switch callee {
            case .ident(let name):
                for a in args { expr(a.value) }
                emit(.callNamed(name, args.count, labelTable(labels)))
            case .member(let b, let name):
                expr(b)
                for a in args { expr(a.value) }
                emit(.callMember(name, args.count, labelTable(labels)))
            default:
                expr(callee)
                for a in args { expr(a.value) }
                emit(.callValue(args.count))
            }

        case .closure(let cd):
            let idx = compileClosure(cd)
            emit(.makeClosure(idx))

        case .arrayLit(let items):
            for i in items { expr(i) }
            emit(.makeArray(items.count))

        case .tupleLit(let items):
            for i in items { expr(i) }
            emit(.makeTuple(items.count))

        case .dictLit(let pairs):
            for (k, v) in pairs {
                expr(k)
                expr(v)
            }
            emit(.makeDict(pairs.count))

        case .unary(let op, let x):
            expr(x)
            emit(.unary(op))

        case .binary(let op, let a, let b):
            compileBinary(op, a, b)

        case .ternary(let c, let a, let b):
            expr(c)
            let toElse = emit(.jumpIfFalse(0))
            expr(a)
            let toEnd = emit(.jump(0))
            patch(toElse, here())
            expr(b)
            patch(toEnd, here())

        case .assign(let target, let op, let rhs):
            compileAssign(target, op, rhs)

        case .forceUnwrap(let x):
            expr(x)
            emit(.forceUnwrap)

        case .tryOptional(let x):
            let handler = emit(.pushHandler(0))
            expr(x)
            emit(.popHandler)
            let toEnd = emit(.jump(0))
            patch(handler, here())
            emit(.pop)
            emit(.pushNil)
            patch(toEnd, here())

        case .tryForced(let x):
            let handler = emit(.pushHandler(0))
            expr(x)
            emit(.popHandler)
            let toEnd = emit(.jump(0))
            patch(handler, here())
            emit(.throwTop)
            patch(toEnd, here())

        case .literal(let v):
            emit(.pushConst(constant(v)))
        }
    }

    private func compileBinary(_ op: String, _ a: Expr, _ b: Expr) {
        switch op {
        case "&&":
            expr(a)
            emit(.dup)
            let toFalse = emit(.jumpIfFalse(0))
            emit(.pop)
            expr(b)
            let toEnd = emit(.jump(0))
            patch(toFalse, here())
            emit(.pop)
            emit(.pushFalse)
            patch(toEnd, here())

        case "||":
            expr(a)
            emit(.dup)
            let toEval = emit(.jumpIfFalse(0))
            let toEnd = emit(.jump(0))
            patch(toEval, here())
            emit(.pop)
            expr(b)
            patch(toEnd, here())

        case "??":
            expr(a)
            emit(.dup)
            let toNil = emit(.jumpIfNil(0))
            let toEnd = emit(.jump(0))
            patch(toNil, here())
            emit(.pop)
            expr(b)
            patch(toEnd, here())

        default:
            expr(a)
            expr(b)
            emit(.binary(op))
        }
    }

    private func compileAssign(_ target: Expr, _ op: String, _ rhs: Expr) {
        switch target {
        case .ident(let n):
            if op == "=" {
                expr(rhs)
                emit(.store(n))
            } else {
                emit(.load(n))
                expr(rhs)
                emit(.binary(String(op.dropLast())))
                emit(.store(n))
            }

        case .member(let b, let n):
            expr(b)
            expr(rhs)
            emit(.storeMember(n))

        case .subscriptExpr(let b, let idx):
            if case .ident(let n) = b {
                for i in idx { expr(i) }
                expr(rhs)
                emit(.storeSubscriptNamed(n, idx.count))
            } else if case .member(let owner, let field) = b {
                expr(owner)
                for i in idx { expr(i) }
                expr(rhs)
                emit(.storeSubscriptMember(field, idx.count))
            } else {
                expr(rhs)
                emit(.pop)
                emit(.pushVoid)
            }

        default:
            expr(rhs)
            emit(.pop)
            emit(.pushVoid)
        }
    }
}
