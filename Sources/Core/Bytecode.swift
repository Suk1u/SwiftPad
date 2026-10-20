import Foundation

// MARK: - Instruction set
//
// A stack machine. Everything structural — patterns, builtin methods, view
// construction — is dispatched back into the runtime as a native call, which keeps
// the opcode set small and the semantics identical to the tree-walker.

enum Op {
    // constants
    case pushConst(Int)
    case pushNil
    case pushTrue
    case pushFalse
    case pushVoid

    // variables & members
    case load(String)
    case loadSelf
    case loadMember(String)
    case loadDollar(Int)
    case loadBinding(String)

    case store(String)
    case define(String)
    case storeMember(String)
    case storeSubscriptNamed(String, Int)
    case storeSubscriptMember(String, Int)
    case subscriptGet(Int)

    // stack shuffling
    case pop
    case dup

    // operators
    case binary(String)
    case unary(String)

    // control flow
    case jump(Int)
    case jumpIfFalse(Int)
    case jumpIfTrue(Int)
    case jumpIfNil(Int)

    // aggregates
    case makeArray(Int)
    case makeTuple(Int)
    case makeDict(Int)

    // calls
    case makeClosure(Int)
    case callNamed(String, Int, Int)     // name, argCount, labelTableIndex
    case callMember(String, Int, Int)    // member, argCount, labelTableIndex
    case callValue(Int)                  // callee sits below the args
    case ret
    case retVoid

    // errors
    case pushHandler(Int)
    case popHandler
    case throwTop
    case tryOptional(Int)
    case tryForced

    // effects
    case awaitTop
    case forceUnwrap
    case fallthroughJump

    // native dispatch (side tables keep patterns out of the instruction stream)
    case switchDispatch(Int)
    case catchDispatch(Int)
}

// MARK: - Chunk

struct Chunk {
    var name: String = ""
    var ops: [Op] = []
    var consts: [Value] = []
    var argLabels: [[String?]] = []
    var switchTables: [[SwitchArm]] = []
    var catchTables: [[CatchArm]] = []

    var params: [Param] = []
    var capturesEnv: Bool = true
    var collectsValues: Bool = false
    var isViewFunction: Bool = false

    /// Chunks for `defer` blocks, run in reverse on frame exit.
    var deferred: [Int] = []
}

struct SwitchArm {
    let patterns: [Pattern]
    let target: Int
    let isDefault: Bool
}

struct CatchArm {
    let pattern: Pattern?
    let name: String?
    let target: Int
}

// MARK: - Frame

struct Frame {
    let chunkIndex: Int
    var ip: Int
    var env: Env
    let stackBase: Int
    var handlers: [(ip: Int, stackDepth: Int)]
    var deferred: [Int]

    init(chunkIndex: Int, env: Env, stackBase: Int) {
        self.chunkIndex = chunkIndex
        self.ip = 0
        self.env = env
        self.stackBase = stackBase
        self.handlers = []
        self.deferred = []
    }
}

enum Engine {
    case tree
    case vm
}

enum VMError: Error, CustomStringConvertible {
    case stepLimit
    case badJump(Int)
    case stackUnderflow
    case noChunk(Int)

    var description: String {
        switch self {
        case .stepLimit: return "execution limit reached — check for an infinite loop"
        case .badJump(let ip): return "bytecode jump out of range (\(ip))"
        case .stackUnderflow: return "bytecode stack underflow"
        case .noChunk(let i): return "missing code block #\(i)"
        }
    }
}
