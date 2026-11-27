import SwiftUI
import AppKit

@main
struct MoleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("FlashMac") {
            RootView()
                .frame(minWidth: 820, minHeight: 600)
        }
        .defaultSize(width: 980, height: 720)
        .windowToolbarStyle(.unified)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Navigation

enum Feature: String, CaseIterable, Identifiable, Hashable {
    case clean, uninstall, optimize, analyze, status
    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: "Clean"
        case .uninstall: "Uninstall"
        case .optimize: "Optimize"
        case .analyze: "Analyze"
        case .status: "Status"
        }
    }
    var subtitle: String {
        switch self {
        case .clean: "Free up disk space"
        case .uninstall: "Remove apps completely"
        case .optimize: "Refresh caches and services"
        case .analyze: "Explore disk usage"
        case .status: "Monitor system health"
        }
    }
    var symbol: String {
        switch self {
        case .clean: "sparkles"
        case .uninstall: "trash"
        case .optimize: "bolt.circle"
        case .analyze: "chart.pie"
        case .status: "waveform.path.ecg"
        }
    }
    var tint: Color {
        switch self {
        case .clean: .teal
        case .uninstall: .red
        case .optimize: .orange
        case .analyze: .indigo
        case .status: .green
        }
    }
}

struct RootView: View {
    @LocalState private var path: [Feature] = []
    @ObservedObject private var admin = AdminSession.shared

    var body: some View {
        NavigationStack(path: $path) {
            HomeView { path.append($0) }
                .navigationDestination(for: Feature.self) { feature in
                    FeatureScreen(feature: feature) { if !path.isEmpty { path.removeLast() } }
                        .navigationBarBackButtonHidden(true)
                        .navigationTitle(feature.title)
                }
                .navigationTitle("FlashMac")
        }
        .sheet(isPresented: Binding(get: { admin.prompting },
                                    set: { if !$0 && admin.prompting { admin.cancelPrompt() } })) {
            AdminPasswordSheet()
        }
        .task {
            // Optional launch arguments: --screen <clean|uninstall|optimize|analyze|status>
            // and --back-after <seconds> (triggers the Back action; used for testing).
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--screen"), i + 1 < args.count, let f = Feature(rawValue: args[i + 1]) {
                path = [f]
                if let j = args.firstIndex(of: "--back-after"), j + 1 < args.count, let s = Double(args[j + 1]) {
                    try? await Task.sleep(for: .seconds(s))
                    if !path.isEmpty { path.removeLast() }
                }
            }
        }
    }
}

struct FeatureScreen: View {
    let feature: Feature
    let goBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(feature: feature, goBack: goBack)
            Divider()
            Group {
                switch feature {
                case .clean: CleanView()
                case .uninstall: UninstallView()
                case .optimize: OptimizeView()
                case .analyze: AnalyzeView()
                case .status: StatusView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ScreenHeader: View {
    let feature: Feature
    let goBack: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: goBack) {
                Label("Back", systemImage: "chevron.left")
                    .font(.body.weight(.medium))
            }
            .controlSize(.large)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to home (⌘[)")

            Image(systemName: feature.symbol)
                .font(.title2)
                .foregroundStyle(feature.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(feature.title).font(.title2.bold())
                Text(feature.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - Home

enum Brand {
    static let name = "FlashMac"
    static let tagline = "Give Your Mac Room to Fly"
    static let gradient = LinearGradient(colors: [Color(red: 0.42, green: 0.27, blue: 0.86),
                                                  Color(red: 0.10, green: 0.68, blue: 0.70)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct HomeView: View {
    let open: (Feature) -> Void
    @LocalState private var version: String?

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 40) {
                    hero
                    cards
                }
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
        .background(alignment: .top) {
            // Soft brand glow behind the header.
            Brand.gradient.opacity(0.10)
                .frame(height: 360)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .task { version = await Mole.version() }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 92, height: 92)
                .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .purple.opacity(0.35), radius: 18, y: 8)
            Text(Brand.name)
                .font(.system(size: 42, weight: .bold, design: .rounded))
            Text(Brand.tagline)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    /// One row of five when the window is wide, otherwise 3 + 2 (or 2 + 2 + 1), always centred.
    private var cards: some View {
        let all = Feature.allCases
        return ViewThatFits(in: .horizontal) {
            row(all)
            VStack(spacing: 18) { row(Array(all[0..<3])); row(Array(all[3...])) }
            VStack(spacing: 18) { row(Array(all[0..<2])); row(Array(all[2..<4])); row([all[4]]) }
        }
    }

    private func row(_ features: [Feature]) -> some View {
        HStack(spacing: 18) {
            ForEach(features) { f in FeatureCard(feature: f) { open(f) } }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Group {
                    if Mole.executable != nil {
                        Label("Powered by Mole" + (version.map { " \($0)" } ?? "")
                              + (Mole.usingBundledCopy ? " (built in)" : ""),
                              systemImage: "checkmark.seal")
                    } else {
                        Label("Mole engine not found. Install it with: brew install mole",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(Mole.executable ?? "")
                Spacer()
                AdminToggle()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

struct FeatureCard: View {
    let feature: Feature
    let action: () -> Void
    @LocalState private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: feature.symbol)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(feature.tint.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title2)
                        .foregroundStyle(hovering ? feature.tint : Color.secondary.opacity(0.35))
                }
                Spacer(minLength: 16)
                Text(feature.title).font(.title2.bold()).foregroundStyle(.primary)
                Text(feature.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .padding(.top, 2)
            }
            .padding(18)
            .frame(width: 200, height: 190, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(hovering ? feature.tint.opacity(0.7) : Color.secondary.opacity(0.15), lineWidth: hovering ? 1.5 : 1))
            .shadow(color: hovering ? feature.tint.opacity(0.25) : .clear, radius: 14, y: 6)
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(feature.subtitle)
    }
}

// MARK: - Shared pieces

struct RunningBanner: View {
    let title: String
    let lastLine: String
    var onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(lastLine.isEmpty ? " " : lastLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let onCancel { Button("Stop", action: onCancel) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        Label {
            Text(message).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
    }
}

struct LogView: View {
    let text: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Color.clear.frame(height: 1).id("end")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct ReportSectionView: View {
    let section: ReportSection
    @LocalState private var expanded: Bool

    init(section: ReportSection) {
        self.section = section
        _expanded = LocalState(wrappedValue: section.hasWork)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(section.lines) { line in ReportLineRow(line: line) }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Image(systemName: section.hasWork ? "circle.inset.filled" : "checkmark.circle.fill")
                    .foregroundStyle(section.hasWork ? Color.orange : Color.green)
                Text(section.title).font(.headline)
                Spacer()
                if section.totalBytes > 0 {
                    Text(Fmt.bytes(section.totalBytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ReportLineRow: View {
    let line: ReportLine
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            Text(line.text)
                .foregroundStyle(line.kind == .info ? .secondary : .primary)
                .textSelection(.enabled)
            Spacer()
            if let size = line.size {
                Text(size)
                    .font(.callout.monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(0.12)))
            }
        }
        .padding(.leading, 6)
    }
    private var icon: String {
        switch line.kind {
        case .action: "arrow.right.circle"
        case .ok: "checkmark.circle"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        }
    }
    private var color: Color {
        switch line.kind {
        case .action: .orange
        case .ok: .green
        case .info: .secondary
        case .warning: .red
        }
    }
}

/// Thread-safe holder for the latest streamed output line, polled by the UI.
@MainActor
final class Runner: ObservableObject {
    @Published var isRunning = false
    @Published var lastLine = ""
    @Published var log = ""
    private var task: Task<Void, Never>?

    func start(_ work: @escaping @MainActor (Runner) async -> Void) {
        task?.cancel()
        isRunning = true
        lastLine = ""
        log = ""
        task = Task { @MainActor in
            await work(self)
            self.isRunning = false
        }
    }

    func cancel() { task?.cancel() }

    /// A callback usable from Mole.run that forwards lines to the UI.
    var lineHandler: @Sendable (String) -> Void {
        { [weak self] line in
            Task { @MainActor in
                guard let self else { return }
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { self.lastLine = t }
                self.log += line + "\n"
            }
        }
    }
}
