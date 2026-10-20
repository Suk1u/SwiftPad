# SwiftPad 2

A Swift + SwiftUI IDE that runs **on the iPhone / iPad itself**. Write code, import whole projects,
preview them live. No Xcode, no build step, no App Store.

```
swiftpad/
├── project.yml                  # XcodeGen spec
├── build_ipa.sh                 # -> build/SwiftPad.ipa
└── Sources/
    ├── SwiftPadApp.swift        # @main
    ├── Info.plist
    ├── Core/
    │   ├── Lexer.swift          # tokenizer
    │   ├── AST.swift            # decls / exprs / stmts / patterns
    │   ├── Parser.swift         # recursive descent + precedence climbing
    │   ├── Value.swift          # runtime values, objects, enums, @State boxes
    │   ├── Interpreter.swift    # evaluator + SwiftUI builtin surface
    │   └── Project.swift        # multi-file model, disk persistence, import
    └── UI/
        ├── ViewNode.swift       # intermediate view tree
        ├── Renderer.swift       # ViewNode -> real SwiftUI
        ├── EditorView.swift     # UITextView + gutter + highlight + auto-pair + completion
        ├── ProjectBrowser.swift # project list, folder/file import
        ├── Samples.swift        # bundled starter projects
        └── ContentView.swift    # shell: tabs, split, preview, console
```

## Why an interpreter, not a compiler

iOS refuses to map writable pages executable on arm64, so nothing can JIT there without special
entitlements. Apple's own Swift Playgrounds sidesteps this by shipping an ahead-of-time toolchain
(~1.5 GB) inside the app. A tree-walking interpreter avoids the problem completely: source is parsed
into data structures and evaluated by native code that is already signed. No dynamic code
generation, no JIT entitlement, no jailbreak, no packaging step.

The trade-off is a supported language subset — but it's a subset big enough to write real screens and
real scripts.

## What it does

**Write.** Multi-file editor with line-number gutter, syntax highlighting, auto-indent, bracket
pairing, context-aware completion strip (typing `.` offers the modifier list), find & replace, per-file
tabs, adjustable font size.

**Preview.** The rendered tree is built from real SwiftUI views, so layout, fonts, colors, spacing and
animation behave like the framework itself. `@State` survives edits — the state store is keyed by
`TypeName.propertyName`, so changing code doesn't reset your counter.

**Import.** Pick a folder of `.swift` files (or individual files) with the system document picker.
Folder structure is preserved as relative paths, every file is parsed into one shared namespace, and
cross-file types/functions resolve. Projects persist in `Documents/SwiftPadProjects/`.

**Run.** Two modes, auto-detected:

- *App mode* — a file declares a type with `body`; the interpreter instantiates it and renders.
  `@main`, `ContentView`, or any type with `body` works as the root.
- *Script mode* — the entry file has top-level statements; they execute in order and `print()` output
  lands in the console. Perfect for algorithms, puzzles, quick experiments.

## Language support

| Area | Supported |
|---|---|
| Declarations | `struct`, `class`, `enum`, `extension`, stored + computed properties, `willSet`/`didSet`, `lazy`, methods, `init`, `subscript` (get/set or implicit getter), static members, `typealias` (parsed, ignored), **`protocol` with real conformance checking**, generics at declaration and call sites (`Box<Int>(5)`) |
| Enums | raw values, associated values, computed properties, methods, `switch` over cases |
| Property wrappers | `@State`, `@StateObject`, `@ObservedObject`, `@Binding` (`$name`) |
| Statements | `var`/`let`, `if`/`else`, `if let`, `guard`/`guard let`, `for … in`, `for (a, b) in`, `while`, `repeat … while`, `switch`, `do`/`catch`, `throw`, `defer`, `fallthrough`, `return`, `break`, `continue`, tuple destructuring |
| Error handling | `throw`, `do`/`catch`, `catch Pattern`, `catch let e`, bare `catch` (binds `error`), `try`, `try?`, `try!` |
| Concurrency | `async` functions and `await` run synchronously; `Task { }`, `MainActor`, `Task.sleep` are accepted no-ops |
| Patterns | `case .foo`, `case .foo(let a, _)`, `case 0`, `case 1...9`, `case _`, `default`, comma lists |
| Operators | full precedence, ternary, `??`, ranges, `?.`-tolerant member access, `!` force unwrap, **custom operators** (`infix operator <+>` + `func <+>`), closures (`$0`, named params, trailing closure, capture lists ignored), array/dict/tuple literals, string interpolation |
| Types | `Int`, `Double`, `String`, `Bool`, `Set`, arrays, dictionaries, tuples, ranges, `nil` |
| Semantics | structs copy on assignment, classes share references |
| Builtins | `print`, `abs`, `min`, `max`, `sqrt`, `pow`, `sin`, `cos`, `tan`, `floor`, `ceil`, `round`, `Int()`, `Double()`, `String()`, `Bool()`, `Array()`, `Set()` |
| Collections | `append`, `insert`, `remove`, `removeAll`, `removeFirst/Last`, `sort`, `reverse`, `contains`, `map`, `compactMap`, `flatMap`, `filter`, `reduce`, `sorted(by:)`, `reversed`, `enumerated`, `firstIndex`, `prefix`, `suffix`, `dropFirst`, `dropLast`, `allSatisfy`, `joined`, `min`, `max`, `count`, `isEmpty`, `first`, `last` |
| Sets | `insert`, `remove`, `removeAll`, `formUnion`, `contains`, `union`, `intersection`, `subtracting`, `isSubset`, `sorted`, `count`, `isEmpty`, `first`, iteration |
| Strings | `count`, `isEmpty`, `first`, `last`, `uppercased`, `lowercased`, `capitalized`, `hasPrefix`, `hasSuffix`, `contains`, `replacingOccurrences`, `components(separatedBy:)`, `split`, `prefix`, `suffix`, `trimmingCharacters` |
| Views | `Text`, `Image(systemName:)`, `VStack`, `HStack`, `ZStack`, `LazyVStack`, `LazyHStack`, `ScrollView`, `List`, `Form`, `Group`, `Section`, `ForEach`, `Button`, `Toggle`, `TextField`, `SecureField`, `Slider`, `Stepper`, `Spacer`, `Divider`, `ProgressView`, `Rectangle`, `RoundedRectangle`, `Circle`, `Capsule`, `Label`, `Link`, `NavigationStack`, `NavigationView`, `Color` |
| Modifiers | `padding`, `frame`, `background`, `foregroundColor`, `foregroundStyle`, `font`, `bold`, `italic`, `fontWeight`, `cornerRadius`, `opacity`, `shadow`, `offset`, `scaleEffect`, `rotationEffect`, `blur`, `clipShape`, `overlay`, `border`, `lineLimit`, `multilineTextAlignment`, `minimumScaleFactor`, `tracking`, `aspectRatio`, `fixedSize`, `hidden`, `accentColor`, `disabled`, `onTapGesture`, `navigationTitle`, `fill`, `stroke` |
| Colors | named colors, `Color("name")`, `Color.x.opacity(n)`, `#RRGGBB`, `#AARRGGBB` |
| Fonts | `.largeTitle` … `.caption2`, `.system(size:weight:)` |

Not supported, and reported by name with a line number instead of failing silently: real
concurrency (async runs synchronously), generic constraints/`where` clauses beyond syntax,
`@escaping` diagnostics, `deinit`, `Set` algebra on nested optionals.

## Two engines

`⋯ → Engine: tree-walker / bytecode VM` switches the evaluator at runtime.

The **tree-walker** is the default and the reference. The **bytecode VM**
(`Bytecode.swift` / `Compiler.swift` / `VM.swift`) compiles each function body to a linear
instruction stream and runs it against an explicit frame stack. Both engines share one
implementation of every semantic rule: the VM's only non-control-flow entry points are the
handful of wrappers at the bottom of `Interpreter.swift`, each a thin call into the
tree-walker's own primitives.

Because frames live on the heap instead of the Swift call stack, a VM run can be stopped
and resumed — that is the property the tree-walker cannot offer, and the reason the VM
exists. Real `await` suspension and reference-counted `deinit` both land on top of it.

The VM is **opt-in and unverified**: it has never been compiled, let alone run. Expect a
debug pass before trusting it. The toggle exists precisely so a bug in it can't take the
working app down with it.

## The three tiers

When something in Swift seems "unsupported", it's worth asking which of three things is actually
missing. They cost very different amounts.

**Tier 1 — runtime concepts the interpreter already had.** Property observers and `lazy` need
nothing but a write path and a read path, and both exist. Built: `willSet`/`didSet` fire on every
assignment including writes that come from rendered controls (`Toggle`, `TextField`, `Slider`), and
`lazy` properties evaluate on first read and memoise. There was never a reason to leave these out.

**Tier 2 — static concepts with no runtime at all.** Protocol conformance, generic constraints and
`@escaping` are compile-time facts. The interpreter had no compile phase, so there was nowhere to
put them — which is why I called them "fake". That was the wrong conclusion: the fix isn't a
runtime, it's a *pass*.

`Sources/Core/Resolver.swift` is that pass. After parsing and before execution it builds the symbol
table and walks every declared conformance, checking that each protocol requirement exists on the
conforming type. Unknown protocols (`View`, `Equatable`) are skipped — they're framework-side.
A missing member stops the run with a list:

```
conformance check failed
  • 'Item' does not conform to 'Describable' — missing 'describe'
```

That's real enforcement, not a stub. Generic constraints and `@escaping` belong in the same pass;
the resolver is where they go.

**Tier 3 — concepts that need an explicit evaluation stack.** Real `async` suspension means
stopping halfway through a function and resuming later. A recursive-descent evaluator can't do that
— the interpreter's call stack *is* Swift's call stack, and Swift won't hand you a continuation for
it. The honest fix is architectural: compile the AST to bytecode and run a VM loop with an explicit
frame stack. Then `await` is "push a continuation, return to the loop", and suspension is trivial.

That rewrite also unlocks `deinit` done properly: an explicit stack plus reference counting on
`Value` at the handful of storage sites gives deterministic destruction, with the usual caveat that
reference cycles leak. It is a rewrite of the evaluator core, not a patch, so it hasn't been started
— a half-migrated evaluator would be worse than the current one.

## Build

### CI — GitHub Actions

`.github/workflows/build.yml` builds an **unsigned** IPA on every push to `main` and on
`workflow_dispatch`. The artifact is `SwiftPad-unsigned-ipa`.

The job selects the newest installed Xcode, then refuses to continue unless the
`iphoneos` SDK is 26 or newer — the app targets iOS 26 and calls Liquid Glass APIs, so an
older SDK cannot compile it. If the runner image doesn't carry Xcode 26 yet, dispatch the
workflow with the `xcode` input set to a version that does, or pin `runs-on` to a newer
image.

Sign it after downloading with Sideloadly, AltStore or TrollStore. The repo never holds
signing material — `.gitignore` excludes profiles, certificates and entitlements.

### Local

macOS + Xcode 26 SDK, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
chmod +x build_ipa.sh
./build_ipa.sh
# -> build/SwiftPad.ipa  (unsigned)

SIGN_IDENTITY="Apple Development: Your Name (ABCDE12345)" \
PROFILE="$HOME/Downloads/profile.mobileprovision" \
./build_ipa.sh
# -> build/SwiftPad-signed.ipa
```

Or `xcodegen generate`, open `SwiftPad.xcodeproj`, pick your team, run on device.

Sideloading: free Apple ID = 7-day profile (re-sign weekly); paid account = 1 year; TrollStore =
install the unsigned IPA directly, no expiry.

## Using it

- **Project name** (top left) opens the project browser: create, rename, delete, import folder, import
  files.
- **File tabs** switch files; long-press a tab to rename, delete, or mark it as the entry file.
- **Split / Code / Run** in the header switches layouts. Drag the divider to resize.
- **▶** re-runs now; otherwise it re-runs 0.55 s after you stop typing.
- **Console** shows `print()` output, the parse/runtime error, and a `script` badge when top-level code
  ran. `copy` puts the whole log on the clipboard.
- **⋯ menu** holds find & replace, text size, console toggle, `@State` reset, preview appearance.

## How a run works

```
files[] -> Lexer.tokenize() -> Parser.parseProgram() -> (decls, topLevel)
        -> register all decls across all files
        -> apply extensions
        -> entry file has topLevel?  -> execute statements      (script mode)
                                     -> find root type with body (app mode)
        -> instantiate()            @State boxes pulled from the global store
        -> collectViews(body)       ViewBuilder semantics -> [ViewNode]
        -> Renderer.view(node)      ViewNode -> real SwiftUI, AnyView-wrapped
```

Rendered controls get `Binding`s that write straight into the `@State` box and ask the runner to
re-evaluate the body — the same reactivity loop SwiftUI uses, one level down.

## Extending

- New view: `viewConstructor` case in `Interpreter.swift`, a `Base` case in `ViewNode.swift`, a branch
  in `Renderer.base`.
- New modifier: one branch in `Renderer.apply`. Arguments arrive in `Mod.args` with labels intact.
- New builtin method: a branch in `Interpreter.callMember`. Mutating methods also need an entry in
  `mutatingMethods` so the write-back path fires.
- New syntax: `Parser` is plain recursive descent, one function per construct.
