import Foundation

enum Templates {
    static let blank = """
    import SwiftUI

    struct ContentView: View {
        @State var count = 0

        var body: some View {
            VStack(spacing: 20) {
                Text("Hello, SwiftPad")
                    .font(.largeTitle)
                    .bold()
                Text("\\(count)")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundColor(.blue)
                Button("Tap me") { count += 1 }
            }
            .padding()
        }
    }
    """
}

enum Samples {

    static var all: [Project] {
        [counter, todo, multiFile, script, tour, playground]
    }

    // MARK: 1

    static let counter = Project(name: "Counter", files: [
        SourceFile(name: "ContentView.swift", text: """
        import SwiftUI

        struct ContentView: View {
            @State var count = 0
            @State var big = false

            var body: some View {
                VStack(spacing: 22) {
                    Text("Tap Counter")
                        .font(.largeTitle)
                        .bold()
                    Text("\\(count)")
                        .font(.system(size: big ? 72 : 40, weight: .bold))
                        .foregroundColor(count > 0 ? .blue : (count < 0 ? .red : .secondary))
                    HStack(spacing: 14) {
                        Button("-1") { count -= 1 }
                        Button("Reset") { count = 0 }
                        Button("+1") { count += 1 }
                    }
                    Toggle("Big number", isOn: $big)
                        .padding(.horizontal, 30)
                    if count > 9 {
                        Text("double digits")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
        }
        """)
    ], entry: nil)

    // MARK: 2

    static let todo = Project(name: "Todo", files: [
        SourceFile(name: "ContentView.swift", text: """
        import SwiftUI

        struct ContentView: View {
            @State var items = ["Milk", "Coffee", "Bread"]
            @State var draft = ""

            var body: some View {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Groceries")
                        .font(.title)
                        .bold()

                    HStack(spacing: 8) {
                        TextField("Add an item", text: $draft)
                            .padding(10)
                            .background(Color.gray.opacity(0.15))
                            .cornerRadius(8)
                        Button("Add") {
                            if draft.count > 0 {
                                items.append(draft)
                                draft = ""
                            }
                        }
                    }

                    Text("\\(items.count) items")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(items) { item in
                        HStack {
                            Text(item)
                            Spacer()
                            Button("x") { items.remove(0) }
                                .foregroundColor(.red)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding()
            }
        }
        """)
    ], entry: nil)

    // MARK: 3 — multi-file

    static let multiFile = Project(name: "Multi-file App", files: [
        SourceFile(name: "Models.swift", text: """
        import Foundation

        enum Priority: String {
            case low = "Low"
            case normal = "Normal"
            case high = "High"

            var tint: String {
                switch self {
                case .low: return "gray"
                case .normal: return "blue"
                case .high: return "red"
                }
            }

            var rank: Int {
                switch self {
                case .low: return 0
                case .normal: return 1
                case .high: return 2
                }
            }
        }

        struct Task {
            var title: String
            var priority: Priority
            var done: Bool

            func summary() -> String {
                let mark = done ? "x" : " "
                return "[\\(mark)] \\(title) — \\(priority.rawValue)"
            }
        }

        func sortTasks(_ list: [Task]) -> [Task] {
            return list.sorted { $0.priority.rank > $1.priority.rank }
        }
        """),

        SourceFile(name: "TaskRow.swift", text: """
        import SwiftUI

        struct TaskRow: View {
            var task: Task

            var body: some View {
                HStack(spacing: 12) {
                    Circle()
                        .fill(task.done ? .green : .gray.opacity(0.35))
                        .frame(width: 14, height: 14)
                    Text(task.summary())
                        .font(.body)
                        .foregroundColor(task.done ? .secondary : .primary)
                    Spacer()
                    Text(task.priority.rawValue)
                        .font(.caption)
                        .foregroundColor(Color(task.priority.tint))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(task.priority.tint).opacity(0.15))
                        .cornerRadius(6)
                }
                .padding(.vertical, 4)
            }
        }
        """),

        SourceFile(name: "ContentView.swift", text: """
        import SwiftUI

        struct ContentView: View {
            @State var tasks = [
                Task(title: "Write the parser", priority: Priority.high, done: true),
                Task(title: "Render the preview", priority: Priority.high, done: false),
                Task(title: "Polish the editor", priority: Priority.normal, done: false),
                Task(title: "Ship it", priority: Priority.low, done: false)
            ]

            var body: some View {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Today")
                        .font(.largeTitle)
                        .bold()

                    ForEach(sortTasks(tasks)) { t in
                        TaskRow(task: t)
                    }

                    Divider()

                    HStack {
                        Text("Done: \\(tasks.filter { $0.done }.count)/\\(tasks.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Mark all done") {
                            var out: [Task] = []
                            for t in tasks {
                                out.append(Task(title: t.title, priority: t.priority, done: true))
                            }
                            tasks = out
                        }
                    }
                }
                .padding()
            }
        }
        """)
    ], entry: nil)

    // MARK: 4 — script

    static let script = Project(name: "Script", files: [
        SourceFile(name: "main.swift", text: """
        import Foundation

        enum Suit: String {
            case hearts = "H"
            case spades = "S"
            case clubs = "C"
            case diamonds = "D"

            var name: String {
                switch self {
                case .hearts: return "hearts"
                case .spades: return "spades"
                case .clubs: return "clubs"
                case .diamonds: return "diamonds"
                }
            }
        }

        func describe(_ s: Suit) -> String {
            return "\\(s.name) [\\(s.rawValue)]"
        }

        for s in [Suit.hearts, Suit.spades, Suit.clubs] {
            print(describe(s))
        }

        var total = 0
        for i in 1...10 {
            if i % 2 == 0 { continue }
            total += i
        }
        print("sum of odds 1...10 =", total)

        let names = ["ada", "grace", "alan"]
        for (i, n) in names.enumerated() {
            print(i, n.uppercased())
        }

        func classify(_ n: Int) -> String {
            switch n {
            case 0:
                return "zero"
            case 1...9:
                return "single digit"
            default:
                return "big"
            }
        }

        for v in [0, 7, 42] {
            print(v, "->", classify(v))
        }
        """)
    ], entry: "main.swift")

    // MARK: 5 — language tour (script)

    static let tour = Project(name: "Language tour", files: [
        SourceFile(name: "main.swift", text: """
        import Foundation

        // custom operator
        infix operator <+>

        func <+>(lhs: [Int], rhs: [Int]) -> [Int] {
            return lhs + rhs
        }

        enum VaultError: Error {
            case locked
            case unknown(Int)
        }

        struct Vault {
            private var items: [String] = []

            subscript(index: Int) -> String {
                get { return items[index] }
                set { items[index] = newValue }
            }

            var count: Int { return items.count }

            mutating func add(_ s: String) {
                items.append(s)
            }

            func open(code: Int) throws -> String {
                if code != 1234 {
                    throw VaultError.locked
                }
                return "opened"
            }
        }

        var vault = Vault()
        vault.add("gold")
        vault.add("map")
        vault[1] = "compass"

        print("slot 0:", vault[0])
        print("slots:", vault.count)

        do {
            let r = try vault.open(code: 0)
            print(r)
        } catch VaultError.locked {
            print("locked out")
        } catch {
            print("something else:", error)
        }

        defer {
            print("— done —")
        }

        print("sum:", [1, 2] <+> [3, 4])

        var seen: Set<Int> = [1, 2, 2, 3]
        seen.insert(4)
        seen.insert(1)
        print("set size:", seen.count, "has 3:", seen.contains(3))

        for x in seen.sorted() {
            print("member", x)
        }

        func fetch() async -> Int {
            return 42
        }

        let answer = await fetch()
        print("answer:", answer)

        // protocol conformance is checked before anything runs
        protocol Describable {
            var label: String { get }
            func describe() -> String
        }

        struct Item: Describable {
            var name: String

            var label: String { return name }

            func describe() -> String {
                return "item: \\(name)"
            }
        }

        let item = Item(name: "lamp")
        print(item.describe(), "/", item.label)

        // property observers
        struct Gauge {
            var value: Int = 0 {
                willSet {
                    print("  will", newValue)
                }
                didSet {
                    print("  did", oldValue, "->", value)
                }
            }
        }

        var g = Gauge()
        g.value = 3
        g.value = 7

        // lazy
        struct Heavy {
            lazy var table: [Int] = build()

            func build() -> [Int] {
                print("  building…")
                var out: [Int] = []
                for i in 1...3 {
                    out.append(i * i)
                }
                return out
            }
        }

        var h = Heavy()
        print("before first read")
        print("table:", h.table)
        print("again:", h.table)
        """)
    ], entry: "main.swift")

    // MARK: 6 — layout playground
    static let playground = Project(name: "Layout", files: [
        SourceFile(name: "ContentView.swift", text: """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack(spacing: 16) {
                    Text("Layout Demo")
                        .font(.title2)
                        .bold()

                    HStack(spacing: 10) {
                        card("A", .blue)
                        card("B", .green)
                        card("C", .orange)
                    }

                    ZStack {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.indigo)
                            .frame(height: 120)
                        Text("ZStack")
                            .font(.headline)
                            .foregroundColor(.white)
                    }

                    HStack(spacing: 8) {
                        Circle().fill(.pink).frame(width: 44, height: 44)
                        Circle().fill(.teal).frame(width: 44, height: 44)
                        Circle().fill(.yellow).frame(width: 44, height: 44)
                        Spacer()
                    }
                }
                .padding()
            }
        }

        func card(_ title: String, _ tint: Color) -> some View {
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Text("card")
                    .font(.caption)
                    .foregroundColor(.white)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(tint)
            .cornerRadius(14)
        }
        """)
    ], entry: nil)
}
