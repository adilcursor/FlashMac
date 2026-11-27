import SwiftUI

struct StatusSnapshot: Decodable {
    struct Hardware: Decodable {
        let model: String?
        let cpu_model: String?
        let total_ram: String?
        let disk_size: String?
        let os_version: String?
    }
    struct CPU: Decodable {
        let usage: Double
        let per_core: [Double]?
        let load1: Double?
        let load5: Double?
        let load15: Double?
        let core_count: Int?
        let p_core_count: Int?
        let e_core_count: Int?
    }
    struct Memory: Decodable {
        let used: Double
        let total: Double
        let available: Double?
        let used_percent: Double
        let swap_used: Double?
        let cached: Double?
    }
    struct Disk: Decodable, Identifiable {
        let mount: String
        let used: Double
        let total: Double
        let used_percent: Double
        let fstype: String?
        let external: Bool?
        var id: String { mount }
    }
    struct DiskIO: Decodable { let read_rate: Double?; let write_rate: Double? }
    struct Net: Decodable, Identifiable {
        let name: String
        let rx_rate_mbs: Double?
        let tx_rate_mbs: Double?
        let ip: String?
        var id: String { name }
    }
    struct Proc: Decodable, Identifiable {
        let pid: Int
        let name: String
        let cpu: Double
        let memory: Double
        let memory_bytes: Double?
        var id: Int { pid }
    }
    struct Thermal: Decodable { let cpu_temp: Double?; let system_power: Double? }

    let host: String?
    let uptime: String?
    let procs: Int?
    let hardware: Hardware?
    let health_score: Int?
    let health_score_msg: String?
    let cpu: CPU?
    let memory: Memory?
    let disks: [Disk]?
    let trash_size: Double?
    let disk_io: DiskIO?
    let network: [Net]?
    let thermal: Thermal?
    let top_processes: [Proc]?
}

@MainActor
final class StatusModel: ObservableObject {
    @Published var snapshot: StatusSnapshot?
    @Published var error: String?
    @Published var loading = false
    @Published var lastUpdated: Date?

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await Mole.run(["status", "--json"])
            guard let start = r.output.firstIndex(of: "{") else {
                throw MoleError.badOutput(String(r.output.prefix(300)))
            }
            let json = Data(r.output[start...].utf8)
            snapshot = try JSONDecoder().decode(StatusSnapshot.self, from: json)
            lastUpdated = Date()
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct StatusView: View {
    @StateObject private var model = StatusModel()
    @LocalState private var autoRefresh = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    if let d = model.lastUpdated {
                        Text("Updated \(d.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.loading { ProgressView().controlSize(.small) }
                    Spacer()
                    Toggle("Live (every 3 s)", isOn: $autoRefresh).toggleStyle(.switch).controlSize(.small)
                    Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .keyboardShortcut("r", modifiers: .command)
                }
                if let e = model.error { ErrorBanner(message: e) }
                if let s = model.snapshot {
                    content(s)
                } else if model.error == nil {
                    HStack { Spacer(); ProgressView("Reading system status…"); Spacer() }.padding(.top, 80)
                }
            }
            .padding(20)
        }
        .task(id: autoRefresh) {
            await model.refresh()
            while autoRefresh && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                await model.refresh()
            }
        }
    }

    @ViewBuilder
    private func content(_ s: StatusSnapshot) -> some View {
        HStack(alignment: .top, spacing: 16) {
            HealthCard(score: s.health_score ?? 0, message: s.health_score_msg ?? "")
            Card(title: "This Mac", symbol: "desktopcomputer") {
                InfoRow("Model", s.hardware?.model)
                InfoRow("Chip", s.hardware?.cpu_model)
                InfoRow("Memory", s.hardware?.total_ram)
                InfoRow("Disk", s.hardware?.disk_size)
                InfoRow("System", s.hardware?.os_version)
                InfoRow("Uptime", s.uptime)
                InfoRow("Processes", s.procs.map(String.init))
            }
        }
        .fixedSize(horizontal: false, vertical: true)

        HStack(alignment: .top, spacing: 16) {
            if let c = s.cpu {
                Card(title: "CPU", symbol: "cpu") {
                    Meter(label: "Usage", value: c.usage / 100, detail: Fmt.percent(c.usage), tint: .blue)
                    if let cores = c.per_core, !cores.isEmpty {
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(Array(cores.enumerated()), id: \.offset) { _, v in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.blue.opacity(0.35 + 0.65 * min(v, 100) / 100))
                                    .frame(height: max(3, 50 * min(v, 100) / 100))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(height: 50, alignment: .bottom)
                        .help("Per-core usage")
                    }
                    if let l1 = c.load1, let l5 = c.load5, let l15 = c.load15 {
                        InfoRow("Load", String(format: "%.2f  %.2f  %.2f", l1, l5, l15))
                    }
                    if let p = c.p_core_count, let e = c.e_core_count {
                        InfoRow("Cores", "\(p) performance + \(e) efficiency")
                    }
                }
            }
            if let m = s.memory {
                Card(title: "Memory", symbol: "memorychip") {
                    Meter(label: "Used", value: m.used_percent / 100,
                          detail: "\(Fmt.bytes(m.used)) of \(Fmt.bytes(m.total))", tint: .purple)
                    InfoRow("Available", m.available.map(Fmt.bytes))
                    InfoRow("Cached", m.cached.map(Fmt.bytes))
                    InfoRow("Swap used", m.swap_used.map(Fmt.bytes))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)

        HStack(alignment: .top, spacing: 16) {
            Card(title: "Disks", symbol: "internaldrive") {
                ForEach(s.disks ?? []) { d in
                    Meter(label: d.mount + ((d.external ?? false) ? "  (external)" : ""),
                          value: d.used_percent / 100,
                          detail: "\(Fmt.bytes(d.total - d.used)) free of \(Fmt.bytes(d.total))",
                          tint: d.used_percent > 85 ? .red : .teal)
                }
                if let t = s.trash_size { InfoRow("Trash", Fmt.bytes(t)) }
                if let io = s.disk_io {
                    InfoRow("Disk I/O", String(format: "read %.1f MB/s · write %.1f MB/s", io.read_rate ?? 0, io.write_rate ?? 0))
                }
            }
            Card(title: "Network", symbol: "network") {
                ForEach((s.network ?? []).filter { !($0.ip ?? "").isEmpty }) { n in
                    InfoRow(n.name, "\(n.ip ?? "")   ↓ \(String(format: "%.2f", n.rx_rate_mbs ?? 0)) ↑ \(String(format: "%.2f", n.tx_rate_mbs ?? 0)) MB/s")
                }
                if let w = s.thermal?.system_power, w > 0 {
                    InfoRow("System power", String(format: "%.1f W", w))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)

        if let procs = s.top_processes, !procs.isEmpty {
            Card(title: "Top processes", symbol: "list.bullet.rectangle") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Process").bold(); Text("PID").bold(); Text("CPU").bold(); Text("Memory").bold()
                    }
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(procs.prefix(10)) { p in
                        GridRow {
                            Text(p.name).lineLimit(1)
                            Text("\(p.pid)").monospacedDigit().foregroundStyle(.secondary)
                            Text(String(format: "%.1f%%", p.cpu)).monospacedDigit()
                            Text(p.memory_bytes.map(Fmt.bytes) ?? String(format: "%.1f%%", p.memory)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.15)))
    }
}

struct InfoRow: View {
    let label: String
    let value: String?
    init(_ label: String, _ value: String?) { self.label = label; self.value = value }
    var body: some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
            .font(.callout)
        }
    }
}

struct Meter: View {
    let label: String
    let value: Double
    let detail: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(detail).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(value, 0), 1)).tint(tint)
        }
    }
}

struct HealthCard: View {
    let score: Int
    let message: String
    var color: Color { score >= 80 ? .green : score >= 60 ? .orange : .red }
    var body: some View {
        VStack(spacing: 10) {
            Text("Health").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: 12)
                Circle().trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(score)").font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, height: 120)
            .animation(.easeOut, value: score)
        }
        .padding(16)
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.15)))
    }
}
