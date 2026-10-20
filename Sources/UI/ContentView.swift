// ⚠️ iOS 26 目标需 Xcode 26 SDK — Liquid Glass 只在 iOS 26+ 可用
import SwiftUI
import UIKit

// MARK: - Runner

final class Runner: ObservableObject {
    @Published var tree: ViewNode = .empty
    @Published var output: [String] = []
    @Published var error: String? = nil
    @Published var mode: String = "none"
    @Published var revision: Int = 0

    var engine: Engine = .tree
    private var interpreter = Interpreter()
    private var pending: DispatchWorkItem?
    private var project: Project?

    func load(_ p: Project) {
        project = p
        pending?.cancel()
        runNow()
    }

    func type(_ p: Project) {
        project = p
        schedule(0.55)
    }

    func invalidate() {
        schedule(0.12)
    }

    private func schedule(_ delay: Double) {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.runNow() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func runNow() {
        guard let p = project else { return }
        let inputs = p.files.map { SourceInput(name: $0.name, text: $0.text) }
        let interp = Interpreter()
        interp.engine = engine
        do {
            let result = try interp.run(files: inputs, entry: p.entry)
            interpreter = interp
            tree = result.view ?? .empty
            output = result.output
            mode = result.mode
            error = nil
        } catch {
            interpreter = interp
            tree = .empty
            output = []
            mode = "none"
            self.error = "\(error)"
        }
        revision += 1
    }

    func invoke(_ v: Value) {
        interpreter.invokeValue(v)
    }

    func resetState() {
        StateStore.shared.reset()
        runNow()
    }

    func clearConsole() {
        output = []
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var store = ProjectStore()
    @StateObject private var runner = Runner()

    @State private var currentProjectID: UUID?
    @State private var currentFileID: UUID?

    @State private var mode = 0                 // 0 split, 1 code, 2 run
    @State private var fraction: CGFloat = 0.55
    @State private var showConsole = true
    @State private var showBrowser = false
    @State private var showFind = false
    @State private var findQuery = ""
    @State private var replaceText = ""
    @State private var searchNonce = 0
    @State private var searchForward = true
    @State private var fontSize: CGFloat = 13.5
    @State private var previewScheme = 0
    @State private var useVM = false
    @State private var booted = false
    @State private var renamingFile: SourceFile?
    @State private var renameText = ""
    @State private var pendingFileDelete: SourceFile?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: derived

    private var project: Project? {
        store.projects.first { $0.id == currentProjectID }
    }

    private var file: SourceFile? {
        project?.files.first { $0.id == currentFileID }
    }

    private var fileText: Binding<String> {
        Binding(
            get: { self.file?.text ?? "" },
            set: { newValue in
                guard let pi = self.store.projects.firstIndex(where: { $0.id == self.currentProjectID }),
                      let fi = self.store.projects[pi].files.firstIndex(where: { $0.id == self.currentFileID })
                else { return }
                self.store.projects[pi].files[fi].text = newValue
                let snapshot = self.store.projects[pi]
                self.store.schedulePersist(snapshot)
                self.runner.type(snapshot)
            }
        )
    }

    private var matchCount: Int {
        guard !findQuery.isEmpty, let t = file?.text else { return 0 }
        let range = NSRange(location: 0, length: (t as NSString).length)
        guard let expression = try? NSRegularExpression(
            pattern: NSRegularExpression.escapedPattern(for: findQuery),
            options: [.caseInsensitive]
        ) else { return 0 }
        return expression.numberOfMatches(in: t, options: [], range: range)
    }

    // MARK: body

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                content
            }
            .safeAreaInset(edge: .top, spacing: 0) { documentBar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showConsole { consolePanel }
            }
            .navigationTitle(project?.name ?? "SwiftPad")
            .navigationSubtitle(file?.displayName ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .sheet(isPresented: $showBrowser) {
            ProjectBrowser(store: store,
                           currentProjectID: $currentProjectID,
                           isPresented: $showBrowser)
        }
        .alert("Rename File", isPresented: Binding(
            get: { self.renamingFile != nil },
            set: { if !$0 { self.renamingFile = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let f = self.renamingFile { self.applyRename(f) }
            }
            Button("Cancel", role: .cancel) { self.renamingFile = nil }
        }
        .confirmationDialog("Delete this file?",
                            isPresented: Binding(
                                get: { pendingFileDelete != nil },
                                set: { if !$0 { pendingFileDelete = nil } }
                            ),
                            titleVisibility: .visible,
                            presenting: pendingFileDelete) { file in
            Button("Delete \(file.displayName)", role: .destructive) {
                deleteFile(file)
                pendingFileDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingFileDelete = nil }
        } message: { file in
            Text("Changes in \(file.displayName) will be removed from this project.")
        }
        .onAppear { self.boot() }
        .onChange(of: currentProjectID) { _, _ in
            self.syncFileSelection()
            self.runNow()
        }
    }

    // MARK: toolbar (functional layer — system Liquid Glass, no custom backgrounds)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                self.showBrowser = true
            } label: {
                Label("Projects", systemImage: "square.stack.3d.up")
            }
            .accessibilityLabel("Projects")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                self.runNow()
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("Run project")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    self.addFile()
                } label: {
                    Label("New File", systemImage: "doc.badge.plus")
                }

                if let p = project {
                    Menu {
                        ForEach(p.files) { f in
                            Button(f.displayName) { self.setEntry(f) }
                        }
                    } label: {
                        Label("Entry File", systemImage: "play.circle")
                    }
                }

                Button {
                    self.runner.resetState()
                } label: {
                    Label("Reset State", systemImage: "arrow.counterclockwise")
                }

                Divider()

                Button {
                    self.showFind.toggle()
                } label: {
                    Label("Find and Replace", systemImage: "magnifyingglass")
                }
                Button {
                    self.fontSize = min(22, self.fontSize + 1)
                } label: {
                    Label("Bigger Text", systemImage: "textformat.size.larger")
                }
                Button {
                    self.fontSize = max(10, self.fontSize - 1)
                } label: {
                    Label("Smaller Text", systemImage: "textformat.size.smaller")
                }
                Button {
                    self.showConsole.toggle()
                } label: {
                    Label(showConsole ? "Hide Console" : "Show Console", systemImage: "terminal")
                }

                Divider()

                Button {
                    self.previewScheme = self.previewScheme == 0 ? 1 : 0
                } label: {
                    Label(previewScheme == 0 ? "Light Canvas" : "Dark Canvas",
                          systemImage: previewScheme == 0 ? "sun.max" : "moon")
                }
                Button {
                    self.useVM.toggle()
                    self.runner.engine = self.useVM ? .vm : .tree
                    self.runNow()
                } label: {
                    Label(useVM ? "Engine: Bytecode VM (Experimental)" : "Engine: Tree-walker",
                          systemImage: "cpu")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityLabel("More actions")
        }
    }

    // MARK: document bar (content layer — standard materials only)

    private var documentBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let p = project {
                            ForEach(p.files) { f in
                                fileChip(f)
                            }
                            Button {
                                addFile()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.footnote.weight(.semibold))
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("New file")
                        } else {
                            Text("No Project")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Picker("Layout", selection: $mode) {
                    Text("Split").tag(0)
                    Text("Code").tag(1)
                    Text("Run").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 210)
                .accessibilityLabel("Layout")
            }
            .padding(.horizontal, 12)

            if showFind { findBar }

            Divider()
        }
        .background(.regularMaterial)
    }

    private func fileChip(_ f: SourceFile) -> some View {
        let selected = f.id == currentFileID
        let isEntry = project?.entry == f.name
        return Button {
            currentFileID = f.id
        } label: {
            HStack(spacing: 4) {
                if isEntry {
                    Image(systemName: "play.circle.fill")
                        .font(.caption2)
                }
                Text(f.displayName)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("File \(f.displayName)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .contextMenu {
            Button {
                renamingFile = f
                renameText = f.displayName
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                setEntry(f)
            } label: {
                Label("Set as Entry", systemImage: "play.circle")
            }
            Button(role: .destructive) {
                pendingFileDelete = f
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: find

    private var findBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("Find", text: $findQuery)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Find text")

                Text("\(matchCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(matchCount) matches")

                Button {
                    search(forward: false)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 44, height: 44)
                }
                .disabled(findQuery.isEmpty || matchCount == 0)
                .accessibilityLabel("Previous match")

                Button {
                    search(forward: true)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 44, height: 44)
                }
                .disabled(findQuery.isEmpty || matchCount == 0)
                .accessibilityLabel("Next match")

                Button {
                    showFind = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close find bar")
            }

            HStack(spacing: 8) {
                TextField("Replace", text: $replaceText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Replace with")

                Button("Replace All") { replaceAll() }
                    .font(.footnote)
                    .frame(minHeight: 44)
                    .disabled(findQuery.isEmpty)
                    .accessibilityLabel("Replace all matches")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func search(forward: Bool) {
        searchForward = forward
        searchNonce += 1
    }

    private func replaceAll() {
        guard !findQuery.isEmpty,
              let pi = store.projects.firstIndex(where: { $0.id == currentProjectID }),
              let fi = store.projects[pi].files.firstIndex(where: { $0.id == currentFileID })
        else { return }
        let updated = store.projects[pi].files[fi].text
            .replacingOccurrences(
                of: findQuery,
                with: replaceText,
                options: [.caseInsensitive]
            )
        store.projects[pi].files[fi].text = updated
        runNow()
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        switch mode {
        case 1:
            editor
        case 2:
            preview
        default:
            GeometryReader { geo in
                VStack(spacing: 0) {
                    editor
                        .frame(height: max(140, geo.size.height * fraction))
                    splitHandle(geo.size)
                    preview
                        .frame(maxHeight: .infinity)
                }
                .coordinateSpace(name: "split")
            }
        }
    }

    private var editor: some View {
        CodeEditor(
            text: fileText,
            fontSize: fontSize,
            query: showFind ? findQuery : "",
            searchNonce: searchNonce,
            searchForward: searchForward
        )
            .accessibilityLabel("Swift code editor")
    }

    private func splitHandle(_ size: CGSize) -> some View {
        ZStack {
            Color(.secondarySystemBackground)
            Capsule()
                .fill(Color(.tertiaryLabel))
                .frame(width: 44, height: 4)
        }
        .frame(height: 16)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .named("split"))
                .onChanged { v in
                    let f = v.location.y / max(size.height, 1)
                    self.fraction = min(0.85, max(0.15, f))
                }
        )
        .accessibilityLabel("Resize editor and preview")
    }

    // MARK: preview (content layer)

    private var preview: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(.secondarySystemBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Renderer(invalidate: { self.runner.invalidate() },
                             invoke: { self.runner.invoke($0) })
                        .view(runner.tree)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                }
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(12)
            }
            .environment(\.colorScheme, previewScheme == 0 ? .dark : .light)

            if runner.tree.isEmptyNode && runner.error == nil && runner.mode != "script" {
                ContentUnavailableView("Nothing to Preview",
                                       systemImage: "swift",
                                       description: Text("Add a type with a body and it renders here."))
                    .accessibilityLabel("Nothing to preview")
            }

            if runner.mode == "script" && runner.tree.isEmptyNode {
                ContentUnavailableView("Script Mode",
                                       systemImage: "terminal",
                                       description: Text("Top-level code runs and its output goes to the console."))
                    .accessibilityLabel("Script mode")
            }

            previewControls
                .padding(16)
        }
    }

    /// Floating functional controls over content — the one place Liquid Glass belongs here.
    private var previewControls: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    self.previewScheme = self.previewScheme == 0 ? 1 : 0
                } label: {
                    Image(systemName: previewScheme == 0 ? "sun.max" : "moon")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(previewScheme == 0 ? "Switch to light canvas" : "Switch to dark canvas")

                Button {
                    runNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Re-run project")
            }
        }
    }

    // MARK: console (content layer)

    private var consolePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Console")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if runner.mode == "script" {
                    Text("Script")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }

                Spacer()

                Button {
                    UIPasteboard.general.string = runner.output.joined(separator: "\n")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Copy console output")

                Button {
                    runner.clearConsole()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Clear console")
            }
            .font(.footnote)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if let e = runner.error {
                        Text(e)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                            .accessibilityLabel("Error: \(e)")
                    }
                    ForEach(0..<runner.output.count, id: \.self) { i in
                        Text(runner.output[i])
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .frame(height: 132)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: lifecycle

    private func boot() {
        guard !booted else { return }
        booted = true
        if let first = store.projects.first {
            currentProjectID = first.id
            currentFileID = first.files.first?.id
            runner.load(first)
        }
    }

    private func syncFileSelection() {
        guard let p = project else { return }
        if !p.files.contains(where: { $0.id == currentFileID }) {
            currentFileID = p.files.first?.id
        }
    }

    private func runNow() {
        guard let p = project else { return }
        store.persist(p)
        runner.load(p)
    }

    // MARK: file ops

    private func addFile() {
        guard let pi = store.projects.firstIndex(where: { $0.id == currentProjectID }) else { return }
        var n = 1
        var name = "File\(n).swift"
        while store.projects[pi].files.contains(where: { $0.name == name }) {
            n += 1
            name = "File\(n).swift"
        }
        let stem = name.replacingOccurrences(of: ".swift", with: "")
        let f = SourceFile(name: name,
                           text: "import SwiftUI\n\nstruct \(stem): View {\n    var body: some View {\n        Text(\"Hello\")\n    }\n}\n")
        store.projects[pi].files.append(f)
        currentFileID = f.id
        store.persist(store.projects[pi])
    }

    private func deleteFile(_ f: SourceFile) {
        guard let pi = store.projects.firstIndex(where: { $0.id == currentProjectID }) else { return }
        store.projects[pi].files.removeAll { $0.id == f.id }
        if currentFileID == f.id {
            currentFileID = store.projects[pi].files.first?.id
        }
        if store.projects[pi].entry == f.name {
            store.projects[pi].entry = nil
        }
        store.persist(store.projects[pi])
        runNow()
    }

    private func setEntry(_ f: SourceFile) {
        guard let pi = store.projects.firstIndex(where: { $0.id == currentProjectID }) else { return }
        store.projects[pi].entry = f.name
        store.persist(store.projects[pi])
        runNow()
    }

    private func applyRename(_ f: SourceFile) {
        guard let pi = store.projects.firstIndex(where: { $0.id == currentProjectID }),
              let fi = store.projects[pi].files.firstIndex(where: { $0.id == f.id }) else { return }
        var newName = store.safeSourceFileName(renameText)
        if newName != f.name, store.projects[pi].files.contains(where: { $0.name == newName && $0.id != f.id }) {
            let base = newName.replacingOccurrences(of: ".swift", with: "")
            var suffix = 2
            repeat {
                newName = "\(base)\(suffix).swift"
                suffix += 1
            } while store.projects[pi].files.contains(where: { $0.name == newName && $0.id != f.id })
        }
        if store.projects[pi].entry == f.name {
            store.projects[pi].entry = newName
        }
        store.projects[pi].files[fi].name = newName
        renamingFile = nil
        store.persist(store.projects[pi])
    }
}

// Preview-only appearance checks. The app itself deliberately leaves the color
// scheme to the system so Liquid Glass can adapt.
#Preview("Light") {
    ContentView()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    ContentView()
        .preferredColorScheme(.dark)
}
