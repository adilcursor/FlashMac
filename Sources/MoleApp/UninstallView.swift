import SwiftUI
import AppKit
import Combine

struct InstalledApp: Decodable, Identifiable, Hashable {
    let name: String
    let bundle_id: String?
    let source: String?
    let uninstall_name: String
    let path: String
    let size: String?
    var id: String { path }
    var bytes: Int64 { size.flatMap(Fmt.parseSize) ?? 0 }
    var displayName: String { name.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}\u{200F}").union(.whitespaces)) }
}

struct UninstallPlan {
    struct AppFiles: Identifiable {
        let id = UUID()
        let title: String
        var files: [String]
    }
    var apps: [AppFiles] = []
    var summary: String?

    static func parse(_ text: String) -> UninstallPlan {
        var plan = UninstallPlan()
        var inFiles = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.contains("Files to be removed") { inFiles = true; continue }
            if line.hasPrefix("Would remove") { plan.summary = line }
            guard inFiles, !line.isEmpty else { continue }
            if line.hasPrefix("➤") || line.hasPrefix("=====") { inFiles = false; continue }
            if line.hasPrefix("◎") {
                let title = String(String.UnicodeScalarView(line.unicodeScalars.dropFirst()))
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: " ,", with: " ·")
                plan.apps.append(AppFiles(title: title, files: []))
            } else if let first = line.unicodeScalars.first, "✓✗•→".unicodeScalars.contains(first) {
                let path = String(String.UnicodeScalarView(line.unicodeScalars.dropFirst())).trimmingCharacters(in: .whitespaces)
                if plan.apps.isEmpty { plan.apps.append(AppFiles(title: "Files", files: [])) }
                plan.apps[plan.apps.count - 1].files.append(path)
            }
        }
        return plan
    }
}

@MainActor
final class UninstallModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var loading = false
    @Published var error: String?
    @Published var selected: Set<InstalledApp.ID> = []
    @Published var plan: UninstallPlan?
    @Published var planning = false
    @Published var finishedLog: String?
    let runner = Runner()
    private var forward: AnyCancellable?

    init() {
        forward = runner.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var selectedApps: [InstalledApp] { apps.filter { selected.contains($0.id) } }

    func loadList() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await Mole.run(["uninstall", "--list"])
            guard let start = r.output.firstIndex(of: "[") else { throw MoleError.failed(r.status, r.output) }
            let list = try JSONDecoder().decode([InstalledApp].self, from: Data(r.output[start...].utf8))
            apps = list.sorted { $0.bytes > $1.bytes }
            selected = selected.filter { id in apps.contains { $0.id == id } }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Runs `mo uninstall --dry-run` for the selection and answers its prompts, to list the files.
    func preparePlan() async {
        let names = selectedApps.map(\.uninstall_name)
        guard !names.isEmpty else { return }
        planning = true
        defer { planning = false }
        do {
            let r = try await Mole.run(["uninstall", "--dry-run"] + names, input: "y\n\n")
            let p = UninstallPlan.parse(r.output)
            if p.apps.isEmpty { throw MoleError.failed(r.status, r.output) }
            plan = p
        } catch {
            self.error = error.localizedDescription
        }
    }

    func uninstall(permanent: Bool) {
        let names = selectedApps.map(\.uninstall_name)
        plan = nil
        finishedLog = nil
        runner.start { [weak self] runner in
            guard let self else { return }
            guard let privilege = await AdminSession.shared.credential() else { return }
            var args = ["uninstall"]
            if permanent { args.append("--permanent") }
            do {
                let r = try await Mole.run(args + names, input: "y\n\n", privilege: privilege, onLine: runner.lineHandler)
                if r.status != 0 { self.error = "mo uninstall exited with code \(r.status). See the log below." }
            } catch {
                self.error = error.localizedDescription
            }
            self.finishedLog = runner.log
            self.selected = []
            await self.loadList()
        }
    }
}

struct UninstallView: View {
    @StateObject private var model = UninstallModel()
    @LocalState private var search = ""
    @LocalState private var permanent = false
    private var runner: Runner { model.runner }

    private var filtered: [InstalledApp] {
        guard !search.isEmpty else { return model.apps }
        return model.apps.filter { $0.displayName.localizedCaseInsensitiveContains(search) || ($0.bundle_id ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("Search apps", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Text("\(model.apps.count) apps").foregroundStyle(.secondary).font(.callout)
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                AdminToggle(compact: true)
                    .help("Needed for apps installed by an administrator, such as Adobe apps.")
                Button { Task { await model.loadList() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                Button(role: .destructive) {
                    Task { await model.preparePlan() }
                } label: {
                    Label(model.selected.isEmpty ? "Uninstall…" : "Uninstall \(model.selected.count)…", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(model.selected.isEmpty || model.planning || runner.isRunning)
            }
            if model.planning {
                RunningBanner(title: "Finding every file that belongs to the selected apps (dry run)…", lastLine: "")
            }
            if runner.isRunning {
                RunningBanner(title: "Uninstalling…", lastLine: runner.lastLine)
            }
            if let e = model.error { ErrorBanner(message: e) }
            if let log = model.finishedLog {
                DisclosureGroup("Last uninstall log") { LogView(text: log).frame(height: 160) }
            }

            Table(filtered, selection: $model.selected) {
                TableColumn("App") { app in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 20, height: 20)
                        Text(app.displayName)
                    }
                }
                TableColumn("Size") { app in Text(app.size ?? "").monospacedDigit() }
                    .width(min: 70, ideal: 90, max: 120)
                TableColumn("Source") { app in Text(app.source ?? "").foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 90, max: 120)
                TableColumn("Location") { app in
                    Text(app.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .contextMenu(forSelectionType: InstalledApp.ID.self) { ids in
                if let id = ids.first, let app = model.apps.first(where: { $0.id == id }) {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
                }
            }
            Text("Select one or more apps (⌘-click for several), then choose Uninstall. You'll see every file FlashMac would remove before anything happens.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .task {
            if model.apps.isEmpty { await model.loadList() }
            if let name = DebugArgs.autoPlanApp, let app = model.apps.first(where: { $0.uninstall_name == name }) {
                model.selected = [app.id]
                await model.preparePlan()
            }
        }
        .sheet(isPresented: Binding(get: { model.plan != nil }, set: { if !$0 { model.plan = nil } })) {
            if let plan = model.plan {
                UninstallConfirmSheet(plan: plan, permanent: $permanent) {
                    model.uninstall(permanent: permanent)
                } cancel: { model.plan = nil }
            }
        }
    }
}

struct UninstallConfirmSheet: View {
    let plan: UninstallPlan
    @Binding var permanent: Bool
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Uninstall \(plan.apps.count == 1 ? "this app" : "these \(plan.apps.count) apps")?", systemImage: "trash.fill")
                .font(.title2.bold()).foregroundStyle(.red)
            Text(plan.summary.map { $0.replacingOccurrences(of: "Would remove", with: "FlashMac will remove") }
                 ?? "FlashMac will remove the app and the files listed below.")
            List {
                ForEach(plan.apps) { app in
                    Section(app.title) {
                        ForEach(app.files, id: \.self) { f in
                            Label(f, systemImage: f.hasSuffix(".app") ? "app" : "doc")
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(minHeight: 240)
            Toggle("Delete permanently instead of moving to the Trash", isOn: $permanent)
            if AdminSession.shared.enabled {
                Label("Administrator mode is on — FlashMac will run with your password.", systemImage: "lock.open.fill")
                    .font(.callout).foregroundStyle(.red)
            }
            Text(permanent ? "Files will be erased right away and can't be recovered."
                           : "Files go to the Trash, so you can put them back if needed.")
                .font(.callout).foregroundStyle(permanent ? .red : .secondary)
            HStack {
                Spacer()
                // Return and Esc both cancel; deleting needs a click on the red button.
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", action: cancel)          // invisible, so Esc cancels too
                    .keyboardShortcut(.cancelAction)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                Button(permanent ? "Delete Permanently" : "Move to Trash", role: .destructive, action: confirm)
                    .buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .padding(22)
        .frame(width: 620, height: 540)
    }
}
