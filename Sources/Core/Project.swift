import Foundation
import Combine

// MARK: - Model

struct SourceFile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var text: String

    var displayName: String {
        (name as NSString).lastPathComponent
    }
}

struct Project: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var files: [SourceFile]
    var entry: String? = nil

    var swiftFiles: [SourceFile] {
        files.filter { $0.name.hasSuffix(".swift") }
    }

    var hasScriptEntry: Bool {
        guard let e = entry else { return false }
        return files.contains { $0.name == e }
    }
}

private struct ProjectMeta: Codable {
    var name: String
    var entry: String?
    var order: [String]
}

// MARK: - Store

final class ProjectStore: ObservableObject {
    @Published var projects: [Project] = []

    private let fm = FileManager.default
    private let root: URL

    init() {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("SwiftPadProjects", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        loadAll()
        if projects.isEmpty {
            for p in Samples.all {
                var copy = p
                copy.id = UUID()
                copy.files = p.files.map { SourceFile(name: $0.name, text: $0.text) }
                projects.append(copy)
                persist(copy)
            }
        }
    }

    // MARK: load

    private func loadAll() {
        guard let dirs = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return }
        var loaded: [Project] = []
        for dir in dirs {
            if let p = load(dir) { loaded.append(p) }
        }
        projects = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func load(_ dir: URL) -> Project? {
        guard let id = UUID(uuidString: dir.lastPathComponent) else { return nil }
        let metaURL = dir.appendingPathComponent("_meta.json")
        var name = "Project"
        var entry: String? = nil
        var order: [String] = []

        if let data = try? Data(contentsOf: metaURL),
           let meta = try? JSONDecoder().decode(ProjectMeta.self, from: data) {
            name = meta.name
            entry = meta.entry
            order = meta.order
        }

        var files: [SourceFile] = []
        let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" || url.pathExtension == "txt" else { continue }
            let rel = url.path.replacingOccurrences(of: dir.path + "/", with: "")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                files.append(SourceFile(name: rel, text: text))
            }
        }

        files.sort { a, b in
            let ia = order.firstIndex(of: a.name) ?? Int.max
            let ib = order.firstIndex(of: b.name) ?? Int.max
            if ia != ib { return ia < ib }
            return a.name < b.name
        }

        return Project(id: id, name: name, files: files, entry: entry)
    }

    // MARK: persist

    func persist(_ project: Project) {
        let dir = root.appendingPathComponent(project.id.uuidString, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let meta = ProjectMeta(name: project.name, entry: project.entry, order: project.files.map { $0.name })
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: dir.appendingPathComponent("_meta.json"))
        }

        for f in project.files {
            let url = dir.appendingPathComponent(f.name)
            let parent = url.deletingLastPathComponent()
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try? f.text.write(to: url, atomically: true, encoding: .utf8)
        }

        // prune files that no longer exist
        let keep = Set(project.files.map { $0.name })
        if let existing = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in existing where url.lastPathComponent != "_meta.json" {
                let rel = url.path.replacingOccurrences(of: dir.path + "/", with: "")
                if !keep.contains(rel) {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    func save(_ project: Project) {
        if let i = projects.firstIndex(where: { $0.id == project.id }) {
            projects[i] = project
        }
        persist(project)
    }

    private var pendingSave: DispatchWorkItem?

    func schedulePersist(_ project: Project) {
        pendingSave?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.persist(project) }
        pendingSave = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }

    // MARK: CRUD

    @discardableResult
    func create(name: String) -> Project {
        let starter = SourceFile(name: "ContentView.swift", text: Templates.blank)
        let p = Project(name: name, files: [starter], entry: nil)
        projects.append(p)
        persist(p)
        return p
    }

    func delete(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        let dir = root.appendingPathComponent(project.id.uuidString, isDirectory: true)
        try? fm.removeItem(at: dir)
    }

    func rename(_ project: Project, to newName: String) {
        guard var p = projects.first(where: { $0.id == project.id }) else { return }
        p.name = newName
        save(p)
    }

    // MARK: import

    /// Copies a folder (recursively, .swift/.txt only) into a new project.
    func importFolder(_ url: URL, name: String? = nil) throws -> Project {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var files: [SourceFile] = []
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let f as URL in en {
                guard f.pathExtension == "swift" || f.pathExtension == "txt" else { continue }
                let rel = f.path.replacingOccurrences(of: url.path + "/", with: "")
                if let text = try? String(contentsOf: f, encoding: .utf8) {
                    files.append(SourceFile(name: rel, text: text))
                }
            }
        }
        if files.isEmpty {
            throw ImportError.empty
        }
        files.sort { $0.name < $1.name }

        let projectName = name ?? url.deletingPathExtension().lastPathComponent
        var p = Project(name: projectName, files: files, entry: nil)
        p.entry = detectEntry(p)
        projects.append(p)
        persist(p)
        return p
    }

    /// Copies loose files into a new project.
    func importFiles(_ urls: [URL], name: String = "Imported") throws -> Project {
        var files: [SourceFile] = []
        var used = Set<String>()
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
            var nm = u.lastPathComponent
            if used.contains(nm) {
                nm = "\(UUID().uuidString.prefix(4))-\(nm)"
            }
            used.insert(nm)
            files.append(SourceFile(name: nm, text: text))
        }
        if files.isEmpty { throw ImportError.empty }
        var p = Project(name: name, files: files, entry: nil)
        p.entry = detectEntry(p)
        projects.append(p)
        persist(p)
        return p
    }

    func detectEntry(_ p: Project) -> String? {
        for f in p.files {
            let t = f.text
            if t.contains("@main") { return f.name }
        }
        for f in p.files where f.text.contains("struct ContentView") { return f.name }
        for f in p.files {
            // crude: file with top-level statements
            let lines = f.text.split(separator: "\n")
            var depth = 0
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix("import") { continue }
                if depth == 0 && !trimmed.hasPrefix("struct") && !trimmed.hasPrefix("class")
                    && !trimmed.hasPrefix("enum") && !trimmed.hasPrefix("func")
                    && !trimmed.hasPrefix("extension") && !trimmed.hasPrefix("@") {
                    return f.name
                }
                depth += line.filter { $0 == "{" }.count
                depth -= line.filter { $0 == "}" }.count
                if depth < 0 { depth = 0 }
            }
        }
        return p.files.first?.name
    }
}

enum ImportError: Error, CustomStringConvertible {
    case empty
    var description: String {
        switch self {
        case .empty: return "No .swift files found in that location"
        }
    }
}
