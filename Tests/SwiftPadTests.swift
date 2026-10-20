import XCTest
@testable import SwiftPad

final class SwiftPadTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StateStore.shared.reset()
    }

    private func runScript(_ source: String) throws -> RunOutcome {
        try Interpreter().run(
            files: [SourceInput(name: "main.swift", text: source)],
            entry: "main.swift"
        )
    }

    func testLexerHandlesUnderscoresHexTripleAndRawStrings() throws {
        let source = "1_000 0xFF \"\"\"multi\nline\"\"\" #\"raw\\n\"#"
        let tokens = try Lexer(source).tokenize()

        guard case .intLit(let decimal) = tokens[0].tok else {
            return XCTFail("expected decimal integer")
        }
        guard case .intLit(let hex) = tokens[1].tok else {
            return XCTFail("expected hexadecimal integer")
        }
        guard case .strLit(let triple) = tokens[2].tok else {
            return XCTFail("expected triple-quoted string")
        }
        guard case .strLit(let raw) = tokens[3].tok else {
            return XCTFail("expected raw string")
        }

        XCTAssertEqual(decimal, 1_000)
        XCTAssertEqual(hex, 255)
        XCTAssertEqual(triple, "multi\nline")
        XCTAssertEqual(raw, #"raw\n"#)
    }

    func testStringInterpolationEvaluatesNestedExpressions() throws {
        let outcome = try runScript("""
        let count = 3
        print("count: \\(count + (2 * 2))")
        """)

        XCTAssertEqual(outcome.output, ["count: 7"])
    }

    func testStructCopiesAndClassSharesReference() throws {
        let outcome = try runScript("""
        struct Point {
            var x: Int
        }

        class Box {
            var x: Int
        }

        var firstPoint = Point(x: 1)
        var secondPoint = firstPoint
        secondPoint.x = 2
        print("struct", firstPoint.x, secondPoint.x)

        let firstBox = Box(x: 1)
        let secondBox = firstBox
        secondBox.x = 2
        print("class", firstBox.x, secondBox.x)
        """)

        XCTAssertEqual(outcome.output, ["struct 1 2", "class 2 2"])
    }

    func testStateBoxSurvivesInterpreterRerun() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            @State var count = 0

            var body: some View {
                Text("\\(count)")
            }
        }
        """

        _ = try Interpreter().run(
            files: [SourceInput(name: "ContentView.swift", text: source)],
            entry: "ContentView.swift"
        )
        StateStore.shared.box("ContentView.count", .int(0)).value = .int(3)

        let outcome = try Interpreter().run(
            files: [SourceInput(name: "ContentView.swift", text: source)],
            entry: "ContentView.swift"
        )

        guard case .view(let node) = outcome.view else {
            return XCTFail("expected a rendered view")
        }
        guard case .text(let text) = node.base else {
            return XCTFail("expected rendered text")
        }
        XCTAssertEqual(text, "3")
    }

    func testDeferRunsForReturnThrowAndCatch() throws {
        let outcome = try runScript("""
        enum Failure: Error {
            case stopped
        }

        func finish() throws -> Int {
            defer { print("cleanup") }
            throw Failure.stopped
        }

        do {
            try finish()
        } catch {
            print("caught")
        }
        """)

        XCTAssertEqual(outcome.output, ["cleanup", "caught"])
    }

    func testTryOptionalAndTryForced() throws {
        let optional = try runScript("""
        enum Failure: Error {
            case stopped
        }

        func finish() throws -> Int {
            throw Failure.stopped
        }

        let result = try? finish()
        print(result == nil)
        """)
        XCTAssertEqual(optional.output, ["true"])

        XCTAssertThrowsError(try runScript("""
        enum Failure: Error {
            case stopped
        }

        func finish() throws -> Int {
            throw Failure.stopped
        }

        let result = try! finish()
        """))
    }

    func testSwitchRangeAssociatedValueAndFallthrough() throws {
        let outcome = try runScript("""
        enum Value {
            case number(Int)
        }

        let wrapped = Value.number(5)
        switch wrapped {
        case .number(let number):
            print("number", number)
        default:
            print("other")
        }

        for number in [5, 20] {
            switch number {
            case 1...9:
                print("range")
                fallthrough
            default:
                print("tail")
            }
        }
        """)

        XCTAssertEqual(outcome.output, ["number 5", "range", "tail", "tail"])
    }

    func testSetCoercionSubscriptAndCustomOperator() throws {
        let outcome = try runScript("""
        infix operator <+>
        func <+>(lhs: [Int], rhs: [Int]) -> [Int] {
            return lhs + rhs
        }

        struct Vault {
            var items: [String] = ["gold", "map"]
            subscript(index: Int) -> String {
                get { return items[index] }
                set { items[index] = newValue }
            }
        }

        var vault = Vault()
        vault[1] = "compass"
        var values: Set<Int> = [1, 2, 2, 3]
        print(vault[1], values.count, [1, 2] <+> [3])
        """)

        XCTAssertEqual(outcome.output, ["compass 3 [1, 2, 3]"])
    }

    func testPropertyObserversAndLazyRunOnce() throws {
        let outcome = try runScript("""
        struct Gauge {
            var value: Int = 0 {
                willSet { print("will", newValue) }
                didSet { print("did", oldValue, value) }
            }
        }

        struct Heavy {
            lazy var table: [Int] = build()
            func build() -> [Int] {
                print("build")
                return [1, 2, 3]
            }
        }

        var gauge = Gauge()
        gauge.value = 3
        var heavy = Heavy()
        print(heavy.table.count)
        print(heavy.table.count)
        """)

        XCTAssertEqual(outcome.output, ["will 3", "did 0 3", "build", "3", "3"])
    }

    func testProtocolConformanceFailsBeforeExecution() throws {
        XCTAssertThrowsError(try runScript("""
        protocol Describable {
            func describe() -> String
        }

        struct Item: Describable {
            var name: String
        }

        print("must not run")
        """)) { error in
            XCTAssertTrue("\(error)".contains("does not conform"))
            XCTAssertTrue("\(error)".contains("describe"))
        }
    }

    func testSecureFieldKeepsSecureRenderingMode() throws {
        let outcome = try Interpreter().run(
            files: [SourceInput(name: "ContentView.swift", text: """
            import SwiftUI

            struct ContentView: View {
                @State var password = ""

                var body: some View {
                    SecureField("Password", text: $password)
                }
            }
            """)],
            entry: "ContentView.swift"
        )

        guard case .view(let node) = outcome.view,
              case .textField(_, _, let secure) = node.base else {
            return XCTFail("expected a text field node")
        }
        XCTAssertTrue(secure)
    }

    func testConformanceErrorAndDeferAlsoWorkInMultiFileProject() throws {
        let outcome = try Interpreter().run(files: [
            SourceInput(name: "Model.swift", text: """
            struct Point {
                var x: Int
            }

            func doubled(_ value: Int) -> Int {
                return value * 2
            }
            """),
            SourceInput(name: "main.swift", text: """
            let point = Point(x: doubled(4))
            defer { print("done") }
            print(point.x)
            """)
        ], entry: "main.swift")

        XCTAssertEqual(outcome.output, ["8", "done"])
    }
}
