// iOS 26 target: UIKit is used only for the native text-editing surface.
import SwiftUI
import UIKit

// MARK: - Palette
//
// Every colour is a dynamic provider with an explicit light and dark variant, as the
// iOS 26 HIG requires for anything drawn behind Liquid Glass.

enum Palette {
    static func dynamic(_ light: UIColor, _ dark: UIColor) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }

    static let bg = dynamic(
        UIColor(white: 0.98, alpha: 1),
        UIColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1))

    static let text = dynamic(
        UIColor(white: 0.12, alpha: 1),
        UIColor(red: 0.88, green: 0.90, blue: 0.93, alpha: 1))

    static let keyword = dynamic(
        UIColor(red: 0.68, green: 0.11, blue: 0.31, alpha: 1),
        UIColor(red: 0.98, green: 0.45, blue: 0.62, alpha: 1))

    static let type = dynamic(
        UIColor(red: 0.05, green: 0.38, blue: 0.62, alpha: 1),
        UIColor(red: 0.44, green: 0.82, blue: 0.98, alpha: 1))

    static let str = dynamic(
        UIColor(red: 0.13, green: 0.45, blue: 0.18, alpha: 1),
        UIColor(red: 0.62, green: 0.88, blue: 0.55, alpha: 1))

    static let number = dynamic(
        UIColor(red: 0.60, green: 0.32, blue: 0.02, alpha: 1),
        UIColor(red: 0.98, green: 0.76, blue: 0.45, alpha: 1))

    static let comment = dynamic(
        UIColor(white: 0.48, alpha: 1),
        UIColor(red: 0.44, green: 0.47, blue: 0.55, alpha: 1))

    static let attr = dynamic(
        UIColor(red: 0.45, green: 0.20, blue: 0.68, alpha: 1),
        UIColor(red: 0.79, green: 0.62, blue: 1.00, alpha: 1))

    static let accent = dynamic(
        UIColor(red: 0.00, green: 0.35, blue: 0.85, alpha: 1),
        UIColor(red: 0.40, green: 0.66, blue: 1.00, alpha: 1))

    static let gutter = dynamic(
        UIColor(white: 0.60, alpha: 1),
        UIColor(red: 0.32, green: 0.35, blue: 0.42, alpha: 1))

    static let bar = dynamic(
        UIColor(white: 0.94, alpha: 1),
        UIColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1))

    static let match = dynamic(
        UIColor(red: 1.00, green: 0.80, blue: 0.10, alpha: 0.35),
        UIColor(red: 1.00, green: 0.85, blue: 0.30, alpha: 0.30))
}

// MARK: - Vocabulary

enum Vocab {
    static let keywords = [
        "struct", "class", "enum", "func", "var", "let", "if", "else", "for", "in",
        "while", "repeat", "switch", "case", "default", "return", "guard", "import",
        "self", "true", "false", "nil", "break", "continue", "some", "View", "init",
        "@State", "@Binding", "@main", "extension"
    ]

    static let views = [
        "Text", "Image", "VStack", "HStack", "ZStack", "ScrollView", "List", "ForEach",
        "Button", "Toggle", "TextField", "Slider", "Stepper", "Spacer", "Divider",
        "ProgressView", "Rectangle", "RoundedRectangle", "Circle", "Capsule",
        "NavigationStack", "Section", "Group", "Color", "Label"
    ]

    static let modifiers = [
        "padding", "frame", "background", "foregroundColor", "font", "bold", "italic",
        "cornerRadius", "opacity", "shadow", "offset", "scaleEffect", "rotationEffect",
        "clipShape", "overlay", "border", "lineLimit", "multilineTextAlignment",
        "onTapGesture", "fill", "stroke", "resizable", "aspectRatio", "fixedSize",
        "hidden", "disabled", "accentColor", "navigationTitle", "blur"
    ]

    static let symbols = ["{", "}", "(", ")", "[", "]", "\"", ":", "=", ".", ",", "->",
                          "+", "-", "*", "/", "<", ">", "!", "$", "_", "@", "  "]
}

// MARK: - Syntax highlighting

enum Syntax {
    static func attributed(_ code: String, font: UIFont, query: String = "") -> NSAttributedString {
        let attr = NSMutableAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: Palette.text
        ])
        let ns = code as NSString
        let full = NSRange(location: 0, length: ns.length)

        func paint(_ pattern: String, _ color: UIColor) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            re.enumerateMatches(in: code, options: [], range: full) { match, _, _ in
                guard let r = match?.range else { return }
                attr.addAttribute(.foregroundColor, value: color, range: r)
            }
        }

        paint("\\b[A-Z][A-Za-z0-9_]*\\b", Palette.type)
        paint("@[A-Za-z]+", Palette.attr)
        paint("\\b(struct|class|enum|func|var|let|if|else|for|in|while|repeat|switch|case|default|return|guard|import|self|true|false|nil|some|init|break|continue|static|extension|protocol)\\b", Palette.keyword)
        paint("\\b[0-9]+(\\.[0-9]+)?\\b", Palette.number)
        paint("\"[^\"\\n]*\"", Palette.str)
        paint("//[^\\n]*", Palette.comment)

        if !query.isEmpty, let re = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: query), options: [.caseInsensitive]) {
            re.enumerateMatches(in: code, options: [], range: full) { match, _, _ in
                guard let r = match?.range else { return }
                attr.addAttribute(.backgroundColor, value: Palette.match, range: r)
            }
        }

        return attr
    }
}

// MARK: - Gutter

final class GutterView: UIView {
    weak var textView: UITextView?
    var lineTops: [CGFloat] = []
    var offsetY: CGFloat = 0
    var fontSize: CGFloat = 11
    private var needsRecompute = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.bg
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { return nil }

    func setNeedsRecompute() {
        needsRecompute = true
        setNeedsDisplay()
    }

    func recompute() {
        recalculateLineTops()
        setNeedsDisplay()
    }

    private func recalculateLineTops() {
        guard let tv = textView else { return }
        let text = tv.text as NSString
        var tops: [CGFloat] = []
        var idx = 0
        var guardCount = 0
        let lm = tv.layoutManager

        while idx <= text.length && guardCount < 6000 {
            guardCount += 1
            let range = text.lineRange(for: NSRange(location: min(idx, text.length), length: 0))
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer)
            tops.append(rect.minY + tv.textContainerInset.top)
            if range.length == 0 { break }
            idx = range.location + range.length
        }

        lineTops = tops
        needsRecompute = false
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        if needsRecompute {
            recalculateLineTops()
        }
        ctx.setFillColor(Palette.bg.cgColor)
        ctx.fill(bounds)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: Palette.gutter
        ]

        for (i, top) in lineTops.enumerated() {
            let y = top - offsetY
            if y < -14 || y > bounds.height { continue }
            let s = "\(i + 1)" as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: bounds.width - size.width - 8, y: y), withAttributes: attrs)
        }
    }
}

// MARK: - Container

final class EditorContainer: UIView {
    let gutter = GutterView()
    let textView = UITextView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.bg

        textView.translatesAutoresizingMaskIntoConstraints = false
        gutter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)
        addSubview(textView)

        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutter.widthAnchor.constraint(equalToConstant: 42),

            textView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        gutter.textView = textView
    }

    required init?(coder: NSCoder) { return nil }
}

// MARK: - Accessory bar

final class SuggestionBar: UIView {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var onTap: ((String) -> Void)?
    private var lastItems: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.bar

        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            stack.trailingAnchor.constraint(greaterThanOrEqualTo: scroll.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    required init?(coder: NSCoder) { return nil }

    func configure(_ items: [String], onTap: @escaping (String) -> Void) {
        self.onTap = onTap
        if items == lastItems { return }
        lastItems = items
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            let b = UIButton(type: .system)
            b.setTitle(item, for: .normal)
            b.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            b.setTitleColor(Palette.text, for: .normal)
            b.backgroundColor = UIColor(white: 1, alpha: 0.07)
            b.layer.cornerRadius = 5
            b.contentEdgeInsets = UIEdgeInsets(top: 10, left: 11, bottom: 10, right: 11)
            b.accessibilityLabel = "Insert \(item)"
            b.addAction(UIAction { [weak self] _ in self?.onTap?(item) }, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
    }
}

// MARK: - Editor

struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 13.5
    var query: String = ""

    static func font(_ size: CGFloat) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> EditorContainer {
        let container = EditorContainer()
        let tv = container.textView

        tv.backgroundColor = Palette.bg
        tv.textColor = Palette.text
        tv.font = CodeEditor.font(fontSize)
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
        tv.keyboardType = .asciiCapable
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 60, right: 12)
        tv.indicatorStyle = .default
        tv.accessibilityLabel = "Swift code editor"
        tv.delegate = context.coordinator

        let bar = SuggestionBar(frame: CGRect(x: 0, y: 0,
                                             width: UIScreen.main.bounds.width,
                                             height: 46))
        context.coordinator.bar = bar
        tv.inputAccessoryView = bar

        context.coordinator.attach(container: container, parent: self)
        context.coordinator.reload(text: text, query: query, force: true)
        return container
    }

    func updateUIView(_ container: EditorContainer, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reload(text: text, query: query, force: false)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        weak var container: EditorContainer?
        weak var bar: SuggestionBar?
        private var lastQuery = ""
        private var lastText = ""
        private var lastFontSize: CGFloat = 0
        private var refreshWork: DispatchWorkItem?

        init(_ parent: CodeEditor) { self.parent = parent }

        deinit {
            refreshWork?.cancel()
        }

        func attach(container: EditorContainer, parent editor: CodeEditor) {
            self.container = container
            self.parent = editor
        }

        func reload(text: String, query: String, force: Bool) {
            guard let container = container else { return }
            let tv = container.textView
            let textChanged = tv.text != text
            let queryChanged = query != lastQuery
            let fontChanged = parent.fontSize != lastFontSize

            if textChanged || force || fontChanged {
                let sel = tv.selectedRange
                tv.attributedText = Syntax.attributed(text, font: CodeEditor.font(parent.fontSize), query: query)
                let limit = (tv.text as NSString).length
                tv.selectedRange = NSRange(location: min(sel.location, limit), length: 0)
                tv.typingAttributes = [
                    .font: CodeEditor.font(parent.fontSize),
                    .foregroundColor: Palette.text
                ]
                container.gutter.recompute()
            } else if queryChanged {
                let sel = tv.selectedRange
                tv.attributedText = Syntax.attributed(text, font: CodeEditor.font(parent.fontSize), query: query)
                tv.selectedRange = NSRange(location: min(sel.location, (tv.text as NSString).length), length: 0)
                container.gutter.recompute()
            }

            lastQuery = query
            lastText = text
            lastFontSize = parent.fontSize
            if textChanged || force {
                refreshSuggestions()
            }
        }

        // MARK: delegate

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            lastText = tv.text

            tv.typingAttributes = [
                .font: CodeEditor.font(parent.fontSize),
                .foregroundColor: Palette.text
            ]

            container?.gutter.setNeedsRecompute()
            scheduleAppearanceRefresh()
            refreshSuggestions()
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            refreshSuggestions()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let g = container?.gutter else { return }
            g.offsetY = scrollView.contentOffset.y
            g.setNeedsDisplay()
        }

        // MARK: editing aids

        private let pairs: [String: String] = ["{": "}", "(": ")", "[": "]", "\"": "\""]

        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            let ns = tv.text as NSString
            let insertionIsCode = isCodePosition(in: ns, location: range.location)

            // newline: keep indentation, add a level after an opener
            if text == "\n" {
                let lineRange = ns.lineRange(for: NSRange(location: min(range.location, ns.length), length: 0))
                let lineText = ns.substring(with: lineRange)
                var indent = String(lineText.prefix { $0 == " " || $0 == "\t" })
                let before = ns.substring(to: min(range.location, ns.length))
                let trimmed = before.trimmingCharacters(in: .whitespaces)
                if insertionIsCode,
                   trimmed.hasSuffix("{") || trimmed.hasSuffix("(") || trimmed.hasSuffix("[") {
                    indent += "    "
                }
                tv.insertText("\n" + indent)
                return false
            }

            // closing brace on an empty indented line: dedent first
            if text == "}", range.length == 0, insertionIsCode {
                let lineRange = ns.lineRange(for: NSRange(location: min(range.location, ns.length), length: 0))
                let head = ns.substring(to: range.location)
                let lineStart = lineRange.location
                let currentLinePrefix = (head as NSString).substring(from: lineStart)
                if currentLinePrefix.trimmingCharacters(in: .whitespaces).isEmpty,
                   currentLinePrefix.hasSuffix("    ") {
                    let drop = NSRange(location: range.location - 4, length: 4)
                    tv.text = ns.replacingCharacters(in: drop, with: "")
                    tv.selectedRange = NSRange(location: range.location - 4, length: 0)
                    parent.text = tv.text
                    tv.attributedText = Syntax.attributed(tv.text, font: CodeEditor.font(parent.fontSize), query: parent.query)
                    tv.selectedRange = NSRange(location: range.location - 4, length: 0)
                    container?.gutter.recompute()
                    return false
                }
            }

            if range.length == 0, text == "\"",
               range.location < ns.length,
               ns.substring(with: NSRange(location: range.location, length: 1)) == "\"" {
                // Step over the closing quote even when the caret is inside a string.
                tv.selectedRange = NSRange(location: range.location + 1, length: 0)
                return false
            }

            // Pair only in executable code. Brace/quote insertion inside comments and
            // strings is valid source text and must not be rewritten by the editor.
            if insertionIsCode, range.length == 0, let closer = pairs[text] {
                let next = range.location < ns.length
                    ? ns.substring(with: NSRange(location: range.location, length: 1))
                    : ""
                if next == closer {
                    tv.selectedRange = NSRange(location: range.location + 1, length: 0)
                    return false
                }
                if text == "\"" {
                    let prev = range.location > 0
                        ? ns.substring(with: NSRange(location: range.location - 1, length: 1))
                        : ""
                    if prev == "\\" { return true }
                }
                tv.insertText(text + closer)
                tv.selectedRange = NSRange(location: range.location + 1, length: 0)
                return false
            }

            return true
        }

        private func scheduleAppearanceRefresh() {
            guard let tv = container?.textView else { return }
            let snapshot = tv.text ?? ""
            refreshWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak tv] in
                guard let self = self, let tv = tv, tv.text == snapshot else { return }
                self.applyAppearance(snapshot, to: tv, recomputeGutter: true)
            }
            refreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        private func applyAppearance(_ text: String, to tv: UITextView, recomputeGutter: Bool) {
            let selection = tv.selectedRange
            tv.attributedText = Syntax.attributed(
                text,
                font: CodeEditor.font(parent.fontSize),
                query: parent.query
            )
            let limit = (tv.text as NSString).length
            tv.selectedRange = NSRange(location: min(selection.location, limit), length: 0)
            tv.typingAttributes = [
                .font: CodeEditor.font(parent.fontSize),
                .foregroundColor: Palette.text
            ]
            if recomputeGutter {
                container?.gutter.recompute()
            }
        }

        /// Used to suppress brace/quote pairing inside strings and comments.
        private func isCodePosition(in text: NSString, location: Int) -> Bool {
            let limit = min(max(location, 0), text.length)
            var index = 0
            var blockDepth = 0
            var inString = false
            var multilineString = false
            var inLineComment = false

            func code(_ offset: Int) -> unichar {
                let i = index + offset
                return i < limit ? text.character(at: i) : 0
            }

            while index < limit {
                let ch = code(0)
                if inLineComment {
                    if ch == 10 || ch == 13 { inLineComment = false }
                    index += 1
                    continue
                }

                if blockDepth > 0 {
                    if ch == 47, code(1) == 42 {
                        blockDepth += 1
                        index += 2
                    } else if ch == 42, code(1) == 47 {
                        blockDepth -= 1
                        index += 2
                    } else {
                        index += 1
                    }
                    continue
                }

                if inString {
                    if multilineString, ch == 34, code(1) == 34, code(2) == 34 {
                        inString = false
                        multilineString = false
                        index += 3
                    } else if !multilineString, ch == 34 {
                        inString = false
                        index += 1
                    } else if ch == 92 {
                        index += 2
                    } else {
                        if !multilineString, ch == 10 || ch == 13 {
                            inString = false
                        }
                        index += 1
                    }
                    continue
                }

                if ch == 47, code(1) == 47 {
                    inLineComment = true
                    index += 2
                } else if ch == 47, code(1) == 42 {
                    blockDepth = 1
                    index += 2
                } else if ch == 34 {
                    inString = true
                    if code(1) == 34, code(2) == 34 {
                        multilineString = true
                        index += 3
                    } else {
                        index += 1
                    }
                } else {
                    index += 1
                }
            }

            return !inString && blockDepth == 0 && !inLineComment
        }

        // MARK: suggestions

        private func refreshSuggestions() {
            guard let bar = bar, let tv = container?.textView else { return }
            bar.configure(suggestions(for: tv)) { [weak self] token in
                guard let self = self, let tv = self.container?.textView else { return }
                tv.insertText(token)
            }
        }

        private func suggestions(for tv: UITextView) -> [String] {
            let ns = tv.text as NSString
            let loc = min(tv.selectedRange.location, ns.length)
            var i = loc - 1
            var prefix = ""
            while i >= 0 {
                let c = ns.substring(with: NSRange(location: i, length: 1))
                if " \n\t(){}[],:;=+*/<>!&|".contains(c) { break }
                prefix = c + prefix
                i -= 1
                if prefix.count > 24 { break }
            }

            if prefix.hasPrefix(".") {
                return Vocab.modifiers
            }
            if prefix.isEmpty {
                return Vocab.keywords + Vocab.views
            }
            let lower = prefix.lowercased()
            let pool = Vocab.keywords + Vocab.views + Vocab.modifiers
            let hits = pool.filter { $0.lowercased().hasPrefix(lower) }
            return hits.isEmpty ? Vocab.keywords : hits
        }
    }
}
