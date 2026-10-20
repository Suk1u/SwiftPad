// ⚠️ iOS 26 目标需 Xcode 26 SDK
import SwiftUI
import UniformTypeIdentifiers

struct ProjectBrowser: View {
    @ObservedObject var store: ProjectStore
    @Binding var currentProjectID: UUID?
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var showNew = false
    @State private var newName = ""
    @State private var showFolderImport = false
    @State private var showFileImport = false
    @State private var importError: String?
    @State private var pendingDelete: Project?
    @State private var renaming: Project?
    @State private var renameText = ""

    private var swiftType: UTType {
        UTType(filenameExtension: "swift") ?? .sourceCode
    }

    private var filtered: [Project] {
        guard !query.isEmpty else { return store.projects }
        return store.projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Projects") {
                    ForEach(filtered) { p in
                        Button {
                            currentProjectID = p.id
                            isPresented = false
                        } label: {
                            row(p)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(p.name), \(p.files.count) files")
                        .accessibilityAddTraits(p.id == currentProjectID ? [.isSelected] : [])
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = p
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                renaming = p
                                renameText = p.name
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                        }
                        .contextMenu {
                            Button {
                                renaming = p
                                renameText = p.name
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                pendingDelete = p
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } footer: {
                    Text("Import a folder of Swift files, or pick individual files. Everything runs on device — no Xcode, no build step.")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer, prompt: "Search Projects")
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { isPresented = false }
                        .accessibilityLabel("Close project browser")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            newName = "Untitled"
                            showNew = true
                        } label: {
                            Label("New Project", systemImage: "plus.square")
                        }
                        Button {
                            showFolderImport = true
                        } label: {
                            Label("Import Folder", systemImage: "folder.badge.plus")
                        }
                        Button {
                            showFileImport = true
                        } label: {
                            Label("Import Swift Files", systemImage: "doc.badge.plus")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .accessibilityLabel("Add project")
                }
            }
            .alert("New Project", isPresented: $showNew) {
                TextField("Name", text: $newName)
                Button("Create") {
                    let p = store.create(name: newName.isEmpty ? "Untitled" : newName)
                    currentProjectID = p.id
                    isPresented = false
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename Project", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let p = renaming {
                        store.rename(p, to: renameText.isEmpty ? p.name : renameText)
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .confirmationDialog("Delete this project?",
                                isPresented: Binding(
                                    get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }
                                ),
                                titleVisibility: .visible,
                                presenting: pendingDelete) { p in
                Button("Delete \(p.name)", role: .destructive) {
                    store.delete(p)
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { p in
                Text("\(p.files.count) files will be removed from this device.")
            }
            .alert("Import Failed", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .fileImporter(isPresented: $showFolderImport,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                handleFolder(result)
            }
            .fileImporter(isPresented: $showFileImport,
                          allowedContentTypes: [swiftType, .plainText, .text],
                          allowsMultipleSelection: true) { result in
                handleFiles(result)
            }
        }
    }

    private func row(_ p: Project) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "swift")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(p.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(subtitle(p))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if p.id == currentProjectID {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private func subtitle(_ p: Project) -> String {
        let files = "\(p.files.count) file\(p.files.count == 1 ? "" : "s")"
        if let e = p.entry { return "\(files) · entry \(e)" }
        return files
    }

    private func handleFolder(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let p = try store.importFolder(url)
                currentProjectID = p.id
                isPresented = false
            } catch {
                importError = "\(error)"
            }
        case .failure(let e):
            importError = e.localizedDescription
        }
    }

    private func handleFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            do {
                let p = try store.importFiles(urls)
                currentProjectID = p.id
                isPresented = false
            } catch {
                importError = "\(error)"
            }
        case .failure(let e):
            importError = e.localizedDescription
        }
    }
}
