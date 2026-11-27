import SwiftUI
import AppKit

struct AnalyzeResult: Decodable {
    struct Entry: Decodable, Identifiable, Hashable {
        let name: String
        let path: String
        let size: Int64
        let is_dir: Bool
        let insight: Bool?
        let last_access: String?
        var id: String { path + "|" + name }
    }
    let path: String
    let overview: Bool?
    let entries: [Entry]
    let total_size: Int64?
}

@MainActor
final class AnalyzeModel: ObservableObject {
    /// nil = the disk overview Mole shows by default.
    @Published var stack: [String?] = [nil]
    @Published var result: AnalyzeResult?
    @Published var error: String?
    @Published var loading = false
    private var cache: [String: AnalyzeResult] = [:]
    private var task: Task<Void, Never>?

    var current: String? { stack.last ?? nil }

    func load(force: Bool = false) {
        let key = current ?? "<overview>"
        if !force, let cached = cache[key] { result = cached; error = nil; return }
        task?.cancel()
        result = nil
        error = nil
        loading = true
        let target = current
        task = Task {
            defer { self.loading = false }
            do {
                var args = ["analyze", "--json"]
                if let target { args.append(target) }
                let r = try await Mole.run(args)
                guard let start = r.output.firstIndex(of: "{") else {
                    throw MoleError.failed(r.status, r.output)
                }
                let decoded = try JSONDecoder().decode(AnalyzeResult.self, from: Data(r.output[start...].utf8))
                if Task.isCancelled { return }
                self.cache[key] = decoded
                self.result = decoded
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func open(_ path: String) { stack.append(path); load() }
    func up() { if stack.count > 1 { stack.removeLast(); load() } }
    func cancel() { task?.cancel(); loading = false }
}

struct AnalyzeView: View {
    @StateObject private var model = AnalyzeModel()
    @LocalState private var selection: AnalyzeResult.Entry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            if let e = model.error { ErrorBanner(message: e) }
            if model.loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Measuring \(model.current ?? "your disk")…").foregroundStyle(.secondary)
                    Text("Large folders can take a minute the first time.").font(.caption).foregroundStyle(.tertiary)
                    Button("Stop") { model.cancel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let r = model.result {
                list(r)
            } else {
                Spacer()
            }
        }
        .padding(20)
        .onAppear { if model.result == nil && !model.loading { model.load() } }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.up() } label: { Label("Up", systemImage: "arrow.up") }
                .disabled(model.stack.count <= 1)
                .help("Go to the enclosing folder")
            VStack(alignment: .leading, spacing: 1) {
                Text(model.current.map { ($0 as NSString).lastPathComponent } ?? "Disk overview").font(.headline)
                Text(model.current ?? "Biggest areas of your startup disk")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let total = model.result?.total_size, total > 0 {
                Text("Total \(Fmt.bytes(total))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button { chooseFolder() } label: { Label("Choose Folder…", systemImage: "folder") }
            Button { model.load(force: true) } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .disabled(model.loading)
        }
    }

    private func list(_ r: AnalyzeResult) -> some View {
        let maxSize = max(r.entries.map(\.size).max() ?? 1, 1)
        return List(r.entries, selection: $selection) { e in
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: e.path))
                    .resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(e.name).lineLimit(1)
                        if e.insight == true {
                            Text("Insight").font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.2)))
                        }
                    }
                    GeometryReader { g in
                        Capsule().fill(Color.indigo.opacity(0.15))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.indigo.gradient)
                                    .frame(width: max(2, g.size.width * CGFloat(Double(e.size) / Double(maxSize))))
                            }
                    }
                    .frame(height: 5)
                }
                Text(Fmt.bytes(e.size)).font(.callout.monospacedDigit()).frame(width: 90, alignment: .trailing)
                if e.is_dir {
                    Button { model.open(e.path) } label: { Image(systemName: "chevron.right.circle") }
                        .buttonStyle(.borderless)
                        .help("Open this folder")
                } else {
                    Color.clear.frame(width: 16)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if e.is_dir { model.open(e.path) } }
            .contextMenu {
                if e.is_dir { Button("Open in Analyze") { model.open(e.path) } }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: e.path)]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(e.path, forType: .string)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if r.entries.isEmpty { Text("This folder is empty.").foregroundStyle(.secondary) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Analyze"
        if panel.runModal() == .OK, let url = panel.url { model.open(url.path) }
    }
}
