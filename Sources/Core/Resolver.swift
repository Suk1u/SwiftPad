import Foundation

/// A semantic problem found before execution. This is the compile phase the interpreter
/// didn't have: declarations are already parsed, so they can be cross-checked without
/// running anything.
struct Diagnostic {
    let message: String
}

enum Resolver {

    static func check(types: [String: TypeDecl],
                      enums: [String: EnumDecl],
                      protocols: [String: ProtocolDecl]) -> [Diagnostic] {
        var out: [Diagnostic] = []

        for name in types.keys.sorted() {
            guard let td = types[name] else { continue }
            out += checkConformances(typeName: name,
                                     declared: td.conformances,
                                     members: membersOf(td),
                                     protocols: protocols)
        }

        for name in enums.keys.sorted() {
            guard let ed = enums[name] else { continue }
            var members = Set<String>()
            for c in ed.cases { members.insert(c.name) }
            for k in ed.methods.keys { members.insert(k) }
            for k in ed.computed.keys { members.insert(k) }
            for k in ed.staticMethods.keys { members.insert(k) }
            out += checkConformances(typeName: name,
                                     declared: ed.conformances,
                                     members: members,
                                     protocols: protocols)
        }

        return out
    }

    private static func membersOf(_ td: TypeDecl) -> Set<String> {
        var members = Set<String>()
        for p in td.properties { members.insert(p.name) }
        for k in td.methods.keys { members.insert(k) }
        for k in td.computed.keys { members.insert(k) }
        for k in td.staticMethods.keys { members.insert(k) }
        if td.initializer != nil { members.insert("init") }
        if td.subscriptGet != nil || td.subscriptSet != nil { members.insert("subscript") }
        return members
    }

    /// Walks the conformance list plus inherited protocols, checking that every
    /// requirement exists on the type. Protocols the interpreter doesn't know about
    /// (`View`, `Equatable`, …) are ignored — they're framework-side.
    private static func checkConformances(typeName: String,
                                          declared: [String],
                                          members: Set<String>,
                                          protocols: [String: ProtocolDecl]) -> [Diagnostic] {
        var out: [Diagnostic] = []
        var seen: Set<String> = []
        var queue = declared

        while let protoName = queue.popLast() {
            if seen.contains(protoName) { continue }
            seen.insert(protoName)
            guard let pd = protocols[protoName] else { continue }
            queue.append(contentsOf: pd.inherits)

            for req in pd.requirements where !members.contains(req) {
                out.append(Diagnostic(
                    message: "'\(typeName)' does not conform to '\(protoName)' — missing '\(req)'"))
            }
        }
        return out
    }
}
