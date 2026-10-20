import Foundation

// MARK: - Parameters & functions

struct Param {
    let label: String?
    let name: String
    let typeName: String?
    let defaultValue: Expr?
}

struct FuncDecl {
    let name: String
    let params: [Param]
    let returnType: String?
    let body: [Stmt]
    let isStatic: Bool
    var isAsync: Bool = false

    var returnsView: Bool {
        guard let r = returnType else { return false }
        return r.contains("View")
    }
}

struct PropertyDecl {
    let name: String
    let isVar: Bool
    let typeName: String?
    let wrappers: [String]
    let initializer: Expr?
    let computedBody: [Stmt]?
    let isStatic: Bool
    var willSet: [Stmt]? = nil
    var didSet: [Stmt]? = nil
    var isLazy: Bool = false
}

// MARK: - Protocols

struct ProtocolDecl {
    let name: String
    var inherits: [String] = []
    var requirements: [String] = []
}

// MARK: - Types

struct TypeDecl {
    let name: String
    let isClass: Bool
    var properties: [PropertyDecl] = []
    var methods: [String: FuncDecl] = [:]
    var staticMethods: [String: FuncDecl] = [:]
    var computed: [String: FuncDecl] = [:]
    var initializer: FuncDecl? = nil
    var subscriptGet: FuncDecl? = nil
    var subscriptSet: FuncDecl? = nil
    var order: [String] = []
    var isMain: Bool = false
    var conformances: [String] = []
}

struct EnumCaseDecl {
    let name: String
    let assocLabels: [String?]
    let assocTypes: [String]
    let rawValue: Expr?
}

struct EnumDecl {
    let name: String
    var rawType: String? = nil
    var cases: [EnumCaseDecl] = []
    var methods: [String: FuncDecl] = [:]
    var computed: [String: FuncDecl] = [:]
    var staticMethods: [String: FuncDecl] = [:]
    var conformances: [String] = []
}

struct ExtensionDecl {
    let typeName: String
    var properties: [PropertyDecl] = []
    var methods: [String: FuncDecl] = [:]
    var computed: [String: FuncDecl] = [:]
    var staticMethods: [String: FuncDecl] = [:]
    var subscriptGet: FuncDecl? = nil
    var subscriptSet: FuncDecl? = nil
    var conformances: [String] = []
}

enum Decl {
    case typeDecl(TypeDecl)
    case enumDecl(EnumDecl)
    case funcDecl(FuncDecl)
    case prop(PropertyDecl)
    case importDecl(String)
    case ext(ExtensionDecl)
    case protocolDecl(ProtocolDecl)
}

struct Program {
    let decls: [Decl]
    let topLevel: [Stmt]
}

// MARK: - Expressions

struct Arg {
    let label: String?
    let value: Expr
}

struct ClosureDef {
    let params: [Param]
    let body: [Stmt]
    var isAsync: Bool = false
}

indirect enum Expr {
    case intLit(Int)
    case doubleLit(Double)
    case stringLit(String)
    case boolLit(Bool)
    case nilLit
    case ident(String)
    case selfExpr
    case implicitMember(String)
    case dollar(Int)
    case binding(Expr)
    case member(Expr, String)
    case subscriptExpr(Expr, [Expr])
    case call(Expr, [Arg])
    case closure(ClosureDef)
    case arrayLit([Expr])
    case dictLit([(Expr, Expr)])
    case tupleLit([Expr])
    case unary(String, Expr)
    case binary(String, Expr, Expr)
    case ternary(Expr, Expr, Expr)
    case assign(Expr, String, Expr)
    case forceUnwrap(Expr)
    case tryOptional(Expr)
    case tryForced(Expr)
    case literal(Value)          // pre-evaluated; lets the VM reuse the native call surface
}

// MARK: - Patterns

indirect enum Pattern {
    case wildcard
    case literal(Expr)
    case binding(String)
    case enumCase(String?, String, [Pattern])   // typeName?, caseName, subpatterns
    case tuple([Pattern])
    case range(Expr, Expr, Bool)
}

struct SwitchCase {
    let patterns: [Pattern]
    let body: [Stmt]
    let isDefault: Bool
}

struct CatchClause {
    let pattern: Pattern?
    let name: String?
    let body: [Stmt]
}

// MARK: - Statements

indirect enum Stmt {
    case expr(Expr)
    case prop(PropertyDecl)
    case funcDecl(FuncDecl)
    case ifStmt(Expr, [Stmt], [Stmt]?)
    case ifLet(String, Expr, [Stmt], [Stmt]?)
    case guardStmt(Expr, [Stmt])
    case guardLet(String, Expr, [Stmt])
    case forIn(String, Expr, [Stmt])
    case forInTuple([String], Expr, [Stmt])
    case whileStmt(Expr, [Stmt])
    case repeatStmt([Stmt], Expr)
    case switchStmt(Expr, [SwitchCase])
    case doCatch([Stmt], [CatchClause])
    case throwStmt(Expr)
    case deferStmt([Stmt])
    case fallthroughStmt
    case returnStmt(Expr?)
    case breakStmt
    case continueStmt
    case tupleLet([String], Expr)
}

enum Flow {
    case normal(Value?)
    case ret(Value?)
    case breakLoop
    case continueLoop
    case fallthroughFlow
}

/// Thrown by `throw` and caught by `do`/`catch`. Distinct from RuntimeError so user
/// code can never swallow an interpreter bug.
struct ThrownError: Error, CustomStringConvertible {
    let value: Value
    var description: String { "uncaught error: \(value.str())" }
}
