import Foundation

// MARK: - Reactive state

final class StateBox {
    private var _value: Value

    /// Fired for writes that come from rendered controls (Toggle / TextField / Slider),
    /// so `didSet` observers see UI-driven changes too. The interpreter's own write path
    /// uses `setSilent` and runs the observers itself, so nothing fires twice.
    var didSetHook: ((Value, Value) -> Void)?

    init(_ v: Value) { _value = v }

    var value: Value {
        get { _value }
        set {
            let old = _value
            _value = newValue
            didSetHook?(old, newValue)
        }
    }

    func setSilent(_ v: Value) { _value = v }
}

final class StateStore {
    static let shared = StateStore()
    private var boxes: [String: StateBox] = [:]
    private init() {}

    func box(_ key: String, _ initial: Value) -> StateBox {
        if let b = boxes[key] { return b }
        let b = StateBox(initial)
        boxes[key] = b
        return b
    }

    func reset() { boxes.removeAll() }
    var count: Int { boxes.count }
}

// MARK: - Object instances

struct Observers {
    let willSet: [Stmt]?
    let didSet: [Stmt]?
}

final class ObjectInstance {
    let typeName: String
    let isClass: Bool
    var fields: [String: Value] = [:]
    var stateBoxes: [String: StateBox] = [:]
    var methods: [String: FuncDecl] = [:]
    var computed: [String: FuncDecl] = [:]
    var observers: [String: Observers] = [:]

    init(_ typeName: String, isClass: Bool = false) {
        self.typeName = typeName
        self.isClass = isClass
    }

    func shallowCopy() -> ObjectInstance {
        let copy = ObjectInstance(typeName, isClass: isClass)
        copy.fields = fields
        copy.stateBoxes = stateBoxes
        copy.methods = methods
        copy.computed = computed
        copy.observers = observers
        return copy
    }
}

// MARK: - Enum values

final class EnumValue {
    let typeName: String
    let caseName: String
    let assoc: [Value]
    var raw: Value?

    init(typeName: String, caseName: String, assoc: [Value] = [], raw: Value? = nil) {
        self.typeName = typeName
        self.caseName = caseName
        self.assoc = assoc
        self.raw = raw
    }
}

// MARK: - Values

indirect enum Value {
    case void
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([Value])
    case dict([String: Value])
    case set([Value])
    case tuple([Value])
    case object(ObjectInstance)
    case enumValue(EnumValue)
    case function(FuncDecl, Env)
    case closure(ClosureDef, Env)
    case vmClosure(Int, Env)
    case view(ViewNode)
    case binding(StateBox)
    case range(Int, Int, Bool)
    case namespace(String)
    case color(String)
    case colorAlpha(String, Double)
    case fontSpec(String)
    case implicit(String)
    case nilValue

    var isNil: Bool {
        if case .nilValue = self { return true }
        return false
    }

    /// Structs get value semantics on assignment; classes keep reference semantics.
    var copyForStorage: Value {
        if case .object(let o) = self, !o.isClass {
            return .object(o.shallowCopy())
        }
        if case .array(let a) = self {
            return .array(a.map { $0.copyForStorage })
        }
        if case .set(let s) = self {
            return .set(s.map { $0.copyForStorage })
        }
        if case .dict(let d) = self {
            var out: [String: Value] = [:]
            for (k, v) in d { out[k] = v.copyForStorage }
            return .dict(out)
        }
        return self
    }

    func asBool() -> Bool {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .nilValue: return false
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .set(let s): return !s.isEmpty
        default: return true
        }
    }

    func asDouble() -> Double {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s) ?? 0
        default: return 0
        }
    }

    func asInt() -> Int {
        switch self {
        case .int(let i): return i
        default: return Int(asDouble())
        }
    }

    func str() -> String {
        switch self {
        case .void: return ""
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d):
            if d == d.rounded() && abs(d) < 1e15 {
                return String(Int(d))
            }
            var s = String(format: "%.6f", d)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        case .string(let s): return s
        case .array(let a): return "[" + a.map { $0.str() }.joined(separator: ", ") + "]"
        case .set(let s): return "Set([" + s.map { $0.str() }.joined(separator: ", ") + "])"
        case .dict(let d):
            let body = d.keys.sorted().map { "\($0): \(d[$0]!.str())" }.joined(separator: ", ")
            return "[" + body + "]"
        case .tuple(let t):
            if t.count == 1 { return "(\(t[0].str()),)" }
            return "(" + t.map { $0.str() }.joined(separator: ", ") + ")"
        case .object(let o): return o.typeName
        case .enumValue(let e):
            if e.assoc.isEmpty { return e.caseName }
            return e.caseName + "(" + e.assoc.map { $0.str() }.joined(separator: ", ") + ")"
        case .function, .closure, .vmClosure: return "<function>"
        case .view: return "<View>"
        case .binding: return "<Binding>"
        case .range(let a, let b, let closed): return closed ? "\(a)...\(b)" : "\(a)..<\(b)"
        case .namespace(let n): return n
        case .color(let n): return n
        case .colorAlpha(let n, let a): return "\(n)@\(a)"
        case .fontSpec(let s): return s
        case .implicit(let n): return n
        case .nilValue: return "nil"
        }
    }

    var typeLabel: String {
        switch self {
        case .void: return "Void"
        case .bool: return "Bool"
        case .int: return "Int"
        case .double: return "Double"
        case .string: return "String"
        case .array: return "Array"
        case .dict: return "Dictionary"
        case .set: return "Set"
        case .tuple: return "Tuple"
        case .object(let o): return o.typeName
        case .enumValue(let e): return e.typeName
        case .function, .closure, .vmClosure: return "Function"
        case .view: return "View"
        case .binding: return "Binding"
        case .range: return "Range"
        case .nilValue: return "nil"
        default: return "Value"
        }
    }
}
