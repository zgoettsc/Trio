import SwiftUI
import Swinject

/// Settings screen for the telemetry feature. Lives under AI Analysis → Configuration.
///
/// What the user does here:
/// 1. Generate a fine-grained Personal Access Token on github.com scoped to
///    `Contents: Read and Write` on the trio repo.
/// 2. Paste it into the PAT field (stored in iOS Keychain, not UserDefaults).
/// 3. (Optional) Edit repo / branch fields. Defaults are correct for most cases.
/// 4. Tap "Initialize Branch" once on first setup — creates the orphan telemetry branch.
/// 5. Toggle "Enable Telemetry" on. Pushes happen automatically on meal-window close
///    and app foreground.
struct TelemetryConfigView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    @StateObject private var vm = ViewModel()
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            // MARK: PAT input
            Section(
                header: Text("GitHub Personal Access Token"),
                footer: Text(
                    "Create a fine-grained PAT scoped to the trio repo with Contents: Read and Write permission. Stored securely in the iOS Keychain."
                )
            ) {
                HStack {
                    if vm.isTokenVisible {
                        TextField("github_pat_...", text: $vm.tokenInput)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else {
                        SecureField("github_pat_...", text: $vm.tokenInput)
                            .textContentType(.password)
                    }
                    Button(action: { vm.isTokenVisible.toggle() }) {
                        Image(systemName: vm.isTokenVisible ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                }

                Button(action: { vm.saveToken() }) {
                    HStack {
                        Image(systemName: "checkmark.circle")
                        Text("Save Token")
                    }
                }
                .disabled(vm.tokenInput.isEmpty)

                if vm.isTokenConfigured {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Token Configured")
                            .foregroundColor(.green)
                    }
                }
            }
            .listRowBackground(Color.chart)

            // MARK: Repo + branch
            Section(
                header: Text("Destination"),
                footer: Text("Telemetry commits land here. Repo must be private; the branch will be created as an orphan on first initialization.")
            ) {
                HStack {
                    Text("Repo")
                    Spacer()
                    TextField("owner/repo", text: $vm.repo)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: vm.repo) { _, new in vm.saveRepo(new) }
                }
                HStack {
                    Text("Branch")
                    Spacer()
                    TextField("telemetry", text: $vm.branch)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: vm.branch) { _, new in vm.saveBranch(new) }
                }
            }
            .listRowBackground(Color.chart)

            // MARK: One-time branch init
            Section(
                header: Text("Branch Setup"),
                footer: Text("Run this once on first setup. Creates the orphan telemetry branch on the repo above. Safe to re-run — does nothing if the branch already exists.")
            ) {
                Button(action: { vm.initializeBranch() }) {
                    HStack {
                        if vm.isInitializing {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.triangle.branch")
                        }
                        Text(vm.isInitializing ? "Initializing..." : "Initialize Telemetry Branch")
                    }
                }
                .disabled(vm.isInitializing || !vm.isTokenConfigured)
            }
            .listRowBackground(Color.chart)

            // MARK: Enable toggle
            Section(footer: Text("When enabled, meal-window events, loop decisions during active windows, daily settings snapshots, and per-meal outcome summaries are pushed to the destination branch on app foreground and after each meal-window close.")) {
                Toggle("Enable Telemetry", isOn: $vm.enabled)
                    .onChange(of: vm.enabled) { _, new in vm.saveEnabled(new) }
                    .disabled(!vm.isTokenConfigured)
            }
            .listRowBackground(Color.chart)

            // MARK: Status + manual push
            Section(header: Text("Status")) {
                HStack {
                    Text("Last Successful Push")
                    Spacer()
                    Text(vm.lastPushString).foregroundStyle(.secondary)
                }
                if let err = vm.lastError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last Error").foregroundStyle(.red)
                        Text(err).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button(action: { vm.pushNow() }) {
                    HStack {
                        if vm.isPushing {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.up.circle")
                        }
                        Text(vm.isPushing ? "Pushing..." : "Push Now")
                    }
                }
                .disabled(vm.isPushing || !vm.enabled)
            }
            .listRowBackground(Color.chart)

            // MARK: Reset
            Section(footer: Text("Wipes all on-device telemetry files and clears push status. Does NOT touch the remote branch.")) {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Clear Local Telemetry Data")
                    }
                }
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Telemetry")
        .onAppear { vm.reload() }
        .alert("Clear local telemetry data?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { vm.resetLocal() }
        } message: {
            Text("Removes all queued data from the device. Remote data is unaffected.")
        }
    }
}

@MainActor
private final class ViewModel: ObservableObject {
    // Inputs
    @Published var tokenInput: String = ""
    @Published var isTokenVisible: Bool = false
    @Published var repo: String = ""
    @Published var branch: String = ""
    @Published var enabled: Bool = false

    // Status / outputs
    @Published var isTokenConfigured: Bool = false
    @Published var isInitializing: Bool = false
    @Published var isPushing: Bool = false
    @Published var lastPushString: String = "—"
    @Published var lastError: String?

    private let resolver: Resolver = TrioApp.resolver
    private lazy var settingsManager: SettingsManager? = resolver.resolve(SettingsManager.self)
    private lazy var keychain: Keychain? = resolver.resolve(Keychain.self)
    private lazy var telemetry: AlgorithmTelemetryManager? = resolver.resolve(AlgorithmTelemetryManager.self)

    func reload() {
        guard let settings = settingsManager?.settings else { return }
        repo = settings.telemetryRepo
        branch = settings.telemetryBranch
        enabled = settings.telemetryEnabled
        lastError = settings.telemetryLastError
        if let date = settings.telemetryLastSuccessfulPushDate {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .short
            lastPushString = f.string(from: date)
        } else {
            lastPushString = "—"
        }
        isTokenConfigured = hasStoredToken()
    }

    func saveToken() {
        guard !tokenInput.isEmpty else { return }
        // KeyValueStorage's `setValue<T: Codable>(_:forKey:)` returns Void, overriding
        // the Keychain protocol's `Result`-returning version via overload resolution.
        keychain?.setValue(tokenInput, forKey: AlgorithmTelemetryKeychainKey.githubPAT)
        tokenInput = ""
        isTokenConfigured = hasStoredToken()
    }

    func saveRepo(_ value: String) {
        guard var s = settingsManager?.settings else { return }
        s.telemetryRepo = value
        settingsManager?.settings = s
    }

    func saveBranch(_ value: String) {
        guard var s = settingsManager?.settings else { return }
        s.telemetryBranch = value
        settingsManager?.settings = s
    }

    func saveEnabled(_ value: Bool) {
        guard var s = settingsManager?.settings else { return }
        s.telemetryEnabled = value
        settingsManager?.settings = s
    }

    func initializeBranch() {
        isInitializing = true
        Task {
            do {
                try await telemetry?.initializeBranch()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            isInitializing = false
            reload()
        }
    }

    func pushNow() {
        isPushing = true
        Task {
            await telemetry?.pushNow()
            isPushing = false
            reload()
        }
    }

    func resetLocal() {
        telemetry?.resetLocalData()
        reload()
    }

    private func hasStoredToken() -> Bool {
        guard let keychain else { return false }
        let token: String? = keychain.getValue(String.self, forKey: AlgorithmTelemetryKeychainKey.githubPAT)
        return token?.isEmpty == false
    }
}
