import Foundation

enum StackAxis {
    case vertical
    case horizontal
    case depth
}

struct Mod {
    let name: String
    let args: [Value]
    let labels: [String?]
}

struct ViewNode {
    var base: Base
    var mods: [Mod] = []

    static var empty: ViewNode { ViewNode(base: .empty) }

    static func text(_ s: String) -> ViewNode { ViewNode(base: .text(s)) }

    static func stack(_ axis: StackAxis, _ children: [ViewNode]) -> ViewNode {
        ViewNode(base: .stack(axis, "center", nil, children))
    }

    var flattened: [ViewNode] {
        if case .group(let kids) = base { return kids }
        return [self]
    }

    var isEmptyNode: Bool {
        if case .empty = base { return true }
        return false
    }
}

indirect enum Base {
    case empty
    case text(String)
    case image(String)
    case shape(String, Double)
    case colorFill(String)
    case spacer
    case divider
    case progress(Double?)
    case stack(StackAxis, String, Double?, [ViewNode])
    case scroll([ViewNode])
    case list([ViewNode])
    case nav(String?, [ViewNode])
    case group([ViewNode])
    case button([ViewNode], () -> Void)
    case toggle(String, StateBox)
    case textField(String, StateBox)
    case slider(StateBox, Double, Double)
    case stepper(String, StateBox)
}
