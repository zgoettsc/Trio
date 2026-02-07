import SwiftUI

/// Displays the Garmin Firestore connection status and allows testing the connection.
/// Follows the Nightscout/Tidepool status indicator pattern (green check / red X).
struct GarminFirestoreStatusView: View {
    @State private var configStatus: CheckStatus = .unknown
    @State private var authStatus: CheckStatus = .unknown
    @State private var dataStatus: CheckStatus = .unknown
    @State private var isTesting = false
    @State private var latestSnapshot: GarminContextSnapshot?
    @State private var errorMessage: String?

    enum CheckStatus {
        case unknown, checking, pass, fail

        var icon: String {
            switch self {
            case .unknown: return "circle.dashed"
            case .checking: return "arrow.trianglehead.2.clockwise"
            case .pass: return "checkmark.circle.fill"
            case .fail: return "xmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .unknown: return .secondary
            case .checking: return .orange
            case .pass: return .green
            case .fail: return .red
            }
        }
    }

    var body: some View {
        Form {
            Section(header: Text("Connection Status")) {
                statusRow(label: "Configuration", status: configStatus, detail: configDetail)
                statusRow(label: "Firebase Sign-In", status: authStatus, detail: authDetail)
                statusRow(label: "Firestore Data", status: dataStatus, detail: dataDetail)
            }

            Section {
                Button {
                    Task { await runConnectionTest() }
                } label: {
                    HStack {
                        Spacer()
                        if isTesting {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Testing...")
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text("Test Connection")
                        }
                        Spacer()
                    }
                }
                .disabled(isTesting)
            }

            if let error = errorMessage {
                Section(header: Text("Error Details")) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = latestSnapshot {
                Section(header: Text("Latest Garmin Data")) {
                    dataRow("Sleep Score", value: snapshot.sleepScoreValue.map { "\($0)/100" })
                    dataRow("Sleep Duration", value: snapshot.totalSleepMinutes.map { "\($0 / 60)h \($0 % 60)m" })
                    dataRow("Resting HR", value: snapshot.restingHeartRateInBeatsPerMinute.map { "\($0) bpm" })
                    dataRow("HRV (last night)", value: snapshot.lastNightAvg.map { "\($0) ms" })
                    dataRow("Body Battery", value: snapshot.currentBodyBattery.map { "\($0)/100" })
                    dataRow("Stress Level", value: snapshot.currentStressLevel.map { "\($0)/100" })
                    dataRow("Active Calories", value: snapshot.activeKilocalories.map { "\($0) kcal" })
                    dataRow("Steps", value: snapshot.steps.map { "\($0)" })
                }
            }

            Section(header: Text("Configuration")) {
                configInfoRow("Project ID", value: maskedValue(GarminFirebaseConstants.projectID))
                configInfoRow("User ID", value: maskedValue(GarminFirebaseConstants.firestoreUserID))
                configInfoRow("Auth Email", value: maskedValue(GarminFirebaseConstants.authEmail))
            }
        }
        .navigationTitle("Garmin Health Data")
        .navigationBarTitleDisplayMode(.automatic)
        .onAppear {
            checkInitialStatus()
        }
    }

    // MARK: - Status Row

    private func statusRow(label: String, status: CheckStatus, detail: String?) -> some View {
        HStack {
            Image(systemName: status.icon)
                .foregroundStyle(status.color)
                .frame(width: 24)
            Text(label)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dataRow(_ label: String, value: String?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value ?? "—")
                .foregroundStyle(value != nil ? .primary : .secondary)
        }
    }

    private func configInfoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Detail Strings

    private var configDetail: String? {
        switch configStatus {
        case .pass: return "Secrets injected"
        case .fail: return "Secrets not configured"
        default: return nil
        }
    }

    private var authDetail: String? {
        switch authStatus {
        case .pass: return "Authenticated"
        case .fail: return "Sign-in failed"
        default: return nil
        }
    }

    private var dataDetail: String? {
        switch dataStatus {
        case .pass: return "Data received"
        case .fail: return "No data found"
        default: return nil
        }
    }

    // MARK: - Logic

    private func checkInitialStatus() {
        configStatus = GarminFirebaseConstants.isConfigured ? .pass : .fail
        authStatus = GarminFirebaseManager.isSignedIn ? .pass : .unknown
    }

    private func runConnectionTest() async {
        isTesting = true
        errorMessage = nil
        latestSnapshot = nil

        // Step 1: Check config
        configStatus = .checking
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard GarminFirebaseConstants.isConfigured else {
            configStatus = .fail
            authStatus = .fail
            dataStatus = .fail
            errorMessage = "Firebase secrets were not injected at build time. Add GARMIN_FIREBASE_* secrets to your GitHub repository and rebuild."
            isTesting = false
            return
        }
        configStatus = .pass

        // Step 2: Check auth (attempt sign-in if needed)
        authStatus = .checking
        await GarminFirebaseManager.configureAndSignIn()

        guard GarminFirebaseManager.isSignedIn else {
            authStatus = .fail
            dataStatus = .fail
            errorMessage = "Firebase sign-in failed. Check that GARMIN_FIREBASE_EMAIL and GARMIN_FIREBASE_PASSWORD are correct and that the account exists in your Firebase project."
            isTesting = false
            return
        }
        authStatus = .pass

        // Step 3: Try fetching data
        dataStatus = .checking
        let service = GarminFirestoreService()
        let snapshot = await service.fetchContext()

        if let snapshot {
            dataStatus = .pass
            latestSnapshot = snapshot
        } else {
            dataStatus = .fail
            errorMessage = "Signed in successfully but no Garmin data found in Firestore. Check that your Garmin Health API webhooks are populating data at path: users/\(GarminFirebaseConstants.firestoreUserID)/garminData/"
        }

        isTesting = false
    }

    // MARK: - Helpers

    private func maskedValue(_ value: String) -> String {
        if value.hasPrefix("__") { return "Not configured" }
        if value.count <= 8 { return value }
        return String(value.prefix(4)) + "..." + String(value.suffix(4))
    }
}
