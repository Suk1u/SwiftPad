# SwiftPad — 复现提示词

> 用法：把下面 `---` 之间的全部内容，作为一条消息发给任意具备代码生成能力的模型（Claude / GPT / Gemini / DeepSeek 均可）。它会产出一个可编译、可打包成无签名 IPA 的完整工程。
>
> 如果你只想让它先出骨架，在末尾加一句「先只做第 1 阶段，等我确认再继续」。不加则要求一次交付完整实现。

---

## 0.1 执行契约与冲突裁决（优先阅读）

本提示词是产品、语言语义和工程交付的主规格。若它与随附的
`swiftui-ios26design-native-ui-builder/SKILL.md` 出现冲突，按以下顺序裁决：

1. **可构建性与功能正确性**：以本提示词的技术前提、目录层级、对
   `UITextView` / `UIViewRepresentable` 的明确要求，以及可运行验收为准。
2. **Apple 平台规范**：以 Liquid Glass 分层、动态颜色、系统文本样式、
   原生浮层、无障碍和可用性保护为准。
3. **文档输出格式**：以本提示词要求的多文件 XcodeGen 工程为准。

因此，执行时必须遵守以下解释：

- **交付多文件工程，不套用 SKILL 的“单一 Swift 文件”输出格式。** 每个
  UI 源文件可在条件允许时提供 `#Preview`；核心解释器、模型和基础设施
  文件不需要伪造成 UI 预览。
- **目标版本是 iOS 26.0+，不是 iOS 27.0+。** iOS 27 专属 API 必须加
  `if #available(iOS 27, *)` / `#available` 保护，且不得成为构建前置条件。
  所有声明的 SwiftUI 界面 API 也必须满足 iOS 26 的可用性。
- **允许 `UITextView` / `UIViewRepresentable`。** 这是项目为了原生代码编辑、
  光标、行号和键盘交互明确要求的系统控件包装，不属于第三方 UI 库，也不是
  自定义绘图或 Polyfill。行号槽可使用最小化的 UIKit `draw(_:)`；除此之外，
  禁止 Canvas、Path、自定义 Shape 或手绘玻璃效果。
- **状态管理以实际工程为约束。** 优先使用 SwiftUI 原生状态；当解释器、
  Combine 绑定或 UIKit 代理生命周期确有必要时，允许 `ObservableObject` /
  `@StateObject` / `@ObservedObject`，不为迎合输出示例而强行替换为 `@Observable`。
- **无障碍要求针对交互控件和关键状态。** 不要求给每一个装饰性 `Text`、
  `Spacer`、`Divider` 或布局容器机械添加 `.accessibilityLabel`。
- **“一次交付完整实现”指最终提交中不得保留 TODO、占位实现、空函数体或
  不可运行分支。** 允许提交过程分阶段进行，但交付前必须完成完整构建与验收。

设计规范是实现质量的硬约束，不是用来自相矛盾或阻塞可编译交付的教条。

## 0. 角色

你是一名同时具备三种能力的工程师：iOS/SwiftUI 应用开发者、编译器/解释器实现者、以及熟悉 Apple HIG 的界面设计师。你要从零实现一个名为 **SwiftPad** 的 iOS 应用，并保证它能通过 Xcode 命令行编译出 `.app` 再打成无签名 `.ipa`。

不要向我提问、不要给方案对比、不要分段征求确认。直接产出完整工程。所有文件一次写完。

---

## 1. 产品定义

SwiftPad 是一台跑在 iPhone/iPad 上的 Swift 开发环境。用户可以在设备上：

1. 新建/编辑多个 Swift 源文件，组成一个项目；
2. 从「文件」App 导入一整个 Swift 项目文件夹（或若干散装 `.swift` 文件），保留相对路径；
3. 点运行，**在设备本地解释执行**这些代码，并把 `print` 输出打到内置控制台；
4. 如果代码里声明了 SwiftUI 视图（`struct Xxx: View { var body: some View { ... } }`），把 `body` 的返回值**渲染成真实的 SwiftUI 界面**显示在预览区；
5. 全程不需要 Xcode、不需要打包、不需要上架、不需要越狱。

### 1.1 必须先想清楚的技术前提

**在 iOS 上运行真正的 `swiftc` 是不可能的。** ARM64 上 W^X 强制生效，可写内存页不能被标记为可执行；没有 JIT；唯一的例外是像 Swift Playgrounds 那样把 Apple 的 AOT 工具链（约 1.5 GB）整个塞进 app。这条路不走。

所以实现方式是：**用原生 Swift 写一个 Swift 子集的解释器**。它不生成机器码，因此不受 JIT 限制；它把用户的 AST 直接求值，产出一个视图树，再由渲染层映射成真实的 SwiftUI 视图。用户看到的界面就是 SwiftUI 本身，不是模拟。

这个前提决定了整个架构。**不要试图在应用内编译 Swift，也不要引入任何需要 JIT 的方案。**

---

## 2. 硬约束

| 项 | 值 |
|---|---|
| 语言 | Swift 5.9 |
| 最低系统 | iOS 26.0 |
| 设备族 | iPhone + iPad（`TARGETED_DEVICE_FAMILY = 1,2`） |
| 工程生成 | XcodeGen（`project.yml`），不提交 `.xcodeproj` |
| 第三方依赖 | 无。只用 Foundation / SwiftUI / UIKit / Combine |
| 签名 | 完全不签名（`CODE_SIGNING_ALLOWED=NO`） |
| Bundle ID | `com.rna.swiftpad` |
| 产物 | `xcodebuild` 出 `.app` → 塞进 `Payload/` → zip 成 `.ipa` |

---

## 3. 目录结构（必须照此组织）

```
swiftpad/
├── project.yml
├── build_ipa.sh
├── README.md
├── .gitignore
├── .gitattributes
├── .github/workflows/build.yml
├── Tests/
│   └── SwiftPadTests.swift      解析器/解释器语义回归测试
└── Sources/
    ├── SwiftPadApp.swift          ~10 行
    ├── Info.plist
    ├── Core/
    │   ├── AST.swift              ~210 行   AST 节点 + 错误类型
    │   ├── Lexer.swift            ~290 行   分词器
    │   ├── Parser.swift           ~1320 行  递归下降 + 优先级爬升
    │   ├── Value.swift            ~230 行   运行时值 + 对象实例 + 全局状态
    │   ├── Interpreter.swift      ~2230 行  树遍历求值器 + SwiftUI 内建表面
    │   ├── Resolver.swift         ~80 行    协议一致性静态检查
    │   ├── Bytecode.swift         ~145 行   指令集 + Chunk + Frame
    │   ├── Compiler.swift         ~590 行   AST → 指令
    │   ├── VM.swift               ~545 行   显式帧栈虚拟机
    │   └── Project.swift          ~265 行   项目模型 + 磁盘持久化
    └── UI/
        ├── ViewNode.swift         ~60 行    视图树中间表示
        ├── Renderer.swift         ~575 行   ViewNode → SwiftUI
        ├── EditorView.swift       ~500 行   代码编辑器（UITextView 包装）
        ├── ProjectBrowser.swift   ~265 行   项目浏览/导入/删除
        ├── ContentView.swift      ~650 行   主界面壳
        └── Samples.swift          ~480 行   内置示例项目
```

总量约 8400 行。**行数是参考，不是目标** —— 但如果某个文件只有几十行而职责对不上，说明你在偷工。

---

## 4. 数据流

```
源文本
  → Lexer.tokenize()        [Token]
  → Parser.parseProgram()   [Program]       每个文件一个 Program
  → Resolver.check()        静态检查（协议一致性），失败则拒绝运行
  → Interpreter.run()       求值
       ├─ 脚本模式：顺序执行顶层语句，print 进 output
       └─ 视图模式：找到根 View 类型，求 body，得到 ViewNode 树
  → Renderer.view(node)     真实 SwiftUI
```

两个求值引擎并列存在，通过菜单切换：

- **tree**（默认）：递归下降直接求值。
- **vm**：AST 编译成线性指令流，跑显式帧栈循环。

两者共享同一套语义定义 —— VM 只通过 `Interpreter` 末尾的桥接扩展回到运行时，桥里每个函数都是一行转发到树遍历器已有的原语。**不要为 VM 复制一份语义实现。**

VM 存在的理由只有一个：帧在堆上而不是 Swift 调用栈上，因此一次运行可以中断再续。这是 `await` 真挂起和确定性 `deinit` 的地基。

---

## 5. 词法层规格

`Lexer` 输入 `String`，输出 `[Token]`。Token = `{ kind, line, col }`，kind 为 `ident / kw / int / double / string / op / punct / eof`。

必须处理：

- 行注释 `//`、块注释 `/* */`（**支持嵌套**）。
- 字符串：普通 `"..."`、三引号 `"""..."""`、raw string `#"..."#`。
- **字符串插值 `\(expr)`**：不能简单跳过，要递归切分成「字面片段 + 表达式源码片段」交给 Parser 二次解析。这是必须的 —— SwiftUI 代码里到处都是 `Text("count: \(n)")`。
- 数字：整数、小数、下划线分隔、十六进制。
- 运算符按**最长匹配**切分。内置双字符表：`== != <= >= && || ?? += -= *= /= %= -> ..`，三字符 `...`、`..<`。
- **自定义运算符预扫描**：词法器构造前，先用两条正则扫全项目的源码 —— `infix operator <符号>` 和 `func <符号>(` —— 收集成一个 `Set<String>` 传进 Lexer。Lexer 在切分前先尝试匹配这个集合里最长的运算符。没有这一步，`<+>` 会被切成 `<`、`+`、`>`。
- 关键字表包含修饰符：`public private fileprivate internal open static class final override mutating nonmutating lazy weak unowned convenience required indirect async throws rethrows await actor some any where inout escaping autoclosure infix prefix postfix nonisolated sending` 等。**注意 `class` 既是关键字又能做标识符**（`class Foo` vs `Foo.class`），需要上下文判断。
- 未知字符报错并带行号。

---

## 6. 语法层规格

递归下降 + 优先级爬升。**不要用解析器生成器**，错误信息会不可控。

### 6.1 声明

`import`、`struct`、`class`、`enum`、`extension`、`protocol`、`typealias`、`func`、`var`/`let`、`init`、`deinit`、`subscript`、属性观察器、属性包装器、泛型参数子句、`where` 子句、访问修饰符、`@attribute`。

类型声明产出 `TypeDecl`，字段包括：`name / isClass / properties / methods / staticMethods / computed / initializer / subscriptGet / subscriptSet / order / isMain / conformances / lazyFlags / observers`。

属性产出 `PropertyDecl`：`name / isVar / typeName / wrappers / initializer / computedBody / isStatic / willSet / didSet / isLazy`。

### 6.2 语句

`var/let`（含元组解构 `let (a, b) = ...`）、`if`/`else if`/`else`、`if let`、`guard`/`guard let`/`else`、`for ... in`（含 `for (i, x) in arr.enumerated()`）、`while`、`repeat ... while`、`switch`、`return`、`break`、`continue`、`fallthrough`、`defer`、`do`/`catch`、`throw`、`try`/`try?`/`try!`。

### 6.3 表达式

字面量、标识符、`self`、`$0`、成员访问、方法调用、下标、闭包（`{ }`、`{ x in }`、`{ (a, b) in }`、尾随闭包、`$0` 简写）、元组、数组/字典字面量、区间、三元、`??`、`as`/`as?`/`is`、前缀/后缀/中缀运算符、`!` 强解包、`?` 可选链、`&` inout。

优先级（数字越大越紧）：

```
1  assignment  = += -= *= /= %=
2  ternary     ? :
3  nilCoalesce ??
4  comparison  == != < > <= >=
5  logicalAnd  &&
6  logicalOr   ||
7  range       ... ..<
8  additive    + -
9  multiplicative * / %
10 unary       - ! &
11 postfix     () [] . !
```

### 6.4 三个必须解决的歧义（这里最容易翻车）

1. **`if x {` vs `VStack {`** —— 两者都是「表达式后跟花括号」。解法：Parser 持有一个 `noTrailing` 标志，解析 `if`/`while`/`for`/`switch`/`guard` 的条件表达式时置位，禁止把 `{` 当作尾随闭包；解析普通表达式时清零。反过来还要防住「表达式跨行继续」的问题：在 `noTrailing` 模式下，换行即视为表达式结束。

2. **`Box<Int>(5)` vs `a < b`** —— 泛型调用和小于号。解法：`looksLikeGenericCall()` —— 从当前位置向前扫描，找配对的 `>`，且 `>` 后紧跟 `(`，才判定为泛型调用并整体跳过；否则当小于号处理。

3. **`case .foo(let a, _)` vs `case 1...9`** —— switch 模式需要独立的解析入口，不能复用表达式解析。支持：`.caseName`、`.caseName(let a, _)`、字面量、区间、`_`、`let x`、逗号列表、`default`、`where` 子句。

### 6.5 错误

所有解析错误抛 `ParseError { message, line, file }`。**必须带文件名和行号**，不许静默跳过。遇到真不支持的语法（比如将来的 `macro`），抛出「`X` 不支持」而不是崩。

---

## 7. 运行时值

```swift
indirect enum Value {
    case void, bool(Bool), int(Int), double(Double), string(String)
    case array([Value]), dict([String: Value]), set([Value]), tuple([Value])
    case object(ObjectInstance)        // class 引用 / struct 值
    case enumValue(EnumValue)
    case function(FuncDecl, Env), closure(ClosureDef, Env), vmClosure(Int, Env)
    case view(ViewNode)
    case binding(StateBox)
    case range(Int, Int, Bool)
    case namespace(String)             // Color / Font / Alignment 等
    case color(String), colorAlpha(String, Double), fontSpec(String)
    case implicit(String)              // .leading 这类裸枚举
    case nilValue
}
```

`ObjectInstance` 是 `final class`，持有 `typeName / isClass / fields / stateBoxes / methods / computed / observers`。

**值语义规则**：`copyForStorage` —— 赋值和传参时，struct 走浅拷贝（`isClass == false` 时新建实例并复制字段），class 保持引用，数组/字典/Set 递归复制。这条不能省，否则用户写的 struct 会表现得像 class。

`asBool / asInt / asDouble / str()` 提供宽松转换（`.int(3)` 取 `str()` 得 `"3"`），用于插值和比较。

---

## 8. 求值器规格

### 8.1 环境

```swift
final class Env {
    var vars: [String: Value]
    var parent: Env?
    var selfObj: ObjectInstance?      // self
    var args: [Value]?                // 闭包参数，供 $0 取
    var selfBoundValue: Value?        // 扩展里 self 可能是非对象
}
```

变量查找顺序：当前层 → 外层 → `self` 的 stateBox → `self` 的 field → 全局。

### 8.2 控制流

`Flow { normal(Value?), ret(Value?), breakFlow, continueFlow, fallthroughFlow }`。`execBlock` 遍历语句，遇到非 normal 立即返回。

**`defer` 的实现**：`execBlock` 收集 defer 体到数组，用 Swift 自己的 `defer` 逆序执行。这样 return、break、**以及 throw 展开**都会触发 —— 跟 Swift 一致。

**`fallthrough`**：返回 `.fallthroughFlow`，switch 语句接住后继续执行下一个 case body。循环体里的 `fallthrough` 也要正确向上传递。

### 8.3 错误处理

**关键设计**：`throw` 不新增 Flow 分支。定义一个 `ThrownError: Error { let value: Value }`，直接搭 Swift 的 `throws` 便车做栈展开。`execBlock`、`invoke`、`eval` 一行都不用改。

好处：用户写的 `catch` 只捕 `ThrownError`，**永远吞不掉解释器自己的 `RuntimeError`**。这条很重要，否则用户的 `catch {}` 会把解释器 bug 变成静默错误。

`try?` 把 `ThrownError` 转成 `.nilValue`；`try!` 转成 `RuntimeError`。

### 8.4 async / await

**语法全收，语义同步。** `async` 函数就是普通函数，`await` 是透明前缀，`Task { }` 立即执行，`Task.sleep` 是空操作。

理由：单线程解释器里没有并发可言，假装有才是欺骗。在文档里明说这一点。

### 8.5 泛型

**擦除。** 声明处的 `<T>` 跳过，调用处 `Box<Int>(5)` 由 `looksLikeGenericCall` 识别后跳过。不建类型参数环境。

### 8.6 属性包装器与响应式

- `@State` / `@StateObject` / `@ObservedObject`：字段不存 `fields`，存 `stateBoxes[name] = StateStore.shared.box(key, initial)`。**key = `"\(TypeName).\(propertyName)"`**。
- `@Binding`：`$name` 在求值时产出 `.binding(box)`，初始化时如果传进来的是 `.binding`，直接接管那个 box。
- `StateStore` 是全局单例。**每次重新运行都新建 Interpreter，但 box 是同一批** —— 所以用户改代码时 `@State` 的值不会丢。这是整个交互体验的核心。

### 8.7 属性观察器

所有字段写入收敛到一条路径 `setField(obj, name, value, env)`：有 `willSet` 先跑（绑 `newValue`），写入，有 `didSet` 再跑（绑 `oldValue`）。初始化时不触发。

`@State` 的写入有两个来源：解释器（走 `setSilent` + 自己跑观察器）和 UI 控件（走 `StateBox.value` 的 setter，触发 `didSetHook`）。**两条路必须互斥**，否则 `didSet` 双触发。

### 8.8 lazy

`lazy var` 在 `instantiate` 时跳过，首次读取时求值并 memoize 进 `fields`。因为读路径要能产生副作用，`lookupVar` 必须是 `throws` 的。

### 8.9 SwiftUI 内建表面

求值器内置这些名字，`viewConstructor` 分派：

**视图**（33 个名字，20 个渲染基元）：
`Text` `Label` `Link` `Image` `VStack` `HStack` `ZStack` `LazyVStack` `LazyHStack` `Grid` `NavigationStack` `NavigationView` `ScrollView` `List` `Form` `Section` `Group` `DisclosureGroup` `WindowGroup` `Scene` `ForEach` `Button` `Toggle` `TextField` `SecureField` `Slider` `Stepper` `Spacer` `Divider` `ProgressView` `Rectangle` `RoundedRectangle` `Circle` `Capsule` `Color`

**修饰符**（约 45 个）：
`padding` `frame(width:height:maxWidth:maxHeight:minWidth:minHeight:alignment:)` `background` `overlay` `cornerRadius` `font` `bold` `fontWeight` `italic` `opacity` `shadow` `offset` `scaleEffect` `rotationEffect` `blur` `clipShape` `lineLimit` `minimumScaleFactor` `multilineTextAlignment` `aspectRatio` `fixedSize` `hidden` `disabled` `border` `fill` `stroke` `navigationTitle` `onTapGesture`

**命名空间**：`Color.*` `Font.*` `Edge.*` `Alignment.*` `TextAlignment.*` `Axis.*` `EdgeInsets.*` `UnitPoint.*` `Font.Weight.*`

**内置函数**：`print` `abs` `min` `max` `sqrt` `pow` `sin` `cos` `tan` `floor` `ceil` `round` `Int()` `Double()` `String()` `Bool()` `Array()` `Set()`

**集合方法**：`append` `insert` `remove` `removeAll` `removeFirst` `removeLast` `sort` `reverse` `contains` `map` `compactMap` `flatMap` `filter` `reduce` `sorted(by:)` `reversed` `enumerated` `firstIndex` `prefix` `suffix` `dropFirst` `dropLast` `allSatisfy` `joined` `min` `max` `count` `isEmpty` `first` `last`

**字符串方法**：`uppercased` `lowercased` `capitalized` `hasPrefix` `hasSuffix` `contains` `replacingOccurrences` `trimmingCharacters` `components` `split` `prefix` `suffix` `count` `isEmpty`

**Int/Double**：`isMultiple(of:)` `advanced(by:)` `rounded()`

**Set**：`insert` `remove` `removeAll` `formUnion` `union` `intersection` `subtracting` `isSubset(of:)` `sorted` `contains`

`Set` 用插入有序 + 按值去重的 `[Value]` 实现。类型标注里含 `Set` 的数组字面量要 `coerce` 成集合：`var s: Set<Int> = [1,2,2,3]` → `{1,2,3}`。

---

## 9. 视图树与渲染

中间表示必须是**纯数据**，不含 SwiftUI 类型：

```swift
struct ViewNode {
    var base: Base
    var mods: [Mod]          // Mod { name, args, labels }
}

indirect enum Base {
    case empty, text(String), image(String), shape(String, Double)
    case colorFill(String), spacer, divider, progress(Double?)
    case stack(StackAxis, String, Double?, [ViewNode])
    case scroll([ViewNode]), list([ViewNode]), nav(String?, [ViewNode])
    case group([ViewNode])
    case button([ViewNode], () -> Void)
    case toggle(String, StateBox), textField(String, StateBox)
    case slider(StateBox, Double, Double), stepper(String, StateBox)
}
```

`Renderer` 把 `Base` 映射成 `AnyView`，然后**按顺序**应用 `mods`。

渲染要点：

- `button` 的 action 是闭包，点击时让 Runner 重新求值 body。
- `toggle` / `textField` / `slider` 拿 `Binding`，**直接写进 StateBox 并触发重跑**。
- **TextField 和 Slider 绝不能每次按键就重建树** —— 否则输入框每 100 ms 丢焦点。提交（onSubmit / 失焦）或松手时才刷新。
- `ForEach` 用 `ForEach(0..<kids.count, id: \.self)` 包一层，不要依赖用户的 id 类型。
- `group` 在父容器里要展平成多个子视图（`flattened`），不能渲染成一个容器。

---

## 10. 项目模型与持久化

```swift
struct SourceFile: Identifiable, Codable, Equatable {
    var id: UUID; var name: String; var text: String
    var displayName: String { (name as NSString).lastPathComponent }
}

struct Project: Identifiable, Codable, Equatable {
    var id: UUID; var name: String; var files: [SourceFile]; var entry: String?
}
```

**磁盘布局**：

```
Documents/SwiftPadProjects/
  <uuid>/
    _meta.json          { name, entry, order: [String] }
    Sources/App.swift
    Sources/Views/Card.swift
```

- 一个文件一条记录，文件名即相对路径，`displayName` 取 `lastPathComponent` 做 tab 标题。
- `entry` 指向脚本模式的入口文件。
- 首次启动若目录为空，把内置示例写进去。
- 写入要**防抖**（约 400 ms），不要每个按键都写盘。

**导入**：`UIDocumentPicker` / `.fileImporter`，`UTType.folder` 选文件夹，`.swift` / `.plainText` / `.text` 选文件。递归遍历，只收 `.swift` 和 `.txt`，相对路径原样保留。

**跨文件解析**：每个文件独立 lex+parse 成 `Program`，然后**两趟注册**：

1. 第一趟：所有 `typeDecl` / `enumDecl` / `funcDecl` / `extension`（extension 收集起来最后应用）。
2. 第二趟：所有顶层 `var`/`let` 全局属性求初值。

顺序很重要 —— 这样「全局变量初始化时调用后面文件里声明的函数」也能解析。extension 必须在两趟之后统一 apply，否则扩展可能作用在还没注册的类型上。

**根视图选择**：`@main` 标注的类型 → `ContentView` → 第一个有 `body` 的类型。

**脚本模式探测**：入口文件有顶层语句 → 按顺序执行，`print` 进控制台。自动探测（第一个有顶层代码的文件），也可手动指定。

---

## 11. 字节码 VM（第二阶段）

### 11.1 为什么要有

树遍历器的调用栈**就是 Swift 的调用栈**，你没法把函数冻在半路。要真挂起，必须把栈搬到堆上。VM 就是干这个的。

### 11.2 指令集（约 40 条）

```
常量    pushConst(Int) pushNil pushTrue pushFalse pushVoid
读      load(String) loadSelf loadMember(String) loadDollar(Int) loadBinding(String)
写      store(String) define(String) storeMember(String)
        storeSubscriptNamed(String, Int) storeSubscriptMember(String, Int)
        subscriptGet(Int)
栈      pop dup
运算    binary(String) unary(String)
跳转    jump(Int) jumpIfFalse(Int) jumpIfTrue(Int) jumpIfNil(Int)
构造    makeArray(Int) makeTuple(Int) makeDict(Int)
调用    makeClosure(Int) callNamed(String, Int, Int) callMember(String, Int, Int)
        callValue(Int) ret retVoid
异常    pushHandler(Int) popHandler throwTop tryOptional(Int) tryForced
其它    awaitTop forceUnwrap fallthroughJump switchDispatch(Int) catchDispatch(Int)
```

### 11.3 关键取舍

- **按名字 load/store，不做槽位分配。** 慢一点，但直接复用 `lookupVar`/`assignVar`，语义零风险。这是语义等价工程，不是性能工程。
- `&&` / `||` / `??` 编译成**短路序列**（dup + 条件跳转），不是算完再判断。
- `fallthrough` 在编译期就是 `jump 下一臂` —— 静态可解。
- 下标赋值需要 lvalue 回写，所以编成 `storeSubscriptNamed` / `storeSubscriptMember`，不能用通用 store。
- 模式匹配 / switch / catch 通过**侧表**分派，让模式逻辑只存在一份。
- `defer` 体编译成独立 chunk，帧退出时运行。

### 11.4 桥接

VM 只能通过 `Interpreter` 末尾的一个 extension 回到运行时，里面是 `selfValue / dollarValue / bindingValue / subscriptAssign / binaryValues / unaryValue / bindValues` 等，每个一行转发。为此需要把 `assignVar / memberValue / setField / iterate / match / callNamed / callMember / callValue / subscriptValue` 从 `private` 放宽到 `internal`。

### 11.5 状态

**VM 是 opt-in 的，默认关闭，菜单里可切。** 它必须被标注为「未经验证」—— 这不是谦虚，是事实。开关存在的意义就是让 VM 的 bug 砸不掉能用的树遍历器。

---

## 12. 编辑器

用 `UIViewRepresentable` 包 `UITextView`（不要用 SwiftUI 的 `TextEditor`，拿不到行号和光标）。

必须实现：

1. **行号槽** `GutterView` —— 从 `layoutManager` 逐行算真实 y 坐标（处理换行折行），跟随滚动重绘。
2. **语法高亮** —— 正则着色，颜色全部走动态 `UIColor` provider。支持关键字/类型/字符串/数字/注释/属性。
3. **自动缩进** —— 换行时若上一行以 `{` 结尾，多缩一级；输入 `}` 时自动反缩一级。
4. **自动配对** —— `{` `(` `[` `"` 成对插入，光标居中；输入闭合符时若下一个字符正好是它，则跳过而不是重复插入。
5. **上下文补全条** `SuggestionBar` —— 输入 `.` 时列出修饰符，输入字母时过滤关键字/视图名。横向滚动的按钮条贴在键盘上方。
6. **查找替换** —— 高亮所有匹配（背景色 `Palette.match`），上一个/下一个，全部替换。
7. **可调字号** —— 这是用户设置，不受「禁止写死字号」约束。

**三个必须踩过的坑**：

- `UITextView` 默认的**智能引号必须关掉**（`smartQuotesType = .no`、`smartDashesType = .no`、`smartInsertDeleteType = .no`），否则用户输入的 `"` 变成 `"`，代码直接编不过。
- **自动配对不能在字符串和注释里触发** —— 需要一个轻量的「当前位置是否在字符串/注释内」判断。
- **行号重算要在 `textStorage` 编辑回调里做**，但不要在每次按键时全量重排 1000 行以上（会卡）；用脏标记 + 延迟。

---

## 13. 界面规范（iOS 26 HIG / Liquid Glass）

这一节是硬性要求，不是建议。逐条对照：

### 13.1 分层

- **功能层**（工具栏、浮动控件）→ 只能用**系统 Liquid Glass**：
  - 主操作按钮 `.buttonStyle(.glassProminent)`
  - 次要按钮 `.buttonStyle(.glass)`
  - 多个浮动控件放进 `GlassEffectContainer`
  - **不许**给 toolbar 加自定义背景色，**不许**自己画玻璃
- **内容层**（列表、面板、画布）→ 只能用**标准材质**：
  - `.regularMaterial` / `.thinMaterial` 做面板
  - `.systemBackground` / `.secondarySystemBackground` 做底色
  - **不许**在内容层用 `.glassEffect()`

### 13.2 颜色

所有自定义颜色必须是动态 provider，明暗两套值：

```swift
static func dynamic(_ light: UIColor, _ dark: UIColor) -> UIColor {
    UIColor { $0.userInterfaceStyle == .dark ? dark : light }
}
```

语法高亮的 12 个颜色（关键字/类型/字符串/数字/注释/属性/强调/行号/工具条/匹配背景）全部照此实现。

### 13.3 字号

**chrome 里一个 `.system(size:)` 都不许有。** 只用系统文本样式（`.headline` `.body` `.caption` `.footnote` 等）。唯一的例外是代码编辑器本身的可调字号。

### 13.4 其他

- `NavigationStack` + `.toolbar`，**不要手写顶栏**。
- Section 标题用 Title Case，**不许 `.uppercased()`**。
- 破坏性操作走 `.confirmationDialog`，不要自己弹 alert 做二次确认。
- 每个可交互控件都要 `.accessibilityLabel`；选中态加 `.accessibilityAddTraits(.isSelected)`；计数器之类加 `.accessibilityValue`。
- 触控目标最小 44×44。
- **不要**在 App 入口加 `.preferredColorScheme(.dark)` —— 会让 Liquid Glass 的自适应失效。
- 每个独立 UI 场景至少提供一个浅色和深色 `#Preview`；预览中的
  `.preferredColorScheme` 只用于画布验证，不得写入 App 入口。

---

## 14. 构建

### 14.1 `project.yml`

```yaml
name: SwiftPad
options:
  bundleIdPrefix: com.rna
  deploymentTarget: { iOS: "26.0" }
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "5.9"
    ENABLE_USER_SCRIPT_SANDBOXING: NO
targets:
  SwiftPad:
    type: application
    platform: iOS
    sources: [{ path: Sources, excludes: ["Info.plist"] }]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.rna.swiftpad
        PRODUCT_NAME: SwiftPad
        INFOPLIST_FILE: Sources/Info.plist
        GENERATE_INFOPLIST_FILE: NO
        TARGETED_DEVICE_FAMILY: "1,2"
        CODE_SIGNING_REQUIRED: NO
        CODE_SIGNING_ALLOWED: NO
        ONLY_ACTIVE_ARCH: NO
    scheme: { testTargets: [] }
```

`Info.plist` 需要 `UILaunchScreen`（空 dict 即可）、`UISupportedInterfaceOrientations`、`UIApplicationSceneManifest` 可省（SwiftUI App 生命周期不需要）。

### 14.2 CI（`.github/workflows/build.yml`）

触发：`push: branches: [main]`、`pull_request`、`workflow_dispatch`（带可选 `xcode` 输入）。`runs-on: macos-latest`，`timeout-minutes: 30`，`concurrency` 按 ref 分组并取消进行中的。

步骤：

1. checkout
2. **选最新 Xcode**：扫 `/Applications/Xcode*.app`，按版本号 `sort -V` 取最高，`xcode-select -s`
3. **SDK 门禁**：`xcrun --sdk iphoneos --show-sdk-version`，主版本 < 26 直接 `::error::` 退出并说明原因（Liquid Glass API 编不过）。这一步是刻意的 —— 与其让它报一堆符号找不到，不如第一分钟就告诉用户 runner 太旧。
4. `brew install xcodegen`
5. `xcodegen generate`
6. 从 `xcrun simctl list devices available -j` 动态选择一个可用 iPhone 模拟器，运行
   `SwiftPadTests`；语义测试失败时不产出 IPA。
7. `xcodebuild -project SwiftPad.xcodeproj -scheme SwiftPad -configuration Release -sdk iphoneos -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build`
8. 打包：`mkdir Payload && cp -R .../SwiftPad.app Payload/ && zip -qry SwiftPad.ipa Payload`
9. `actions/upload-artifact@v4` 上传 `SwiftPad.ipa`，名 `SwiftPad-unsigned-ipa`，`if-no-files-found: error`
10. `if: failure()` 时额外上传 `build/Logs`

### 14.3 本地脚本 `build_ipa.sh`

同样的流程，支持 `SIGN_IDENTITY` / `PROFILE` 环境变量做可选签名，不设则出无签名包。

---

## 15. 验收清单

交付前自己过一遍。任何一条不过，就是没做完。

**编译**

- [ ] `xcodegen generate && xcodebuild ... build` 零错误。
- [ ] 没有 `warning: ... will never be executed` 这类明显逻辑错。
- [ ] GitHub Actions 在 iPhone 模拟器上运行 `SwiftPadTests`，全部通过。

**语言**

- [ ] `struct` 赋值后修改副本，原值不变（值语义）。
- [ ] `class` 赋值后修改，两边都变（引用语义）。
- [ ] `@State` 计数按钮点三次显示 3；改代码重跑后仍显示 3。
- [ ] `do/catch` 捕获自定义 `throw`；`try?` 返回 nil；`try!` 失败时报明确错误。
- [ ] `defer` 在 `return`、`break`、`throw` 三种情况下都执行。
- [ ] `switch` 的 `.case(let x)`、`1...9`、`_`、`default`、`fallthrough` 全部正确。
- [ ] 自定义运算符 `<+>` 能声明并调用。
- [ ] `Set<Int> = [1,2,2,3]` 结果是 3 个元素。
- [ ] `subscript` 读写都生效。
- [ ] `willSet`/`didSet` 各触发一次，初始化时不触发。
- [ ] `lazy var` 首次读才求值，二次读不重跑。
- [ ] 协议缺成员时拒绝运行并列出缺失成员。

**UI**

- [ ] `VStack` / `HStack` / `ZStack` / `List` / `ForEach` / `Button` / `Toggle` / `TextField` / `Slider` 都能渲染且可交互。
- [ ] 输入框打字不丢焦点。
- [ ] 亮/暗模式切换，语法颜色和材质都跟着变。
- [ ] 工具栏是系统玻璃，内容面板是材质，没有一处混用。

**工程**

- [ ] 导入一个含子目录的 Swift 文件夹，相对路径保留，跨文件调用能跑。
- [ ] 杀掉 app 重启，项目还在。
- [ ] CI 出 `SwiftPad.ipa`，解压后 `Payload/SwiftPad.app/SwiftPad` 是 arm64 Mach-O。

---

## 16. 已知的坑（别人踩过，别重踩）

1. **`RuntimeError` 必须有 `init(_:)`。** 只有 memberwise init 时，`RuntimeError("...")` 会在 60 个调用点同时报 `missing argument label 'message:'`。这个错误会一直潜伏到第一次真正编译。

2. **`Frame.env` 必须是 `var`。** switch/catch 分派时要重新绑定环境，`let` 会直接编不过。

3. **指令集和 VM 的 switch 必须同步。** 加了 `jumpIfTrue` / `subscriptGet` 到 `Op`，就要同时补 VM 的 handler 和 `describe()`，否则 `switch` 不穷尽。

4. **VM 桥需要放宽访问级别。** 那些 `private func` 在另一个文件里调不到，得改成 `internal`。

5. **用脚本改 Swift 代码时，绝不要用字符串替换写入转义序列。** 一次 `\n` 被写成字面量 `/n`，浪费了一整轮 CI。带转义的改动一律用编辑器工具逐处改，并且每个替换都要断言命中。

6. **SwiftUI 类型检查器会超时。** 一个 `List` 挂 8 个修饰符就能触发 `unable to type-check this expression in reasonable time`。把长修饰符链拆成几个 `private var xxx: some View` 计算属性。

7. **`Section("Title") { } footer: { }` 重载解析会失败。** 用显式 `Section { } header: { } footer: { }`。

8. **`.gitattributes` 强制 LF。** 否则 `build_ipa.sh` 在 Windows 上提交、在 macOS 上 checkout 成 CRLF，直接跑不起来（`bad interpreter`）。

9. **不要给 `UITextView` 保留智能标点。** 见 §12。

10. **不要假装实现了做不到的东西。** async 是同步的、泛型是擦除的、VM 没验证过 —— 这些都要在 README 里明写。用户能接受边界，不能接受被骗。

---

## 17. 交付要求

1. 按 §3 的目录结构，**一次性写完全部文件**。不要留 `// TODO`、不要留 `fatalError("implement")`、不要留空函数体。
2. 每个文件顶部一行注释说明职责。复杂逻辑（优先级爬升、跳转回填、值语义拷贝、观察器双路径）加简短注释解释**为什么**，不复述**是什么**。
3. 附 `README.md`：架构图（ASCII）、支持的语言特性表、明确的不支持清单、构建步骤、两个引擎的说明。
4. 附内置示例项目 6 个：`Counter`（@State 计数器）、`Todo`（List + ForEach + 增删）、`Multi-file App`（跨文件 + 导航）、`Script`（顶层语句 + print）、`Language tour`（把 enum/switch/guard/try-catch/defer/subscript/Set/自定义运算符/async 全跑一遍）、`Layout`（各种 stack 和修饰符）。
5. 最后用不超过 20 行说明：哪些做完了、哪些是近似实现、下一个该动哪里。

不要写免责声明，不要写「仅供学习」，不要问我用途。这是一个开发工具，照做。

---

*（提示词结束）*

---

## 附录 A — 精简版（上下文有限时用这个）

> 上面那份是完整规格，约 600 行。如果目标模型的上下文不够，用下面这份 40 行的浓缩版。它会产出一个功能少一圈但结构正确的实现，之后可以按上面那份逐节补齐。

```
用原生 Swift 5.9 从零实现 SwiftPad，一个跑在 iOS 26 上的 Swift 开发环境。
不签名、不上架、不依赖 Xcode。XcodeGen 出工程，xcodebuild 出 .app 再打成无签名 .ipa。

前提：iOS 上没有 JIT，跑不了真正的 swiftc。所以实现方式是「用 Swift 写一个 Swift 子集的
解释器」——AST 直接求值，产出视图树，再映射成真实 SwiftUI。不要试图在应用内编译。

架构（严格分层，不许跨层耦合）：
  源文本 → Lexer → Parser → [Program] → Resolver → Interpreter → ViewNode → Renderer → SwiftUI

Core/
  AST.swift       声明/语句/表达式节点 + ParseError/RuntimeError
  Lexer.swift     分词；必须处理字符串插值 \(expr)、嵌套块注释、raw string、
                  以及「预扫描全项目自定义运算符」再按最长匹配切分
  Parser.swift    递归下降 + 优先级爬升；支持 struct/class/enum/extension/protocol/
                  func/init/subscript/属性包装器/泛型子句/where；if-let/guard/for-in/
                  switch 全模式/do-catch/throw/try?/try!/defer/fallthrough
  Value.swift     indirect enum Value（含 array/dict/set/tuple/object/enumValue/
                  function/closure/view/binding/range/namespace/nil）；
                  ObjectInstance（class 引用）；StateStore（全局 @State 仓库）
  Interpreter.swift  树遍历求值器 + SwiftUI 内建表面（约 33 个视图、45 个修饰符、
                  60 个集合/字符串方法）
  Resolver.swift  执行前的协议一致性检查，缺成员则拒绝运行并列出
  Bytecode/Compiler/VM  第二个引擎：AST 编译成线性指令，跑显式帧栈。
                  按名字 load/store 不做槽位分配，语义与树遍历器共用一份。
UI/
  ViewNode.swift  纯数据视图树（不含 SwiftUI 类型）
  Renderer.swift  ViewNode → AnyView，按顺序应用修饰符
  EditorView.swift  UITextView 包装：行号槽、正则高亮、自动缩进、括号配对、
                    上下文补全条、查找替换
  ContentView.swift  NavigationStack + 工具栏 + 分栏 + 控制台
  ProjectBrowser.swift  项目列表、文件夹导入、删除、重命名
  Samples.swift   6 个内置示例

三条必须正确的语义：
1. struct 赋值浅拷贝、class 保持引用（copyForStorage）
2. @State 的 box 键是 "TypeName.property"，重跑新建 Interpreter 但复用 box，
   所以改代码时状态不丢
3. throw 用自定义 Error 类型搭 Swift 的 throws 做栈展开，用户 catch 吞不掉
   解释器的 RuntimeError

界面必须守 iOS 26 HIG：功能层只用系统 Liquid Glass（.buttonStyle(.glass)、
GlassEffectContainer），内容层只用标准材质（.regularMaterial/.systemBackground），
两层不许混用；自定义颜色全部写成 UIColor { traits in ... } 的明暗双值；
chrome 里不许有 .system(size:)；每个控件带 accessibilityLabel。

CI：GitHub Actions，macos-latest，选最高版本 Xcode，先查 iphoneos SDK 主版本是否
>= 26，不满足直接报错退出；然后 xcodegen + xcodebuild 无签名构建，塞 Payload 打 zip
成 SwiftPad.ipa，上传 artifact。

已知的坑：RuntimeError 必须有 init(_:)；Frame.env 必须是 var；指令集与 VM 的 switch
必须同步；长修饰符链会让 SwiftUI 类型检查器超时，要拆成计算属性；
Section 用显式 content/header/footer 形式。

一次性写完全部文件，不留 TODO、不留空实现。README 里明写哪些是近似实现
（async 是同步的、泛型是擦除的）。
```

---

## 附录 B — 增量迭代提示词

生成完之后，用它继续推进（每次一条）：

```
在现有 SwiftPad 工程上继续，只改必要的文件，其余保持不动。

[任务]
<一句话说明要加什么>

[约束]
- 不改动现有语义：树遍历器仍是默认引擎，改动必须对两个引擎都成立
- 新增语言特性时同步更新：Parser、Interpreter、Compiler、VM 的 switch、
  Resolver（如涉及）、README 的支持表、Samples 里的 Language tour
- 新增视图或修饰符时同步更新：ViewNode.Base（如需要）、Interpreter 的
  viewConstructor、Renderer 的 case、以及内建名字集合
- 不留 TODO，不写「后续可扩展」

[验收]
<贴一条能验证的具体代码片段或操作步骤>
```

