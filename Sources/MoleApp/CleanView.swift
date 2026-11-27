import SwiftUI
import AppKit

/// Shared flow for Clean and Optimize: preview with --dry-run, confirm, then run for real.
@MainActor
final class PreviewRunModel: ObservableObject {
    enum Phase { case idle, previewing, previewed, running, finished }

    let command: String
    @Published var phase: Phase = .idle
    @Published var preview: Report?
    @Published var result: Report?
    @Published var error: String?
    @Published var ranAsAdmin = false
    let runner = Runner()

    init(command: String) { self.command = command }

    func runPreview() {
        error = nil
        result = nil
        let prior = phase
        phase = .previewing
        runner.start { [weak self] runner in
            guard let self else { return }
            guard let privilege = await AdminSession.shared.credential() else {
                self.phase = prior
                return
            }
            if case .root = privilege { self.ranAsAdmin = true } else { self.ranAsAdmin = false }
            do {
                let r = try await Mole.run([self.command, "--dry-run"], privilege: privilege, onLine: runner.lineHandler)
                self.preview = ReportParser.parse(r.output)
                if r.status != 0 && self.preview?.sections.isEmpty != false {
                    throw MoleError.failed(r.status, r.output)
                }
                self.phase = .previewed
            } catch is CancellationError {
                self.phase = self.preview == nil ? .idle : .previewed
            } catch {
                self.error = error.localizedDescription
                self.phase = self.preview == nil ? .idle : .previewed
            }
        }
    }

    func runForReal() {
        error = nil
        phase = .running
        runner.start { [weak self] runner in
            guard let self else { return }
            guard let privilege = await AdminSession.shared.credential() else {
                self.phase = .previewed
                return
            }
            if case .root = privilege { self.ranAsAdmin = true } else { self.ranAsAdmin = false }
            do {
                // stdin is closed right away, so Mole runs in its non-interactive mode.
                // As the user: user-level work only. In administrator mode (sudo): system files too.
                let r = try await Mole.run([self.command], privilege: privilege, onLine: runner.lineHandler)
                self.result = ReportParser.parse(r.output)
                if r.status != 0 { self.error = "mo \(self.command) exited with code \(r.status). See the log below." }
            } catch is CancellationError {
                self.error = "Stopped."
            } catch {
                self.error = error.localizedDescription
            }
            self.phase = .finished
        }
    }
}

struct CleanView: View {
    @StateObject private var model = PreviewRunModel(command: "clean")
    @LocalState private var onlyWork = true
    @LocalState private var confirming = false

    var body: some View {
        PreviewRunScreen(
            model: model,
            feature: .clean,
            heroTitle: "Free up disk space",
            intro: "FlashMac finds caches, logs, temporary files and leftovers from apps you already removed. Scan first to see everything — nothing is deleted until you confirm.",
            previewLabel: "Scan",
            runLabel: "Clean Now…",
            onlyWork: $onlyWork,
            onRun: { confirming = true }
        )
        .task { if DebugArgs.autoPreview && model.phase == .idle { model.runPreview() } }
        .sheet(isPresented: $confirming) {
            if let report = model.preview {
                CleanConfirmSheet(report: report) {
                    confirming = false
                    model.runForReal()
                } cancel: { confirming = false }
            }
        }
    }
}

struct PreviewRunScreen: View {
    @ObservedObject var model: PreviewRunModel
    @ObservedObject private var runner: Runner
    @ObservedObject private var admin = AdminSession.shared
    let feature: Feature
    let heroTitle: String
    let intro: String
    let previewLabel: String
    let runLabel: String
    @Binding var onlyWork: Bool
    let onRun: () -> Void

    init(model: PreviewRunModel, feature: Feature, heroTitle: String, intro: String,
         previewLabel: String, runLabel: String, onlyWork: Binding<Bool>, onRun: @escaping () -> Void) {
        self.model = model
        self.runner = model.runner
        self.feature = feature
        self.heroTitle = heroTitle
        self.intro = intro
        self.previewLabel = previewLabel
        self.runLabel = runLabel
        self._onlyWork = onlyWork
        self.onRun = onRun
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.phase {
                case .idle:
                    hero
                case .previewing, .running:
                    progress
                case .previewed:
                    VStack(alignment: .leading, spacing: 12) {
                        if let e = model.error { ErrorBanner(message: e) }
                        if let p = model.preview { ReportView(report: p, onlyWork: $onlyWork, isPreview: true) }
                    }
                    .padding(20)
                case .finished:
                    VStack(alignment: .leading, spacing: 10) {
                        if let e = model.error { ErrorBanner(message: e) }
                        if let r = model.result, !r.summary.isEmpty {
                            SummaryBox(lines: r.summary, tint: .green, title: "Done")
                        }
                        Text("Full log").font(.headline)
                        LogView(text: runner.log)
                    }
                    .padding(20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.phase != .idle {
                Divider()
                actionBar
            }
        }
    }

    // Idle: big, centred buttons.
    private var hero: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: feature.symbol)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(feature.tint.gradient, in: RoundedRectangle(cornerRadius: 24))
            Text(heroTitle).font(.title.bold())
            Text(intro)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            if let e = model.error { ErrorBanner(message: e).frame(maxWidth: 520) }
            HStack(spacing: 14) {
                Button { model.runPreview() } label: {
                    Label(previewLabel, systemImage: "magnifyingglass").frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)
                .tint(feature.tint)
                .keyboardShortcut(.defaultAction)
                Button(action: onRun) {
                    Label(runLabel, systemImage: "play.fill").frame(minWidth: 150)
                }
                .buttonStyle(.bordered)
                .disabled(true)
            }
            .controlSize(.extraLarge)
            Text("Scan first — the \(runLabel.replacingOccurrences(of: "…", with: "")) button unlocks after you've seen the preview.")
                .font(.caption).foregroundStyle(.tertiary)
            AdminModeNote()
                .padding(.top, 6)
            Spacer()
        }
        .padding(24)
    }

    // Running: progress in the middle, buttons move to the bottom bar.
    private var progress: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).padding(.top, 24)
            Text(model.phase == .running ? "Running mo \(model.command)…" : "Scanning — preview only, nothing is changed")
                .font(.title3.bold())
            Text(runner.lastLine.isEmpty ? " " : runner.lastLine)
                .font(.callout.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 600)
            LogView(text: runner.log).padding(.horizontal, 20).padding(.bottom, 12)
        }
    }

    private var statusText: String {
        switch model.phase {
        case .idle: return ""
        case .previewing: return "Scanning…"
        case .running: return "Working… please keep FlashMac open"
        case .previewed:
            let s = model.preview?.summary ?? []
            if let line = s.first(where: { $0.hasPrefix("Potential space") }) {
                return line.components(separatedBy: "|").first.map { $0.replacingOccurrences(of: "Potential space:", with: "Can free").trimmingCharacters(in: .whitespaces) } ?? line
            }
            return s.first(where: { $0.hasPrefix("Would apply") }) ?? "Preview ready"
        case .finished: return model.error == nil ? "Finished" : "Finished with problems"
        }
    }

    // After a scan: a fixed bar at the bottom with large buttons.
    private var actionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(statusText).font(.headline)
                if model.ranAsAdmin {
                    Label("Administrator mode — system files included", systemImage: "lock.open.fill")
                        .font(.caption).foregroundStyle(.red)
                } else {
                    Text("Your files only — turn on Administrator mode to include system files")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            AdminToggle(compact: true).disabled(runner.isRunning)
            if runner.isRunning {
                Button(role: .cancel) { runner.cancel() } label: {
                    Label("Stop", systemImage: "stop.fill").frame(minWidth: 100)
                }
                .keyboardShortcut(.cancelAction)
            } else {
                Button { model.runPreview() } label: {
                    Label(model.phase == .finished ? "Scan Again" : "Rescan", systemImage: "arrow.clockwise").frame(minWidth: 110)
                }
                Button(action: onRun) {
                    Label(runLabel, systemImage: "play.fill").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .tint(feature == .clean ? .red : feature.tint)
                .disabled(model.phase != .previewed)
                // No Return shortcut: running a clean must always be a deliberate click.
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

/// Admin toggle with a one-line explanation, used on the idle screens.
struct AdminModeNote: View {
    @ObservedObject private var admin = AdminSession.shared
    var body: some View {
        VStack(spacing: 4) {
            AdminToggle()
            Text(admin.enabled
                 ? "On: FlashMac runs with your administrator password and also cleans system caches, logs and temporary files."
                 : "Off: only your own user files are touched. Turn on to include system files.")
                .font(.caption)
                .foregroundStyle(admin.enabled ? Color.red : Color.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
    }
}

struct ReportView: View {
    let report: Report
    @Binding var onlyWork: Bool
    let isPreview: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !report.summary.isEmpty {
                SummaryBox(lines: report.summary, tint: .orange, title: isPreview ? "Preview — nothing was changed" : "Result")
            }
            HStack {
                Text("\(report.sections.count) categories checked · \(report.actionCount) items to act on")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Toggle("Only show items with work to do", isOn: $onlyWork).toggleStyle(.checkbox)
            }
            List {
                if !report.header.isEmpty {
                    Section("Notes") {
                        ForEach(report.header.filter { $0.kind != .info || !$0.text.hasPrefix("/") }) { ReportLineRow(line: $0) }
                    }
                }
                ForEach(report.sections.filter { !onlyWork || $0.hasWork }) { s in
                    ReportSectionView(section: s)
                }
            }
            .listStyle(.inset)
        }
    }
}

struct SummaryBox: View {
    let lines: [String]
    let tint: Color
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ForEach(lines.filter { !$0.lowercased().contains("whitelist") }, id: \.self) { l in
                if l.hasPrefix("Detailed file list:") {
                    let path = l.replacingOccurrences(of: "Detailed file list:", with: "").trimmingCharacters(in: .whitespaces)
                    Button("Open detailed file list") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        .buttonStyle(.link)
                } else {
                    Text(l).textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.1)))
    }
}

struct CleanConfirmSheet: View {
    let report: Report
    let confirm: () -> Void
    let cancel: () -> Void

    private var work: [ReportSection] { report.sections.filter(\.hasWork) }
    private var potential: String {
        report.summary.first { $0.hasPrefix("Potential space") } ?? "Total: \(Fmt.bytes(work.reduce(0) { $0 + $1.totalBytes }))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Clean these items?", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(.orange)
            Text("FlashMac will permanently delete the caches, logs and temporary files below. \(potential).")
            Text((AdminSession.shared.enabled
                  ? "Administrator mode is on, so system-level caches, logs and temporary files are included. "
                  : "Administrator mode is off, so system-level files are skipped. ")
                 + "Protected (whitelisted) paths are never touched. The real run re-scans, so totals can differ slightly from the preview.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(work) { s in
                    Section(s.title) {
                        ForEach(s.actions) { a in
                            HStack {
                                Text(a.text)
                                Spacer()
                                if let size = a.size { Text(size).monospacedDigit().foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 280)
            HStack {
                Spacer()
                // Return and Esc both cancel; deleting needs a click on the red button.
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", action: cancel)          // invisible, so Esc cancels too
                    .keyboardShortcut(.cancelAction)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                Button("Clean \(report.actionCount) Items", role: .destructive, action: confirm)
                    .buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .padding(22)
        .frame(width: 620, height: 560)
    }
}

struct OptimizeView: View {
    @StateObject private var model = PreviewRunModel(command: "optimize")
    @LocalState private var onlyWork = false
    @LocalState private var confirming = false

    var body: some View {
        PreviewRunScreen(
            model: model,
            feature: .optimize,
            heroTitle: "Refresh caches and services",
            intro: "FlashMac refreshes DNS, Finder and LaunchServices caches, repairs preferences and tidies system services. Preview first to see every step.",
            previewLabel: "Preview Steps",
            runLabel: "Run Optimize…",
            onlyWork: $onlyWork,
            onRun: { confirming = true }
        )
        .task { if DebugArgs.autoPreview && model.phase == .idle { model.runPreview() } }
        .alert("Run Optimize now?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Run Optimize") { model.runForReal() }
        } message: {
            Text("FlashMac will run the \(model.preview?.sections.count ?? 0) maintenance steps from the preview. Finder and the Dock may restart briefly." + (AdminSession.shared.enabled ? " Administrator mode is on, so system-level steps run too." : " Steps that need an administrator password are skipped."))
        }
    }
}

/// Testing aids. `--auto-preview` starts the dry-run preview on Clean/Optimize;
/// `--auto-plan <app name>` selects that app on Uninstall and opens the (dry-run) confirmation.
/// Neither ever runs a real clean or uninstall.
enum DebugArgs {
    static let args = ProcessInfo.processInfo.arguments
    static var autoPreview: Bool { args.contains("--auto-preview") }
    static var autoPlanApp: String? {
        guard let i = args.firstIndex(of: "--auto-plan"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
