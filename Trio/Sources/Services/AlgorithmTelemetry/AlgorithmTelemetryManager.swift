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

    /// Detect a naturally-expired meal window and emit a `mealWindowExpired` event,
    /// then clear `mealWindowActivationDate` from settings so the window's gone for good.
    /// Safe to call any time. Returns the windowId if an expiry was just logged.
    @discardableResult
    func auditExpiredMealWindow() -> String?

    /// Write today's settings snapshot if not already present.
    func maintainDailySnapshot()

    /// Run 30-day rolling local retention.
    func runRetentionCleanup()

    /// Append a per-window close summary. Called from every close path so each window
    /// has a discoverable row in summary.jsonl, independent of the event stream.
    func recordWindowClose(
        windowId: String?,
        activatedAt: Date,
        closedAt: Date,
        closeReason: String,
        estimatedCarbs: Double?,
        carbsConfirmed: Bool,
        bgAtActivation: Double?,
        iobAtActivation: Double?,
        cobAtActivation: Double?
    )
}

/// Keychain key for the GitHub Personal Access Token. We store ONLY the PAT here;
/// repo + branch + enabled toggle live in TrioSettings since they're not secrets.
enum AlgorithmTelemetryKeychainKey {
    static let githubPAT = "trio.telemetry.github.pat"
}

final class BaseAlgorithmTelemetryManager: AlgorithmTelemetryManager, Injectable {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var keychain: Keychain!
    @Injected() private var fileStorage: FileStorage!

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
                self.auditExpiredMealWindow()
                self.maintainDailySnapshot()
                self.runRetentionCleanup()
                Task { await self.pushNow() }
            }
            .store(in: &subscriptions)

        // Snapshot + cleanup also run once at startup so launching after a long sleep
        // doesn't have to wait for the next foreground to refresh.
        maintainDailySnapshot()
        runRetentionCleanup()
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

    @discardableResult
    func auditExpiredMealWindow() -> String? {
        let s = settingsManager.settings
        guard let activatedAt = s.mealWindowActivationDate else { return nil }
        let durationMinutes: Decimal = s.mealWindowCarbsConfirmed
            ? s.mealWindowExtendedDurationMinutes
            : s.mealWindowDurationMinutes
        let cappedDuration = min(durationMinutes, 360)
        let expiresAt = activatedAt.addingTimeInterval(
            TimeInterval(truncating: cappedDuration as NSDecimalNumber) * 60
        )
        guard expiresAt <= Date() else { return nil }

        let windowId = s.mealWindowId
        logEvent(AlgorithmTelemetryEvent(
            kind: .mealWindowExpired,
            timestamp: expiresAt,
            windowId: windowId,
            payload: [
                "source": .string("naturalExpiry"),
                "elapsedMinutes": .double(Date().timeIntervalSince(activatedAt) / 60),
                "wasCarbsConfirmed": .bool(s.mealWindowCarbsConfirmed)
            ]
        ))
        recordWindowClose(
            windowId: windowId,
            activatedAt: activatedAt,
            closedAt: expiresAt,
            closeReason: "naturalExpiry",
            estimatedCarbs: s.mealWindowEstimatedCarbs > 0
                ? Double(truncating: s.mealWindowEstimatedCarbs as NSDecimalNumber)
                : nil,
            carbsConfirmed: s.mealWindowCarbsConfirmed,
            bgAtActivation: nil,
            iobAtActivation: nil,
            cobAtActivation: nil
        )

        DispatchQueue.main.async {
            var ns = self.settingsManager.settings
            ns.mealWindowActivationDate = nil
            ns.mealWindowEstimatedCarbs = 0
            ns.mealWindowCarbsConfirmed = false
            ns.mealWindowId = nil
            self.settingsManager.settings = ns
        }
        return windowId
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

    // MARK: - Phase 3: daily snapshot + cleanup

    /// Write today's settings.json snapshot if one isn't already on disk. Cheap to call
    /// repeatedly because TelemetryLogger.writeSettingsSnapshot does an atomic overwrite.
    /// Pulls hourly basal / ISF / CR / target schedules out of FileStorage so analysis
    /// knows which profile entry was active at any given hour.
    func maintainDailySnapshot() {
        guard settingsManager.settings.telemetryEnabled else { return }
        let s = settingsManager.settings
        let p = settingsManager.preferences

        // Hourly schedules from FileStorage. Best-effort — missing schedules are nil,
        // not an error (e.g., fresh install).
        let basal: [ScheduledRate]? = {
            guard let entries = fileStorage.retrieve(
                OpenAPS.Settings.basalProfile,
                as: [BasalProfileEntry].self
            ) else { return nil }
            return entries.map {
                ScheduledRate(startMinutes: $0.minutes, value: Double(truncating: $0.rate as NSNumber))
            }
        }()
        let isf: [ScheduledRate]? = {
            guard let payload = fileStorage.retrieve(
                OpenAPS.Settings.insulinSensitivities,
                as: InsulinSensitivities.self
            ) else { return nil }
            return payload.sensitivities.map {
                ScheduledRate(startMinutes: $0.offset, value: Double(truncating: $0.sensitivity as NSNumber))
            }
        }()
        let cr: [ScheduledRate]? = {
            guard let payload = fileStorage.retrieve(
                OpenAPS.Settings.carbRatios,
                as: CarbRatios.self
            ) else { return nil }
            return payload.schedule.map {
                ScheduledRate(startMinutes: $0.offset, value: Double(truncating: $0.ratio as NSNumber))
            }
        }()
        let targets: [ScheduledTargetRange]? = {
            guard let payload = fileStorage.retrieve(
                OpenAPS.Settings.bgTargets,
                as: BGTargets.self
            ) else { return nil }
            return payload.targets.map {
                ScheduledTargetRange(
                    startMinutes: $0.offset,
                    low: Double(truncating: $0.low as NSNumber),
                    high: Double(truncating: $0.high as NSNumber)
                )
            }
        }()

        let snapshot = AlgorithmTelemetrySettingsSnapshot(
            timestamp: Date(),
            mealWindowDurationMinutes: Double(truncating: s.mealWindowDurationMinutes as NSDecimalNumber),
            mealWindowExtendedDurationMinutes: Double(
                truncating: s.mealWindowExtendedDurationMinutes as NSDecimalNumber
            ),
            maxIOB: Double(truncating: p.maxIOB as NSDecimalNumber),
            smbDeliveryRatio: Double(truncating: p.smbDeliveryRatio as NSDecimalNumber),
            maxSMBBasalMinutes: Double(truncating: p.maxSMBBasalMinutes as NSDecimalNumber),
            maxUAMSMBBasalMinutes: Double(truncating: p.maxUAMSMBBasalMinutes as NSDecimalNumber),
            smbInterval: Double(truncating: p.smbInterval as NSDecimalNumber),
            enableUAM: p.enableUAM,
            enableSMBAlways: p.enableSMBAlways,
            enableSMBWithCOB: p.enableSMBWithCOB,
            enableSMBAfterCarbs: p.enableSMBAfterCarbs,
            enableSMBWithTemptarget: p.enableSMBWithTemptarget,
            enableSMBHighBG: p.enableSMB_high_bg,
            enableSMBHighBGTarget: Double(truncating: p.enableSMB_high_bg_target as NSDecimalNumber),
            toughMealEnabled: s.toughMeals,
            basalSchedule: basal,
            isfSchedule: isf,
            carbRatioSchedule: cr,
            bgTargetSchedule: targets,
            activeOverrideName: nil,
            activeOverrideTarget: nil,
            activeTempTargetTarget: nil
        )
        logger.writeSettingsSnapshot(snapshot)
    }

    /// 30-day rolling local cleanup. loop.jsonl in old directories is purged; summary
    /// data is kept indefinitely on the device. The remote branch isn't touched here —
    /// the GitHub-side retention pass is a separate, less-frequent operation.
    func runRetentionCleanup() {
        guard settingsManager.settings.telemetryEnabled else { return }
        logger.purgeLocal(olderThan: 30)
    }

    /// Record a per-window close-time summary. Outcomes that require post-prandial data
    /// (peak BG, time-above-180, etc.) are intentionally NOT computed here — those need
    /// a +6h delayed pass that's deferred to a follow-up commit. For now, summary.jsonl
    /// contains the metadata of every closed window (id, activation, close reason,
    /// hint vs real carbs, activation snapshot). Client-side analysis fills in outcomes
    /// from the matching loop.jsonl rows.
    func recordWindowClose(
        windowId: String?,
        activatedAt: Date,
        closedAt: Date,
        closeReason: String,
        estimatedCarbs: Double?,
        carbsConfirmed: Bool,
        bgAtActivation: Double?,
        iobAtActivation: Double?,
        cobAtActivation: Double?
    ) {
        guard settingsManager.settings.telemetryEnabled else { return }
        let p = settingsManager.preferences
        let summary = AlgorithmTelemetryWindowSummary(
            windowId: windowId ?? UUID().uuidString,
            activatedAt: activatedAt,
            closedAt: closedAt,
            closeReason: closeReason,
            estimatedCarbsHint: estimatedCarbs,
            realCarbsLogged: nil,
            realFatLogged: nil,
            realProteinLogged: nil,
            carbsConfirmed: carbsConfirmed,
            bgAtActivation: bgAtActivation,
            iobAtActivation: iobAtActivation,
            cobAtActivation: cobAtActivation,
            velocityAtActivation: nil,
            accelerationAtActivation: nil,
            mealDetectionAtActivation: nil,
            peakBG: nil,
            peakBGMinutesAfterActivation: nil,
            nadirBG: nil,
            nadirBGMinutesAfterActivation: nil,
            bgAt2hr: nil,
            bgAt4hr: nil,
            bgAt6hr: nil,
            minutesAbove180: nil,
            minutesAbove250: nil,
            minutesBelow70: nil,
            totalSMBInsulin: nil,
            totalScheduledBasalInsulin: nil,
            totalManualBolusInsulin: nil,
            floorActivationCount: 0,
            target: nil,
            isf: nil,
            carbRatio: nil,
            maxIOB: Double(truncating: p.maxIOB as NSDecimalNumber),
            smbDeliveryRatio: Double(truncating: p.smbDeliveryRatio as NSDecimalNumber),
            maxSMBBasalMinutes: Double(truncating: p.maxSMBBasalMinutes as NSDecimalNumber),
            maxUAMSMBBasalMinutes: Double(truncating: p.maxUAMSMBBasalMinutes as NSDecimalNumber)
        )
        logSummary(summary)
    }
}
