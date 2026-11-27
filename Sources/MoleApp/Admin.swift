import SwiftUI
import AppKit

/// Administrator mode: when on, Clean / Optimize / Uninstall run `mo` through `sudo`
/// so Mole can also clear system-level caches, logs and temporary files.
///
/// The password is typed by the user into the app's own sheet, checked with `sudo -v`,
/// kept in memory only for as long as the app is open, and never written to disk.
@MainActor
final class AdminSession: ObservableObject {
    static let shared = AdminSession()

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "adminMode")
            if !enabled { password = nil }
        }
    }
    @Published var prompting = false
    @Published private(set) var unlocked = false

    private var password: String? { didSet { unlocked = password != nil } }
    private var waiter: CheckedContinuation<String?, Never>?

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "adminMode")
    }

    var userName: String { NSUserName() }

    /// Returns `.user` when admin mode is off, `.root(password)` when on and unlocked,
    /// or nil if the user cancelled the password prompt (the run should not start).
    func credential() async -> Mole.Privilege? {
        guard enabled else { return .user }
        if let pw = password, await Mole.checkPassword(pw) { return .root(pw) }
        password = nil
        if waiter != nil { return nil }
        let pw: String? = await withCheckedContinuation { cont in
            waiter = cont
            prompting = true
        }
        return pw.map { .root($0) }
    }

    /// Called by the password sheet. Returns false if the password was wrong.
    func submit(_ pw: String) async -> Bool {
        guard await Mole.checkPassword(pw) else { return false }
        password = pw
        prompting = false
        waiter?.resume(returning: pw)
        waiter = nil
        return true
    }

    func cancelPrompt() {
        prompting = false
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func lock() { password = nil }
}

struct AdminToggle: View {
    @ObservedObject var admin = AdminSession.shared
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $admin.enabled) {
                Label(compact ? "Admin" : "Administrator mode",
                      systemImage: admin.enabled ? "lock.open.fill" : "lock.fill")
            }
            .toggleStyle(.switch)
            .tint(.red)
            .help("Run FlashMac with administrator rights so it can also clean system caches, logs and temporary files.")
        }
    }
}

struct AdminPasswordSheet: View {
    @ObservedObject var admin = AdminSession.shared
    @LocalState private var password = ""
    @LocalState private var checking = false
    @LocalState private var wrong = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill").font(.system(size: 34)).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Administrator access").font(.title2.bold())
                    Text("FlashMac needs your Mac password to clean system files.").foregroundStyle(.secondary)
                }
            }
            Text("Enter the password for \(admin.userName). It is checked with sudo, kept only in memory while FlashMac is open, and never saved.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if wrong {
                Text("That password didn't work. Try again.").foregroundStyle(.red).font(.callout)
            }
            HStack {
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { admin.cancelPrompt() }.keyboardShortcut(.cancelAction)
                Button("Unlock", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || checking)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private func submit() {
        guard !password.isEmpty, !checking else { return }
        checking = true
        wrong = false
        let pw = password
        Task {
            let ok = await admin.submit(pw)
            checking = false
            if !ok { wrong = true; password = "" } else { password = "" }
        }
    }
}
