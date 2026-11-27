import Foundation

// MARK: - Running the `mo` command

enum MoleError: LocalizedError {
    case notFound
    case failed(Int32, String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Couldn't find the `mo` command. Install Mole with Homebrew: brew install mole"
        case .failed(let code, let output):
            return "mo exited with code \(code).\n\(String(output.suffix(800)))"
        case .badOutput(let detail):
            return "Couldn't read Mole's output: \(detail)"
        }
    }
}

struct MoleResult {
    let status: Int32
    let output: String
}

/// Collects process output, splitting it into ANSI-free lines.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var lines: [String] = []
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let chunk = String(decoding: data, as: UTF8.self)
        var emitted: [String] = []
        lock.lock()
        pending += chunk
        while let idx = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let line = Mole.stripANSI(String(pending[..<idx]))
            pending = String(pending[pending.index(after: idx)...])
            lines.append(line)
            emitted.append(line)
        }
        lock.unlock()
        if let onLine { emitted.forEach(onLine) }
    }

    func finish() {
        lock.lock()
        var last: String?
        if !pending.isEmpty {
            last = Mole.stripANSI(pending)
            lines.append(last!)
            pending = ""
        }
        lock.unlock()
        if let last, let onLine { onLine(last) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var resumed = false
    /// Returns true only the first time it is called.
    func claimResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

enum Mole {
    static let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Path to the user's installed `mo` binary.
    static let executable: String? = {
        let fm = FileManager.default
        let candidates = ["/opt/homebrew/bin/mo", "/usr/local/bin/mo",
                          NSHomeDirectory() + "/.local/bin/mo", "/opt/homebrew/bin/mole", "/usr/local/bin/mole"]
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return found }
        // Fall back to the user's login shell PATH.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v mo"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        return bundledExecutable
    }()

    /// Copy of Mole shipped inside Mole.app (Contents/Resources/mole), used on Macs without `mo`.
    static let bundledExecutable: String? = {
        guard let res = Bundle.main.resourcePath else { return nil }
        let path = res + "/mole/bin/mole"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()

    static var usingBundledCopy: Bool { executable != nil && executable == bundledExecutable }

    /// How to run mo: as the current user, or as root through sudo with the user's password.
    enum Privilege { case user, root(String) }

    /// Checks an administrator password with sudo without running anything else.
    static func checkPassword(_ password: String) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                p.arguments = ["-S", "-k", "-p", "", "/usr/bin/true"]
                let inPipe = Pipe()
                p.standardInput = inPipe
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: false); return }
                inPipe.fileHandleForWriting.write(Data((password + "\n").utf8))
                try? inPipe.fileHandleForWriting.close()
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
    }

    private static let ansiRegex = try! NSRegularExpression(pattern: "\u{1B}(\\[[0-9;?]*[A-Za-z]|\\][^\u{07}]*\u{07}|[()][A-Z0-9])")

    static func stripANSI(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return ansiRegex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    /// Runs `mo` with the given arguments. Output (stdout + stderr) is streamed line by line
    /// to `onLine` and returned in full. `input` is written to stdin, which is then closed,
    /// so Mole always runs in its non-interactive mode. Cancelling the task terminates mo.
    static func run(_ args: [String],
                    input: String? = nil,
                    privilege: Privilege = .user,
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> MoleResult {
        guard let moPath = executable else { throw MoleError.notFound }
        var exe = moPath
        var args = args
        var input = input
        if case .root(let password) = privilege {
            // sudo reads the password from the first line of stdin, sets SUDO_USER so Mole
            // still treats this user's home as the target, then runs mo as root. Mole sees
            // an active admin session and includes its system-level cleanup.
            let home = NSHomeDirectory()
            exe = "/usr/bin/sudo"
            args = ["-S", "-k", "-p", "", "/usr/bin/env", "HOME=\(home)", "PATH=\(extraPath)",
                    "NO_COLOR=1", "TERM=dumb", "LANG=en_US.UTF-8", moPath] + args
            input = password + "\n" + (input ?? "")
        }
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MoleResult, Error>) in
                let p = box.process
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = extraPath + ":" + (env["PATH"] ?? "")
                env["NO_COLOR"] = "1"
                env["TERM"] = "dumb"
                env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
                p.environment = env
                p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

                let out = Pipe()
                let inPipe = Pipe()
                p.standardOutput = out
                p.standardError = out
                p.standardInput = inPipe

                let collector = OutputCollector(onLine: onLine)
                let eof = DispatchSemaphore(value: 0)
                out.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    if d.isEmpty {
                        h.readabilityHandler = nil
                        eof.signal()
                    } else {
                        collector.append(d)
                    }
                }
                p.terminationHandler = { proc in
                    // Give the reader a moment to drain; background helpers may hold the pipe open.
                    DispatchQueue.global().async {
                        _ = eof.wait(timeout: .now() + 1.5)
                        collector.finish()
                        if box.claimResume() {
                            cont.resume(returning: MoleResult(status: proc.terminationStatus, output: collector.text))
                        }
                    }
                }
                do {
                    try p.run()
                } catch {
                    if box.claimResume() { cont.resume(throwing: error) }
                    return
                }
                if let input, let data = input.data(using: .utf8) {
                    inPipe.fileHandleForWriting.write(data)
                }
                try? inPipe.fileHandleForWriting.close()
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }

    static func version() async -> String? {
        guard let r = try? await run(["--version"]) else { return nil }
        for line in r.output.split(separator: "\n") where line.hasPrefix("Mole version") {
            return line.replacingOccurrences(of: "Mole version", with: "").trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

// MARK: - Formatting helpers

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    static func bytes(_ n: Double) -> String { bytes(Int64(n)) }
    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v) }

    /// Parses sizes printed by Mole, e.g. "26.29GB", "550KB", "0B".
    static func parseSize(_ s: String) -> Int64? {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        for (u, m) in units where t.hasSuffix(u) {
            if let v = Double(t.dropLast(u.count)) { return Int64(v * m) }
        }
        return nil
    }
}

// MARK: - Parsing Mole's text reports (clean / optimize)

struct ReportLine: Identifiable, Hashable {
    enum Kind { case action, ok, info, warning }
    let id = UUID()
    let kind: Kind
    let text: String
    let size: String?

    var bytes: Int64 { size.flatMap(Fmt.parseSize) ?? 0 }
}

struct ReportSection: Identifiable {
    let id = UUID()
    let title: String
    var lines: [ReportLine]

    var actions: [ReportLine] { lines.filter { $0.kind == .action } }
    var totalBytes: Int64 { actions.reduce(0) { $0 + $1.bytes } }
    var hasWork: Bool { !actions.isEmpty }
}

struct Report {
    var header: [ReportLine] = []
    var sections: [ReportSection] = []
    var summary: [String] = []

    var actionCount: Int { sections.reduce(0) { $0 + $1.actions.count } }
}

enum ReportParser {
    private static let sizeRegex = try! NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?(?:TB|GB|MB|KB|B))\\b")

    static func parse(_ text: String) -> Report {
        var report = Report()
        var current: ReportSection?
        var inSummary = false

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("=====") {
                inSummary.toggle()
                if inSummary, let c = current { report.sections.append(c); current = nil }
                continue
            }
            if inSummary { report.summary.append(line); continue }
            if line.hasPrefix("➤") {
                if let c = current { report.sections.append(c) }
                current = ReportSection(title: String(line.dropFirst()).trimmingCharacters(in: .whitespaces), lines: [])
                continue
            }
            guard let item = parseLine(line) else { continue }
            if current != nil { current!.lines.append(item) } else { report.header.append(item) }
        }
        if let c = current { report.sections.append(c) }
        return report
    }

    static func parseLine(_ line: String) -> ReportLine? {
        guard let first = line.unicodeScalars.first else { return nil }
        let symbols: [Unicode.Scalar: ReportLine.Kind] = [
            "→": .action, "✓": .ok, "✗": .warning, "⚠": .warning,
            "◎": .info, "•": .info, "↳": .info, "☞": .info, "⚙": .info, "◆": .info, "ℹ": .info,
        ]
        let kind = symbols[first] ?? .info
        var body = line
        if symbols[first] != nil {
            body = String(String.UnicodeScalarView(line.unicodeScalars.dropFirst()))
                .trimmingCharacters(in: .whitespaces)
        }
        if body.hasSuffix(" dry") { body = String(body.dropLast(4)) }

        var size: String?
        let ns = body as NSString
        if let m = sizeRegex.matches(in: body, range: NSRange(location: 0, length: ns.length)).last {
            size = ns.substring(with: m.range(at: 1))
            // Drop the ", 12.3MB" tail from the title.
            let prefix = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
            let suffix = ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespaces)
            if suffix.isEmpty, prefix.hasSuffix(",") {
                body = String(prefix.dropLast())
            }
        }
        body = body.replacingOccurrences(of: " · ", with: " — ").replacingOccurrences(of: "\u{00B7}", with: "—")
        return ReportLine(kind: kind, text: body, size: size)
    }
}
