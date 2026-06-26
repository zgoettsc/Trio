import Combine
import Foundation
import Swinject
import UIKit

/// Public protocol for the rest of the app. Event-recording calls are fire-and-forget —
/// they never throw and never block the caller (loop, intent, etc.). The manager handles
/// queueing and pushing asynchronously.
protocol AlgorithmTelemetryManager: AnyObject {
    func logEvent(_ event: AlgorithmTelemetryEvent)
    func logLoopSample(_ sample: AlgorithmTelemetryLoopSample)
    func logSummary(_ summary: AlgorithmTelemetryWindowSummary)
    func logSettingsSnapshot(_ snapshot: AlgorithmTelemetrySettingsSnapshot)

    /// Trigger an immediate push attempt. Called manually from the UI button, on app
    /// foreground, and after a meal-window closes.
    func pushNow() async

    /// Initialize the orphan `telemetry` branch on the configured repo. Idempotent.
    /// Called from the settings UI "Initialize Branch" button.
    func initializeBranch() async throws

    /// Wipe local data and clear last-push state. Called from the settings "Reset" button.
    func resetLocalData()
}

/// Keychain key for the GitHub Personal Access Token. We store ONLY the PAT here;
/// repo + branch + enabled toggle live in TrioSettings since they're not secrets.
enum AlgorithmTelemetryKeychainKey {
    static let githubPAT = "trio.telemetry.github.pat"
}

final class BaseAlgorithmTelemetryManager: AlgorithmTelemetryManager, Injectable {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var keychain: Keychain!

    private let logger = AlgorithmTelemetryLogger()
    private let client = AlgorithmTelemetryGitHubClient()

    /// Pushes are debounced: if multiple triggers fire within a short window, only one push runs.
    private let pushDebounceInterval: TimeInterval = 30
    private var lastPushTriggerDate: Date = .distantPast
    private var pushTask: Task<Void, Never>?
    private let pushQueue = DispatchQueue(label: "AlgorithmTelemetryManager.push.serial")

    /// Observe app foreground to push pending data when the user opens the app.
    private var subscriptions = Set<AnyCancellable>()

    init(resolver: Resolver) {
        injectServices(resolver)

        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.pushNow() }
            }
            .store(in: &subscriptions)
    }

    // MARK: - Public API

    func logEvent(_ event: AlgorithmTelemetryEvent) {
        guard settingsManager.settings.telemetryEnabled else { return }
        logger.appendEvent(event)
    }

    func logLoopSample(_ sample: AlgorithmTelemetryLoopSample) {
        guard settingsManager.settings.telemetryEnabled else { return }
        logger.appendLoopSample(sample)
    }

    func logSummary(_ summary: AlgorithmTelemetryWindowSummary) {
        guard settingsManager.settings.telemetryEnabled else { return }
        logger.appendSummary(summary)
        Task { await self.pushNow() } // summaries are end-of-meal signals; push promptly
    }

    func logSettingsSnapshot(_ snapshot: AlgorithmTelemetrySettingsSnapshot) {
        guard settingsManager.settings.telemetryEnabled else { return }
        logger.writeSettingsSnapshot(snapshot)
    }

    func pushNow() async {
        // Debounce: if a push triggered within the last `pushDebounceInterval` seconds,
        // skip this one. The last-running task will sweep up whatever's queued.
        let now = Date()
        let shouldRun: Bool = pushQueue.sync {
            if now.timeIntervalSince(self.lastPushTriggerDate) < self.pushDebounceInterval {
                return false
            }
            self.lastPushTriggerDate = now
            return true
        }
        guard shouldRun else { return }

        guard settingsManager.settings.telemetryEnabled else { return }
        guard let token = currentToken(), !token.isEmpty else {
            recordError("No GitHub PAT configured")
            return
        }

        let repo = settingsManager.settings.telemetryRepo
        let branch = settingsManager.settings.telemetryBranch
        guard !repo.isEmpty, !branch.isEmpty else {
            recordError("Telemetry repo or branch is empty")
            return
        }

        let files = logger.enumerateFiles()
        guard !files.isEmpty else { return }

        do {
            try await client.initializeBranchIfMissing(repo: repo, branch: branch, token: token)

            // Load file bytes from disk and push in one atomic commit
            var payload: [(path: String, contents: Data)] = []
            for file in files {
                if let data = try? Data(contentsOf: file.localURL) {
                    payload.append((path: file.repoPath, contents: data))
                }
            }
            guard !payload.isEmpty else { return }

            let message = "telemetry: \(formatPushDate()) (\(payload.count) files)"
            try await client.pushFiles(
                repo: repo,
                branch: branch,
                files: payload,
                message: message,
                token: token
            )
            recordSuccess()
        } catch {
            recordError("\(error.localizedDescription)")
        }
    }

    func initializeBranch() async throws {
        guard let token = currentToken(), !token.isEmpty else {
            throw AlgorithmTelemetryGitHubError.missingToken
        }
        let repo = settingsManager.settings.telemetryRepo
        let branch = settingsManager.settings.telemetryBranch
        try await client.initializeBranchIfMissing(repo: repo, branch: branch, token: token)
    }

    func resetLocalData() {
        logger.purgeAll()
        var s = settingsManager.settings
        s.telemetryLastSuccessfulPushDate = nil
        s.telemetryLastError = nil
        settingsManager.settings = s
    }

    // MARK: - Token + status persistence

    private func currentToken() -> String? {
        switch keychain.getValue(String.self, forKey: AlgorithmTelemetryKeychainKey.githubPAT) {
        case .success(let token): return token
        case .failure: return nil
        }
    }

    private func recordSuccess() {
        DispatchQueue.main.async {
            var s = self.settingsManager.settings
            s.telemetryLastSuccessfulPushDate = Date()
            s.telemetryLastError = nil
            self.settingsManager.settings = s
        }
    }

    private func recordError(_ message: String) {
        DispatchQueue.main.async {
            var s = self.settingsManager.settings
            s.telemetryLastError = message
            self.settingsManager.settings = s
        }
        debug(.service, "[Telemetry] push failed: \(message)")
    }

    private func formatPushDate() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withFullTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        return f.string(from: Date())
    }
}
