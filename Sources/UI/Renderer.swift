// iOS 26 target: rendered content uses native SwiftUI controls and materials only.
import SwiftUI
import UIKit
import Foundation

struct Renderer {
    let invalidate: () -> Void
    let invoke: (Value) -> Void

    // MARK: - Node walk

    func view(_ node: ViewNode) -> AnyView {
        var mods = node.mods

        if case .shape(let kind, let radius) = node.base {
            let fillMod = mods.first { $0.name == "fill" }
            let strokeMod = mods.first { $0.name == "stroke" }
            mods.removeAll { $0.name == "fill" || $0.name == "stroke" }

            let fill = fillMod?.args.first.map { color($0) } ?? Color.gray
            var v = filledShape(kind, radius, fill)

            if let s = strokeMod, let first = s.args.first {
                let width = s.args.count > 1 ? s.args[1].asDouble() : 1
                v = strokedShape(kind, radius, color(first), CGFloat(width))
            }
            for m in mods { v = apply(v, m) }
            return v
        }

        if case .nav(_, let kids) = node.base {
            var title: String? = nil
            if let idx = mods.firstIndex(where: { $0.name == "navigationTitle" }) {
                title = mods[idx].args.first?.str()
                mods.remove(at: idx)
            }
            var v = navView(title, kids)
            for m in mods { v = apply(v, m) }
            return v
        }

        var v = base(node.base)
        for m in mods { v = apply(v, m) }
        return v
    }

    private func base(_ b: Base) -> AnyView {
        switch b {
        case .empty:
            return AnyView(EmptyView())

        case .text(let s):
            return AnyView(Text(s))

        case .image(let name):
            if UIImage(systemName: name) != nil {
                return AnyView(Image(systemName: name))
            }
            return AnyView(Image(systemName: "questionmark.square.dashed"))

        case .shape(let kind, let radius):
            return filledShape(kind, radius, .gray)

        case .colorFill(let name):
            return AnyView(colorByName(name))

        case .spacer:
            return AnyView(Spacer())

        case .divider:
            return AnyView(Divider())

        case .progress(let v):
            if let v = v {
                return AnyView(ProgressView(value: v))
            }
            return AnyView(ProgressView())

        case .stack(let axis, let align, let spacing, let kids):
            let sp = spacing.map { CGFloat($0) }
            switch axis {
            case .vertical:
                return AnyView(VStack(alignment: hAlign(align), spacing: sp) {
                    ForEach(0..<kids.count, id: \.self) { i in self.view(kids[i]) }
                })
            case .horizontal:
                return AnyView(HStack(alignment: vAlign(align), spacing: sp) {
                    ForEach(0..<kids.count, id: \.self) { i in self.view(kids[i]) }
                })
            case .depth:
                return AnyView(ZStack(alignment: alignment(align)) {
                    ForEach(0..<kids.count, id: \.self) { i in self.view(kids[i]) }
                })
            }

        case .scroll(let kids):
            return AnyView(ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<kids.count, id: \.self) { i in self.view(kids[i]) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            })

        case .list(let kids):
            return AnyView(
                AnyView(List {
                    ForEach(0..<kids.count, id: \.self) { i in self.view(kids[i]) }
                })
                .frame(minHeight: CGFloat(max(120, kids.count * 46)))
            )

        case .nav(let title, let kids):
            return navView(title, kids)

        case .group(let kids):
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<kids.count, id: \.self) { i in self.view(kids[i]) }
            })

        case .button(let label, let action):
            let accessibleLabel = plainText(label).isEmpty ? "Button" : plainText(label)
            return AnyView(Button(action: {
                action()
                self.invalidate()
            }) {
                if label.isEmpty {
                    Text("Button")
                } else {
                    HStack(spacing: 4) {
                        ForEach(0..<label.count, id: \.self) { i in self.view(label[i]) }
                    }
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(accessibleLabel))

        case .toggle(let label, let box):
            return AnyView(Toggle(isOn: Binding(
                get: { box.value.asBool() },
                set: { nv in
                    box.value = .bool(nv)
                    self.invalidate()
                }
            )) {
                Text(label)
            }
            .frame(minHeight: 44)
            .accessibilityLabel(label.isEmpty ? "Toggle" : label)
            .accessibilityValue(box.value.asBool() ? "On" : "Off"))

        case .textField(let placeholder, let box, let secure):
            return AnyView(InterpretedTextField(
                placeholder: placeholder,
                box: box,
                secure: secure,
                onCommit: self.invalidate
            ))

        case .slider(let box, let lo, let hi):
            return AnyView(Slider(value: Binding(
                get: { min(max(box.value.asDouble(), lo), hi) },
                set: { nv in box.value = .double(nv) }
            ), in: lo...hi, onEditingChanged: { editing in
                if !editing { self.invalidate() }
            })
            .frame(minHeight: 44)
            .accessibilityLabel("Slider")
            .accessibilityValue(box.value.str()))

        case .stepper(let label, let box):
            return AnyView(Stepper(value: Binding(
                get: { box.value.asDouble() },
                set: { nv in
                    if case .int = box.value {
                        box.value = .int(Int(nv))
                    } else {
                        box.value = .double(nv)
                    }
                    self.invalidate()
                }
            ), in: 0...100, step: 1) {
                Text(label)
            }
            .frame(minHeight: 44)
            .accessibilityLabel(label.isEmpty ? "Stepper" : label)
            .accessibilityValue(box.value.str()))
        }
    }

    private func navView(_ title: String?, _ kids: [ViewNode]) -> AnyView {
        AnyView(NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<kids.count, id: \.self) { i in self.view(kids[i]) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(title ?? "")
            .navigationBarTitleDisplayMode(.inline)
        })
    }

    private func plainText(_ nodes: [ViewNode]) -> String {
        nodes.map { node in
            switch node.base {
            case .text(let value):
                return value
            case .image(let name):
                return name
            case .stack(_, _, _, let children),
                 .scroll(let children),
                 .list(let children),
                 .nav(_, let children),
                 .group(let children):
                return plainText(children)
            default:
                return ""
            }
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Shapes

    private func filledShape(_ kind: String, _ radius: Double, _ fill: Color) -> AnyView {
        switch kind {
        case "Circle": return AnyView(Circle().fill(fill))
        case "Capsule": return AnyView(Capsule().fill(fill))
        case "RoundedRectangle":
            return AnyView(RoundedRectangle(cornerRadius: CGFloat(radius)).fill(fill))
        default: return AnyView(Rectangle().fill(fill))
        }
    }

    private func strokedShape(_ kind: String, _ radius: Double, _ c: Color, _ width: CGFloat) -> AnyView {
        switch kind {
        case "Circle": return AnyView(Circle().stroke(c, lineWidth: width))
        case "Capsule": return AnyView(Capsule().stroke(c, lineWidth: width))
        case "RoundedRectangle":
            return AnyView(RoundedRectangle(cornerRadius: CGFloat(radius)).stroke(c, lineWidth: width))
        default: return AnyView(Rectangle().stroke(c, lineWidth: width))
        }
    }

    // MARK: - Modifiers

    private func apply(_ v: AnyView, _ m: Mod) -> AnyView {
        func arg(_ i: Int, _ def: Double = 0) -> Double {
            i < m.args.count ? m.args[i].asDouble() : def
        }
        func argColor(_ i: Int) -> Color {
            i < m.args.count ? color(m.args[i]) : .gray
        }
        func argView(_ i: Int) -> AnyView? {
            guard i < m.args.count, case .view(let n) = m.args[i] else { return nil }
            return view(n)
        }
        func argString(_ i: Int) -> String {
            i < m.args.count ? m.args[i].str() : ""
        }

        switch m.name {
        case "padding":
            if m.args.isEmpty { return AnyView(v.padding()) }
            if let e = edgeOf(m.args[0]) {
                return AnyView(v.padding(e, CGFloat(arg(1, 0))))
            }
            return AnyView(v.padding(CGFloat(arg(0, 0))))

        case "frame":
            var w: CGFloat? = nil
            var h: CGFloat? = nil
            var mw: CGFloat? = nil
            var mh: CGFloat? = nil
            var minW: CGFloat? = nil
            var minH: CGFloat? = nil
            var align = Alignment.center
            for (i, a) in m.args.enumerated() {
                let label = i < m.labels.count ? m.labels[i] : nil
                let d = dim(a)
                switch label {
                case "width": w = d
                case "height": h = d
                case "maxWidth": mw = d
                case "maxHeight": mh = d
                case "minWidth": minW = d
                case "minHeight": minH = d
                case "alignment": align = alignment(a.str())
                default: break
                }
            }
            var out = AnyView(v.frame(minWidth: minW, maxWidth: mw,
                                      minHeight: minH, maxHeight: mh,
                                      alignment: align))
            if w != nil || h != nil {
                out = AnyView(out.frame(width: w, height: h))
            }
            return out

        case "foregroundColor", "foregroundStyle":
            return AnyView(v.foregroundColor(argColor(0)))

        case "background":
            if let sub = argView(0) { return AnyView(v.background(sub)) }
            return AnyView(v.background(argColor(0)))

        case "overlay":
            if let sub = argView(0) { return AnyView(v.overlay(sub)) }
            return v

        case "cornerRadius":
            return AnyView(v.cornerRadius(CGFloat(arg(0, 8))))

        case "font":
            return AnyView(v.font(fontOf(m.args.first ?? .implicit("body"))))

        case "bold":
            return AnyView(v.fontWeight(.bold))

        case "fontWeight":
            return AnyView(v.fontWeight(weightOf(argString(0))))

        case "italic":
            return AnyView(v.italic())

        case "opacity":
            return AnyView(v.opacity(arg(0, 1)))

        case "shadow":
            return AnyView(v.shadow(radius: CGFloat(arg(0, 4))))

        case "offset":
            var x = 0.0
            var y = 0.0
            for (i, a) in m.args.enumerated() {
                let label = i < m.labels.count ? m.labels[i] : nil
                if label == "x" { x = a.asDouble() }
                if label == "y" { y = a.asDouble() }
            }
            if m.args.count == 2, m.labels.allSatisfy({ $0 == nil }) {
                x = m.args[0].asDouble()
                y = m.args[1].asDouble()
            }
            return AnyView(v.offset(x: CGFloat(x), y: CGFloat(y)))

        case "scaleEffect":
            return AnyView(v.scaleEffect(CGFloat(arg(0, 1))))

        case "rotationEffect":
            return AnyView(v.rotationEffect(.degrees(arg(0, 0))))

        case "blur":
            return AnyView(v.blur(radius: CGFloat(arg(0, 0))))

        case "clipShape":
            if let n = implicitName(m.args.first) {
                if n == "Circle" { return AnyView(v.clipShape(Circle())) }
                if n == "Capsule" { return AnyView(v.clipShape(Capsule())) }
            }
            return AnyView(v.clipShape(RoundedRectangle(cornerRadius: CGFloat(arg(0, 8)))))

        case "lineLimit":
            return AnyView(v.lineLimit(Int(arg(0, 1))))

        case "minimumScaleFactor":
            return AnyView(v.minimumScaleFactor(CGFloat(arg(0, 1))))

        case "tracking", "kerning":
            return AnyView(v.tracking(CGFloat(arg(0, 0))))

        case "multilineTextAlignment":
            let n = implicitName(m.args.first) ?? "leading"
            let a: TextAlignment = n == "center" ? .center : (n == "trailing" ? .trailing : .leading)
            return AnyView(v.multilineTextAlignment(a))

        case "aspectRatio":
            return AnyView(v.aspectRatio(contentMode: .fit))

        case "fixedSize":
            return AnyView(v.fixedSize())

        case "hidden":
            return AnyView(v.opacity(0))

        case "accentColor", "tint":
            return AnyView(v.accentColor(argColor(0)))

        case "disabled":
            return AnyView(v.disabled(true))

        case "border":
            let c = argColor(0)
            let width = CGFloat(arg(1, 1))
            return AnyView(v.overlay(
                RoundedRectangle(cornerRadius: CGFloat(arg(2, 8)))
                    .stroke(c, lineWidth: width)
            ))

        case "navigationTitle":
            return AnyView(v.navigationTitle(argString(0)))

        case "onTapGesture":
            if let closure = m.args.first {
                return AnyView(v.onTapGesture {
                    self.invoke(closure)
                    self.invalidate()
                })
            }
            return v

        case "resizable", "label", "fill", "stroke", "listRowSeparator",
             "textCase", "saturation", "brightness", "zIndex", "clipped",
             "keyboardType", "autocorrectionDisabled", "textInputAutocapitalization",
             "scrollContentBackground", "toolbar", "listStyle", "buttonStyle",
             "textFieldStyle", "labelsHidden", "truncationMode", "contentShape",
             "allowsHitTesting", "ignoresSafeArea", "safeAreaInset", "onAppear",
             "onDisappear", "animation", "transition", "help", "tag", "id":
            return v

        default:
            return v
        }
    }

    // MARK: - Value -> SwiftUI primitives

    private func implicitName(_ v: Value?) -> String? {
        guard let v = v else { return nil }
        switch v {
        case .implicit(let n): return n
        case .string(let s): return s
        case .color(let n): return n
        case .namespace(let n): return n
        default: return nil
        }
    }

    private func dim(_ v: Value) -> CGFloat {
        if case .implicit(let n) = v {
            if n == "infinity" { return .infinity }
            return 0
        }
        return CGFloat(v.asDouble())
    }

    func color(_ v: Value) -> Color {
        switch v {
        case .color(let n): return colorByName(n)
        case .colorAlpha(let n, let a): return colorByName(n).opacity(a)
        case .implicit(let n): return colorByName(n)
        case .string(let n): return colorByName(n)
        default: return .gray
        }
    }

    func colorByName(_ name: String) -> Color {
        switch name.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        case "gray", "grey": return .gray
        case "black": return .black
        case "white": return .white
        case "clear": return .clear
        case "primary": return .primary
        case "secondary": return .secondary
        case "accentcolor": return .accentColor
        default:
            if name.hasPrefix("#") { return Color(hex: name) }
            return .gray
        }
    }

    func fontOf(_ v: Value) -> Font {
        var spec = "body"
        switch v {
        case .fontSpec(let s): spec = s
        case .implicit(let s): spec = s
        case .string(let s): spec = s
        default: break
        }

        if spec.hasPrefix("system|") {
            let parts = spec.split(separator: "|").map(String.init)
            let size = parts.count > 1 ? (Double(parts[1]) ?? 17) : 17
            let weight = parts.count > 2 ? parts[2] : "regular"
            return .system(size: CGFloat(size), weight: weightOf(weight))
        }

        switch spec {
        case "largeTitle": return .largeTitle
        case "title": return .title
        case "title2": return .title2
        case "title3": return .title3
        case "headline": return .headline
        case "subheadline": return .subheadline
        case "body": return .body
        case "callout": return .callout
        case "footnote": return .footnote
        case "caption": return .caption
        case "caption2": return .caption2
        case "monospaced": return .system(.body, design: .monospaced)
        default: return .body
        }
    }

    private func weightOf(_ s: String) -> Font.Weight {
        switch s {
        case "ultraLight": return .ultraLight
        case "thin": return .thin
        case "light": return .light
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        case "black": return .black
        default: return .regular
        }
    }

    private func edgeOf(_ v: Value) -> Edge.Set? {
        guard let n = implicitName(v) else { return nil }
        switch n {
        case "horizontal": return .horizontal
        case "vertical": return .vertical
        case "top": return .top
        case "bottom": return .bottom
        case "leading": return .leading
        case "trailing": return .trailing
        case "all": return .all
        default: return nil
        }
    }

    private func hAlign(_ s: String) -> HorizontalAlignment {
        switch s {
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .center
        }
    }

    private func vAlign(_ s: String) -> VerticalAlignment {
        switch s {
        case "top": return .top
        case "bottom": return .bottom
        case "firstTextBaseline": return .firstTextBaseline
        default: return .center
        }
    }

    private func alignment(_ s: String) -> Alignment {
        switch s {
        case "topLeading": return .topLeading
        case "topTrailing": return .topTrailing
        case "bottomLeading": return .bottomLeading
        case "bottomTrailing": return .bottomTrailing
        case "top": return .top
        case "bottom": return .bottom
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .center
        }
    }
}

// MARK: - Hex colors

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b, a: Double
        switch s.count {
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        default:
            r = 0.5; g = 0.5; b = 0.5; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

/// Keeps field focus while the interpreted state changes, and re-evaluates the
/// user's body only on submit or focus loss instead of after every keystroke.
private struct InterpretedTextField: View {
    let placeholder: String
    let box: StateBox
    let secure: Bool
    let onCommit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        field
            .focused($focused)
            .frame(minHeight: 44)
            .onSubmit(onCommit)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { onCommit() }
            }
            .accessibilityLabel(placeholder.isEmpty
                                ? (secure ? "Secure text field" : "Text field")
                                : placeholder)
            .accessibilityValue(secure ? "Protected" : box.value.str())
    }

    @ViewBuilder
    private var field: some View {
        let binding = Binding(
            get: { box.value.str() },
            set: { box.value = .string($0) }
        )
        if secure {
            SecureField(placeholder, text: binding)
        } else {
            TextField(placeholder, text: binding)
        }
    }
}
