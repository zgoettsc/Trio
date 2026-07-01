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

    /// Close the active meal window via the behavior-based exit detector.
    /// Mirrors auditExpiredMealWindow's close machinery (telemetry event,
    /// recordWindowClose, wipe settings) but with closeReason
    /// "behaviorBasedExit" and a custom payload identifying which rule
    /// fired (peakDropConfirmed / loopIdleAtBaseline / maxDurationCap).
    @discardableResult
    func closeMealWindowByExitRule(reason: String, payload: [String: AlgorithmTelemetryJSONValue]) -> String?

    /// Write today's settings snapshot if not already present.
    func maintainDailySnapshot()

    /// Run 30-day rolling local retention.
    func runRetentionCleanup()

    /// Rewrite the saved-meal definitions snapshot to telemetry/meals/definitions.json
    /// and push. Called by SavedMealStorage after every CRUD action.
    func emitMealDefinitionsSnapshot()

    /// Emit a meals.jsonl + per-meal-history row for an already-closed
    /// SavedMealInstance (no recordWindowClose round trip). Used by the
    /// retroactive backfill flow which creates closed instances without going
    /// through the live meal-window close path.
    func emitBackfilledInstance(instanceId: UUID)

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

    /// Process any closed windows whose +6h post-prandial tail has elapsed. Writes
    /// outcome-enriched summary rows. Called automatically on app foreground.
    func processReadyOutcomes()

    /// Snapshot of the active override + temp target at the current moment. Read by
    /// the loop logger (per-pass) and the daily settings writer (once/day).
    func currentAdjustments() -> AlgorithmTelemetryAdjustmentSnapshot
}

/// CoreData-derived snapshot of the active override + temp target.
struct AlgorithmTelemetryAdjustmentSnapshot {
    let overrideId: String?
    let overrideActive: Bool
    let overrideName: String?
    let overridePercentage: Double?
    let overrideTargetMgdL: Double?
    let overrideDuration: Double?
    let overrideMinutesRemaining: Double?
    let tempTargetId: String?
    let tempTargetActive: Bool
    let tempTargetName: String?
    let tempTargetTargetMgdL: Double?
    let tempTargetDuration: Double?
    let tempTargetMinutesRemaining: Double?
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
    @Injected() private var savedMealStorage: SavedMealStorage!

    private let logger = AlgorithmTelemetryLogger()
    private let client = AlgorithmTelemetryGitHubClient()
    private let outcomes = AlgorithmTelemetryOutcomes()

    /// Count of floor activations seen during the currently-open window. Reset on
    /// activation, snapshotted into the pending outcome on close.
    private var floorActivationsThisWindow: Int = 0
    private var lastWindowIdForFloorTracking: String?

    /// Pushes are debounced. Two windows so background-only triggers (loop ticks)
    /// don't drain battery while user-meaningful events still upload promptly.
    /// - eager (30s): events, settings changes, summaries — user-initiated activity.
    /// - lazy (15 min): per-loop samples in the background.
    /// A push is allowed when `now - lastPushDate >= minIntervalForThisTrigger`.
    private let pushDebounceEager: TimeInterval = 30
    private let pushDebounceLazy: TimeInterval = 900
    private var lastPushTriggerDate: Date = .distantPast
    private var pushTask: Task<Void, Never>?
    private let pushQueue = DispatchQueue(label: "AlgorithmTelemetryManager.push.serial")

    /// Observe app foreground to push pending data when the user opens the app.
    private var subscriptions = Set<AnyCancellable>()

    init(resolver: Resolver) {
        injectServices(resolver)

        // Foundation-qualified — Trio also defines a `protocol NotificationCenter` for
        // Swinject DI, so an unqualified `NotificationCenter.default` resolves to the
        // protocol type which doesn't have `.default`.
        Foundation.NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.auditExpiredMealWindow()
                self.maintainDailySnapshot()
                self.runRetentionCleanup()
                self.processReadyOutcomes()
                Task { await self.pushNow() }
            }
            .store(in: &subscriptions)

        // Snapshot + cleanup also run once at startup so launching after a long sleep
        // doesn't have to wait for the next foreground to refresh.
        maintainDailySnapshot()
        runRetentionCleanup()
        processReadyOutcomes()
        sweepUnemittedInstancesIfNeeded()
    }

    /// Current sweep generation. Bump when there's a known emit-format change
    /// or back-emit needed for previously-saved instances that didn't ship.
    /// Devices with `lastInstanceTelemetrySweepGeneration` < this value will
    /// re-emit every closed SavedMealInstance on next launch.
    /// Generation 1 covers the Phase E backfills made before
    /// emitBackfilledInstance was wired into SavedMealBackfillService.
    private static let currentTelemetrySweepGeneration = 1

    /// On launch, if the device hasn't run the current sweep generation,
    /// emit telemetry for every closed SavedMealInstance. Append-only so a
    /// few duplicate rows on the remote are harmless.
    private func sweepUnemittedInstancesIfNeeded() {
        guard settingsManager.settings.telemetryEnabled else { return }
        let lastSweep = settingsManager.settings.lastInstanceTelemetrySweepGeneration
        guard lastSweep < Self.currentTelemetrySweepGeneration else { return }
        let ctx = CoreDataStack.shared.persistentContainer.viewContext
        var ids: [UUID] = []
        ctx.performAndWait {
            let req = SavedMealInstance.fetchRequest()
            req.predicate = NSPredicate(format: "closedAt != nil")
            let all = (try? ctx.fetch(req)) ?? []
            ids = all.compactMap { $0.id }
        }
        guard !ids.isEmpty else {
            // Still bump the generation so we don't scan on every launch
            // until the user has instances.
            var s = settingsManager.settings
            s.lastInstanceTelemetrySweepGeneration = Self.currentTelemetrySweepGeneration
            settingsManager.settings = s
            return
        }
        debug(.service, "[Telemetry] Sweeping \(ids.count) SavedMealInstance(s) for back-emit (gen \(Self.currentTelemetrySweepGeneration))")
        for id in ids {
            emitBackfilledInstance(instanceId: id)
        }
        emitMealDefinitionsSnapshot()
        var s = settingsManager.settings
        s.lastInstanceTelemetrySweepGeneration = Self.currentTelemetrySweepGeneration
        settingsManager.settings = s
    }

    // MARK: - Public API

    func logEvent(_ event: AlgorithmTelemetryEvent) {
        guard settingsManager.settings.telemetryEnabled else { return }
        logger.appendEvent(event)

        // Track floor activations per window for the outcome summary.
        switch event.kind {
        case .mealWindowActivated:
            floorActivationsThisWindow = 0
            lastWindowIdForFloorTracking = event.windowId
        case .insulinReqFloorActivated:
            if event.windowId == lastWindowIdForFloorTracking {
                floorActivationsThisWindow += 1
            }
        default:
            break
        }
        // Every event-kind here is user-meaningful (quick-action activation,
        // bolus, carb entry, override change). Push immediately — pushNow()
        // debounces at 30s so back-to-back events coalesce.
        Task { await self.pushNow() }
    }

    func logLoopSample(_ sample: AlgorithmTelemetryLoopSample) {
        guard settingsManager.settings.telemetryEnabled else { return }
        logger.appendLoopSample(sample)
        // Lazy push — coalesces ~3 consecutive loop samples (15 min) into one
        // upload to save battery / background-network budget. Events still push
        // eagerly so floor activations / quick-actions don't get delayed.
        Task { await self.pushNow(priority: .lazy) }
    }

    func logSummary(_ summary: AlgorithmTelemetryWindowSummary) {
        guard settingsManager.settings.telemetryEnabled else { return }
        logger.appendSummary(summary)
        Task { await self.pushNow() } // summaries are end-of-meal signals; push promptly
    }

    func logSettingsSnapshot(_ snapshot: AlgorithmTelemetrySettingsSnapshot) {
        guard settingsManager.settings.telemetryEnabled else { return }
        logger.writeSettingsSnapshot(snapshot)
        Task { await self.pushNow() }
    }

    /// Trigger a push. `priority: .eager` (default) bypasses the lazy debounce —
    /// use for user-meaningful events (quick-action, settings change, summary).
    /// `priority: .lazy` for high-frequency background triggers (per-loop samples).
    enum PushPriority { case eager, lazy }

    /// Protocol-satisfying zero-arg entrypoint. UI "Push Now" button and app
    /// foreground both use this — both should bypass the lazy debounce, so
    /// .eager is the right default.
    func pushNow() async {
        await pushNow(priority: .eager)
    }

    func pushNow(priority: PushPriority) async {
        // Debounce: skip if the last push trigger was within the appropriate window.
        // The last-running task sweeps up whatever's queued.
        let now = Date()
        let minInterval: TimeInterval = (priority == .lazy) ? pushDebounceLazy : pushDebounceEager
        let shouldRun: Bool = pushQueue.sync {
            if now.timeIntervalSince(self.lastPushTriggerDate) < minInterval {
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

            // Daily remote cleanup runs at most once every 24h after a successful push.
            await maybeRunRemoteCleanup(repo: repo, branch: branch, token: token)
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

    func currentAdjustments() -> AlgorithmTelemetryAdjustmentSnapshot {
        let ctx = CoreDataStack.shared.newTaskContext()
        var ov: OverrideStored?
        var tt: TempTargetStored?
        ctx.performAndWait {
            let oReq = OverrideStored.fetchRequest()
            oReq.predicate = NSPredicate(format: "enabled == YES")
            oReq.fetchLimit = 1
            ov = try? ctx.fetch(oReq).first
            let tReq = TempTargetStored.fetchRequest()
            tReq.predicate = NSPredicate(format: "enabled == YES")
            tReq.fetchLimit = 1
            tt = try? ctx.fetch(tReq).first
        }
        let now = Date()
        let ovMinutesRemaining: Double? = ov.flatMap { o -> Double? in
            guard let date = o.date, let durDec = o.duration else { return nil }
            let dur = Double(truncating: durDec)
            return max(0, dur - now.timeIntervalSince(date) / 60)
        }
        let ttMinutesRemaining: Double? = tt.flatMap { t -> Double? in
            guard let date = t.date, let durDec = t.duration else { return nil }
            let dur = Double(truncating: durDec)
            return max(0, dur - now.timeIntervalSince(date) / 60)
        }
        let snapshot = AlgorithmTelemetryAdjustmentSnapshot(
            overrideId: ov?.id,
            overrideActive: ov != nil,
            overrideName: ov?.name,
            overridePercentage: ov.map { $0.percentage },
            overrideTargetMgdL: ov?.target.map { Double(truncating: $0) },
            overrideDuration: ov?.duration.map { Double(truncating: $0) },
            overrideMinutesRemaining: ovMinutesRemaining,
            tempTargetId: tt?.id?.uuidString,
            tempTargetActive: tt != nil,
            tempTargetName: tt?.name,
            tempTargetTargetMgdL: tt?.target.map { Double(truncating: $0) },
            tempTargetDuration: tt?.duration.map { Double(truncating: $0) },
            tempTargetMinutesRemaining: ttMinutesRemaining
        )

        // Emit transition events if the active adjustment changed since the last call.
        // Catches start (no prior → active), cancel (prior → no active), and swap
        // (one preset replaced with another) regardless of where the change originated.
        detectAndEmitAdjustmentTransitions(newSnapshot: snapshot)

        return snapshot
    }

    private var lastSeenOverrideId: String? = nil
    private var lastSeenTempTargetId: String? = nil
    private let adjustmentAuditQueue = DispatchQueue(label: "AlgorithmTelemetry.adjustmentAudit")

    private func detectAndEmitAdjustmentTransitions(newSnapshot s: AlgorithmTelemetryAdjustmentSnapshot) {
        adjustmentAuditQueue.sync {
            // Override transition
            if s.overrideId != self.lastSeenOverrideId {
                if self.lastSeenOverrideId != nil {
                    logEvent(AlgorithmTelemetryEvent(
                        kind: .overrideCancelled,
                        timestamp: Date(),
                        windowId: settingsManager.settings.mealWindowId,
                        payload: ["overrideId": .string(self.lastSeenOverrideId!)]
                    ))
                }
                if let newId = s.overrideId {
                    var payload: [String: AlgorithmTelemetryJSONValue] = [:]
                    payload["overrideId"] = .string(newId)
                    payload["name"] = s.overrideName.map { .string($0) } ?? .null
                    payload["percentage"] = .from(s.overridePercentage)
                    payload["targetMgdL"] = .from(s.overrideTargetMgdL)
                    payload["durationMinutes"] = .from(s.overrideDuration)
                    logEvent(AlgorithmTelemetryEvent(
                        kind: .overrideStarted,
                        timestamp: Date(),
                        windowId: settingsManager.settings.mealWindowId,
                        payload: payload
                    ))
                }
                self.lastSeenOverrideId = s.overrideId
            }
            // Temp target transition
            if s.tempTargetId != self.lastSeenTempTargetId {
                if self.lastSeenTempTargetId != nil {
                    logEvent(AlgorithmTelemetryEvent(
                        kind: .tempTargetCancelled,
                        timestamp: Date(),
                        windowId: settingsManager.settings.mealWindowId,
                        payload: ["tempTargetId": .string(self.lastSeenTempTargetId!)]
                    ))
                }
                if let newId = s.tempTargetId {
                    var payload: [String: AlgorithmTelemetryJSONValue] = [:]
                    payload["tempTargetId"] = .string(newId)
                    payload["name"] = s.tempTargetName.map { .string($0) } ?? .null
                    payload["targetMgdL"] = .from(s.tempTargetTargetMgdL)
                    payload["durationMinutes"] = .from(s.tempTargetDuration)
                    logEvent(AlgorithmTelemetryEvent(
                        kind: .tempTargetStarted,
                        timestamp: Date(),
                        windowId: settingsManager.settings.mealWindowId,
                        payload: payload
                    ))
                }
                self.lastSeenTempTargetId = s.tempTargetId
            }
        }
    }

    @discardableResult
    func auditExpiredMealWindow() -> String? {
        let s = settingsManager.settings
        guard let activatedAt = s.mealWindowActivationDate else { return nil }
        let durationMinutes: Decimal = s.mealWindowCarbsConfirmed
            ? s.mealWindowExtendedDurationMinutes
            : s.mealWindowDurationMinutes
        // When behavior-based exit is enabled the per-loop detector is
        // the primary close path; this timer becomes a hard safety cap
        // that only fires if the loop never noticed the meal was done.
        // Cap the cap by mealWindowBehaviorExitMaxMinutes so windows
        // CAN run long when the user wants them to (default 600 min).
        let hardCap: Decimal = s.mealWindowBehaviorBasedExitEnabled
            ? s.mealWindowBehaviorExitMaxMinutes
            : 360
        let cappedDuration = min(durationMinutes, hardCap)
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
            ns.pendingLiveCarbsSuggestion = nil
            // Wipe live-classifier state on natural expiry too.
            ns.mealCurrentClassification = .simple
            ns.mealClassifierActivationBG = nil
            ns.mealClassifierPhase1ConfirmedAt = nil
            ns.mealClassifierPhase1Trough = nil
            ns.mealClassifierPhase2ConfirmedAt = nil
            ns.mealClassifierUpgradedAt = nil
            ns.mealWindowSavedMealId = nil
            ns.mealWindowSavedMealInstanceId = nil
            // Reset the auto-phantom-COB accumulator so the next window
            // starts at 0. Stale state would skew the per-window cap on
            // a fresh activation.
            ns.mealWindowAutoPhantomCOBInjectedGrams = 0
            self.settingsManager.settings = ns
        }
        return windowId
    }

    @discardableResult
    func closeMealWindowByExitRule(reason: String, payload: [String: AlgorithmTelemetryJSONValue]) -> String? {
        let s = settingsManager.settings
        guard let activatedAt = s.mealWindowActivationDate else { return nil }
        let windowId = s.mealWindowId
        let now = Date()
        var fullPayload = payload
        fullPayload["reason"] = .string(reason)
        fullPayload["minutesSinceOpen"] = .double(now.timeIntervalSince(activatedAt) / 60)
        fullPayload["carbsConfirmed"] = .bool(s.mealWindowCarbsConfirmed)
        logEvent(AlgorithmTelemetryEvent(
            kind: .mealWindowClosedByExitRule,
            timestamp: now,
            windowId: windowId,
            payload: fullPayload
        ))
        recordWindowClose(
            windowId: windowId,
            activatedAt: activatedAt,
            closedAt: now,
            closeReason: "behaviorBasedExit:\(reason)",
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
            ns.pendingLiveCarbsSuggestion = nil
            ns.mealCurrentClassification = .simple
            ns.mealClassifierActivationBG = nil
            ns.mealClassifierPhase1ConfirmedAt = nil
            ns.mealClassifierPhase1Trough = nil
            ns.mealClassifierPhase2ConfirmedAt = nil
            ns.mealClassifierUpgradedAt = nil
            ns.mealWindowSavedMealId = nil
            ns.mealWindowSavedMealInstanceId = nil
            // Clear pending live-carbs suggestion banner — meal is over,
            // the suggestion is no longer actionable.
            ns.pendingLiveCarbsSuggestion = nil
            // Reset auto-phantom-COB accumulator (see auditExpiredMealWindow).
            ns.mealWindowAutoPhantomCOBInjectedGrams = 0
            self.settingsManager.settings = ns
        }
        return windowId
    }

    // MARK: - Saved Meal telemetry (Phase D)

    /// Looks up the saved meal in the persistence layer to fetch macros + name,
    /// builds a SavedMealTelemetryRow, and writes it to BOTH the daily
    /// meals.jsonl AND the per-meal history file.
    func emitSavedMealInstanceTelemetry(
        instanceId: UUID,
        windowId: String,
        activatedAt: Date,
        closedAt: Date,
        finalClassification: MealClassification,
        metrics: SavedMealInstanceMetrics,
        score: Int,
        bgCurveJSON: String?,
        smbsJSON: String?,
        classifierUpgradesJSON: String?
    ) {
        guard settingsManager.settings.telemetryEnabled else { return }
        // Look up the linked meal via the instance.
        guard let inst = savedMealStorage?.instance(forWindowId: windowId),
              let meal = inst.savedMeal,
              let mealId = meal.id
        else { return }

        let anonymize = settingsManager.settings.telemetryAnonymizeMealNames
        let row = SavedMealTelemetryRow(
            kind: "savedMealInstance",
            instanceId: instanceId.uuidString,
            savedMealId: mealId.uuidString,
            savedMealName: anonymize ? nil : meal.name,
            savedMealNamePrivate: anonymize,
            windowId: windowId,
            startedAt: activatedAt,
            closedAt: closedAt,
            deviceTimeZone: TimeZone.current.identifier,
            macros: SavedMealTelemetryRow.Macros(
                carbs: inst.carbsAtActivation.map { $0.doubleValue },
                fat: inst.fatAtActivation.map { $0.doubleValue },
                protein: inst.proteinAtActivation.map { $0.doubleValue }
            ),
            carbBucket: inst.carbBucket?.rawValue,
            initialClassification: inst.initialClassification,
            finalClassification: finalClassification.rawValue,
            bgCurveJSON: bgCurveJSON,
            smbsJSON: smbsJSON,
            floorActivationsJSON: nil,
            classifierUpgradesJSON: classifierUpgradesJSON,
            outcomeScore: score,
            metrics: SavedMealTelemetryRow.Metrics(
                peakBG: metrics.peakBG,
                timeInRangeMinutes: metrics.timeInRangeMinutes,
                timeAboveRangeMinutes: metrics.timeAboveRangeMinutes,
                timeBelowRangeMinutes: metrics.timeBelowRangeMinutes,
                lowsCount: metrics.lowsCount,
                timeToBaselineMinutes: metrics.timeToBaselineMinutes,
                totalInsulinDeliveredU: metrics.totalInsulinDeliveredU,
                smbCount: metrics.smbCount,
                floorActivationCount: metrics.floorActivationCount
            ),
            context: SavedMealTelemetryRow.ActivationContext(
                bgAtActivation: inst.bgAtActivation?.doubleValue,
                bgTrendAtActivation: inst.bgTrendAtActivation?.doubleValue,
                autosensRatioAtActivation: inst.autosensRatioAtActivation?.doubleValue,
                smartSenseRatioAtActivation: inst.smartSenseRatioAtActivation?.doubleValue,
                effectiveISFAtActivation: inst.effectiveISFAtActivation?.doubleValue,
                carbRatioAtActivation: inst.carbRatioAtActivation?.doubleValue,
                pumpSiteAgeHours: inst.pumpSiteAgeHours?.doubleValue,
                garminContextAtActivationJSON: inst.garminContextAtActivationJSON
            ),
            tagNames: resolveTagNames(for: meal),
            buildSchema: 13
        )
        logger.appendMealInstance(row, on: closedAt)
        logger.appendPerMealHistory(row, mealId: mealId)
        Task { await self.pushNow() }  // eager push — meal-close is user-meaningful
    }

    /// Rewrites `telemetry/meals/definitions.json` with the current set of
    /// SavedMeal definitions. Called on every SavedMeal CRUD action by the
    /// storage layer (which forwards the snapshot to us).
    /// Emits a meals.jsonl + per-meal-history row for a SavedMealInstance
    /// that was created outside the live recordWindowClose path
    /// (specifically, the retroactive backfill flow).
    func emitBackfilledInstance(instanceId: UUID) {
        guard settingsManager.settings.telemetryEnabled else { return }
        guard let storage = savedMealStorage else { return }
        // Find by id via the storage's lookup. We need the full instance to
        // read macros / outcome metrics — storage exposes instance(forWindowId:)
        // but backfilled rows use a synthetic windowId. Fetch directly.
        let ctx = CoreDataStack.shared.persistentContainer.viewContext
        var inst: SavedMealInstance?
        ctx.performAndWait {
            let req = SavedMealInstance.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", instanceId as CVarArg)
            req.fetchLimit = 1
            inst = (try? ctx.fetch(req))?.first
        }
        guard let inst = inst, let meal = inst.savedMeal, let mealId = meal.id,
              let startedAt = inst.startedAt, let closedAt = inst.closedAt
        else { return }
        let anonymize = settingsManager.settings.telemetryAnonymizeMealNames
        let finalClassification = MealClassification(rawValue: inst.finalClassification ?? "")
            ?? .simple
        let row = SavedMealTelemetryRow(
            kind: "savedMealInstance",
            instanceId: instanceId.uuidString,
            savedMealId: mealId.uuidString,
            savedMealName: anonymize ? nil : meal.name,
            savedMealNamePrivate: anonymize,
            windowId: inst.windowId ?? "backfill-\(instanceId.uuidString)",
            startedAt: startedAt,
            closedAt: closedAt,
            deviceTimeZone: TimeZone.current.identifier,
            macros: SavedMealTelemetryRow.Macros(
                carbs: inst.carbsAtActivation.map { $0.doubleValue },
                fat: inst.fatAtActivation.map { $0.doubleValue },
                protein: inst.proteinAtActivation.map { $0.doubleValue }
            ),
            carbBucket: inst.carbBucket?.rawValue,
            initialClassification: inst.initialClassification,
            finalClassification: finalClassification.rawValue,
            bgCurveJSON: inst.bgCurveJSON,
            smbsJSON: inst.smbsJSON,
            floorActivationsJSON: inst.floorActivationsJSON,
            classifierUpgradesJSON: inst.classifierUpgradesJSON,
            outcomeScore: Int(inst.outcomeScore),
            metrics: SavedMealTelemetryRow.Metrics(
                peakBG: inst.peakBG,
                timeInRangeMinutes: Int(inst.timeInRangeMinutes),
                timeAboveRangeMinutes: Int(inst.timeAboveRangeMinutes),
                timeBelowRangeMinutes: Int(inst.timeBelowRangeMinutes),
                lowsCount: Int(inst.lowsCount),
                timeToBaselineMinutes: Int(inst.timeToBaselineMinutes),
                totalInsulinDeliveredU: inst.totalInsulinDeliveredU,
                smbCount: Int(inst.smbCount),
                floorActivationCount: Int(inst.floorActivationCount)
            ),
            context: SavedMealTelemetryRow.ActivationContext(
                bgAtActivation: inst.bgAtActivation?.doubleValue,
                bgTrendAtActivation: inst.bgTrendAtActivation?.doubleValue,
                autosensRatioAtActivation: inst.autosensRatioAtActivation?.doubleValue,
                smartSenseRatioAtActivation: inst.smartSenseRatioAtActivation?.doubleValue,
                effectiveISFAtActivation: inst.effectiveISFAtActivation?.doubleValue,
                carbRatioAtActivation: inst.carbRatioAtActivation?.doubleValue,
                pumpSiteAgeHours: inst.pumpSiteAgeHours?.doubleValue,
                garminContextAtActivationJSON: inst.garminContextAtActivationJSON
            ),
            tagNames: resolveTagNames(for: meal),
            buildSchema: 13
        )
        logger.appendMealInstance(row, on: closedAt)
        logger.appendPerMealHistory(row, mealId: mealId)
        // Refresh definitions.json — cachedInstanceCount changed.
        emitMealDefinitionsSnapshot()
    }

    /// Resolves the meal's `tagIDs` against the user's tag library to
    /// produce name strings for telemetry. Unknown IDs (tag deleted out
    /// from under us) are dropped. Returns nil when the meal carries no
    /// tags so the JSON row omits the field entirely.
    private func resolveTagNames(for meal: SavedMeal) -> [String]? {
        let ids = meal.tagIDs
        guard !ids.isEmpty else { return nil }
        let lib = settingsManager.settings.mealTags
        let names = ids.compactMap { id in lib.first(where: { $0.id == id })?.name }
        return names.isEmpty ? nil : names
    }

    func emitMealDefinitionsSnapshot() {
        guard settingsManager.settings.telemetryEnabled else { return }
        guard let storage = savedMealStorage else { return }
        let anonymize = settingsManager.settings.telemetryAnonymizeMealNames
        let meals = storage.allMeals()
        var dict: [String: SavedMealDefinitionsSnapshot.MealDef] = [:]
        for m in meals {
            guard let id = m.id else { continue }
            let defaults = SavedMealDefinitionsSnapshot.MealDef.Defaults(
                carbs: m.defaultCarbs.map { $0.doubleValue },
                fat: m.defaultFat.map { $0.doubleValue },
                protein: m.defaultProtein.map { $0.doubleValue },
                classification: m.defaultClassification,
                extendedDurationMinutes: m.defaultExtendedDurationMinutes > 0
                    ? Int(m.defaultExtendedDurationMinutes) : nil,
                phantomCOBEnabled: m.defaultPhantomCOBEnabled ? true : nil,
                phantomCOBGrams: m.defaultPhantomCOBGrams.map { $0.doubleValue }
            )
            let stats = SavedMealDefinitionsSnapshot.MealDef.Stats(
                instanceCount: Int(m.cachedInstanceCount),
                recommendedClassification: m.cachedRecommendedClassification
            )
            dict[id.uuidString] = SavedMealDefinitionsSnapshot.MealDef(
                id: id.uuidString,
                name: anonymize ? nil : m.name,
                icon: m.icon,
                createdAt: m.createdAt,
                updatedAt: m.updatedAt,
                defaults: defaults,
                stats: stats,
                tagNames: resolveTagNames(for: m)
            )
        }
        let snapshot = SavedMealDefinitionsSnapshot(
            lastUpdated: Date(),
            deviceTimeZone: TimeZone.current.identifier,
            meals: dict
        )
        logger.writeMealDefinitions(snapshot)
        Task { await self.pushNow() }
    }

    // MARK: - Token + status persistence

    private func currentToken() -> String? {
        // KeyValueStorage's `getValue<T: Codable>(_:forKey:) -> T?` is selected by
        // overload resolution over Keychain's `Result`-returning version, so this
        // returns `String?` directly.
        keychain.getValue(String.self, forKey: AlgorithmTelemetryKeychainKey.githubPAT)
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

    /// Identify `telemetry/YYYY-MM/DD/...` paths in the remote branch whose date is
    /// older than `daysToKeep`, and delete them in a single commit via the Git
    /// Database API. Idempotent; throttled to at most once per 24 hours.
    private func maybeRunRemoteCleanup(repo: String, branch: String, token: String) async {
        let daysToKeep = 30
        let now = Date()
        if let last = settingsManager.settings.telemetryLastRemoteCleanupDate {
            if now.timeIntervalSince(last) < 24 * 3600 { return }
        }

        do {
            let allPaths = try await client.listAllPaths(repo: repo, branch: branch, token: token)
            // Match telemetry/YYYY-MM/DD/anything paths.
            let regex = try NSRegularExpression(
                pattern: #"^telemetry/(\d{4})-(\d{2})/(\d{2})/"#,
                options: []
            )
            let cutoff = now.addingTimeInterval(-Double(daysToKeep) * 86_400)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current  // folder partitioning is local-time; cutoff math must match

            var pathsToDelete: [String] = []
            for path in allPaths {
                let range = NSRange(path.startIndex..., in: path)
                guard let match = regex.firstMatch(in: path, options: [], range: range),
                      match.numberOfRanges == 4,
                      let yearRange = Range(match.range(at: 1), in: path),
                      let monthRange = Range(match.range(at: 2), in: path),
                      let dayRange = Range(match.range(at: 3), in: path),
                      let year = Int(path[yearRange]),
                      let month = Int(path[monthRange]),
                      let day = Int(path[dayRange]) else { continue }
                var dc = DateComponents()
                dc.year = year; dc.month = month; dc.day = day
                dc.timeZone = .current
                guard let fileDate = calendar.date(from: dc), fileDate < cutoff else { continue }
                // Preserve summary.jsonl rows forever (small + tuning-relevant).
                if path.hasSuffix("/summary.jsonl") { continue }
                pathsToDelete.append(path)
            }

            guard !pathsToDelete.isEmpty else {
                stampCleanupDate(now)
                return
            }

            let message = "telemetry cleanup: drop \(pathsToDelete.count) files older than \(daysToKeep)d"
            try await client.deleteFiles(
                repo: repo,
                branch: branch,
                paths: pathsToDelete,
                message: message,
                token: token
            )
            stampCleanupDate(now)
        } catch {
            // Cleanup failures are non-fatal — we'll try again on the next push tomorrow.
            debug(.service, "[Telemetry] remote cleanup failed: \(error)")
        }
    }

    private func stampCleanupDate(_ date: Date) {
        DispatchQueue.main.async {
            var s = self.settingsManager.settings
            s.telemetryLastRemoteCleanupDate = date
            self.settingsManager.settings = s
        }
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
        let adj = currentAdjustments()

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
            activeOverrideName: adj.overrideName,
            activeOverridePercentage: adj.overridePercentage,
            activeOverrideTarget: adj.overrideTargetMgdL,
            activeOverrideDuration: adj.overrideDuration,
            activeTempTargetName: adj.tempTargetName,
            activeTempTargetTarget: adj.tempTargetTargetMgdL,
            activeTempTargetDuration: adj.tempTargetDuration,
            mealWindowBoostSMBRatio: s.mealWindowBoostSMBRatio,
            mealWindowSMBRatioValue: Double(truncating: s.mealWindowSMBRatioValue as NSDecimalNumber),
            mealWindowRelaxRisingGuard: s.mealWindowRelaxRisingGuard,
            mealWindowAdditiveFloor: s.mealWindowAdditiveFloor,
            mealWindowForceUAM: s.mealWindowForceUAM,
            mealWindowPhantomCOB: s.mealWindowPhantomCOB,
            mealWindowPhantomCOBGrams: Double(truncating: s.mealWindowPhantomCOBGrams as NSDecimalNumber),
            mealWindowSMBMinutesMultiplier: Double(truncating: s.mealWindowSMBMinutesMultiplier as NSDecimalNumber),
            mealWindowToughMealCapPercent: Double(truncating: s.mealWindowToughMealCapPercent as NSDecimalNumber),
            deviceTimeZone: TimeZone.current.identifier
        )
        logger.writeSettingsSnapshot(snapshot)
        detectAndEmitTuningTransitions()

        // v3 — write a daily Garmin snapshot row to garmin.jsonl.
        // Gated by telemetryIncludeGarmin (privacy switch). Fire-and-
        // forget — failures here must NOT block settings export.
        if s.telemetryIncludeGarmin {
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                let service = GarminFirestoreService()
                guard service.isConfigured else { return }
                guard let context = await service.fetchContext() else { return }
                let row = DailyGarminRow(
                    timestamp: Date(),
                    deviceTimeZone: TimeZone.current.identifier,
                    snapshot: context
                )
                self.logger.appendGarminSnapshot(row, on: row.timestamp)
            }
        }
    }

    /// One row in the daily garmin.jsonl file. Wraps the raw snapshot
    /// with the same timestamp + timezone fields every other telemetry
    /// row carries so the file is self-consistent in pandas etc.
    struct DailyGarminRow: Encodable {
        let timestamp: Date
        let deviceTimeZone: String?
        let snapshot: GarminContextSnapshot
    }

    // Track each tuning field's last-known value to emit transition events on change.
    private var lastTuningSnapshot: [String: String] = [:]
    private let tuningAuditQueue = DispatchQueue(label: "AlgorithmTelemetry.tuningAudit")

    private func detectAndEmitTuningTransitions() {
        let s = settingsManager.settings
        let current: [String: String] = [
            "mealWindowBoostSMBRatio": String(s.mealWindowBoostSMBRatio),
            "mealWindowSMBRatioValue": "\(s.mealWindowSMBRatioValue)",
            "mealWindowRelaxRisingGuard": String(s.mealWindowRelaxRisingGuard),
            "mealWindowAdditiveFloor": String(s.mealWindowAdditiveFloor),
            "mealWindowForceUAM": String(s.mealWindowForceUAM),
            "mealWindowPhantomCOB": String(s.mealWindowPhantomCOB),
            "mealWindowPhantomCOBGrams": "\(s.mealWindowPhantomCOBGrams)",
            "mealWindowSMBMinutesMultiplier": "\(s.mealWindowSMBMinutesMultiplier)",
            "mealWindowToughMealCapPercent": "\(s.mealWindowToughMealCapPercent)"
        ]
        tuningAuditQueue.sync {
            // First call seeds the cache; no events on initial run.
            if self.lastTuningSnapshot.isEmpty {
                self.lastTuningSnapshot = current
                return
            }
            for (field, value) in current where self.lastTuningSnapshot[field] != value {
                var payload: [String: AlgorithmTelemetryJSONValue] = [:]
                payload["field"] = .string(field)
                payload["oldValue"] = .string(self.lastTuningSnapshot[field] ?? "")
                payload["newValue"] = .string(value)
                logEvent(AlgorithmTelemetryEvent(
                    kind: .mealWindowTuningChanged,
                    timestamp: Date(),
                    windowId: settingsManager.settings.mealWindowId,
                    payload: payload
                ))
            }
            self.lastTuningSnapshot = current
        }
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
        let resolvedWindowId = windowId ?? UUID().uuidString
        let p = settingsManager.preferences
        let summary = AlgorithmTelemetryWindowSummary(
            windowId: resolvedWindowId,
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
            floorActivationCount: floorActivationsThisWindow,
            target: nil,
            isf: nil,
            carbRatio: nil,
            maxIOB: Double(truncating: p.maxIOB as NSDecimalNumber),
            smbDeliveryRatio: Double(truncating: p.smbDeliveryRatio as NSDecimalNumber),
            maxSMBBasalMinutes: Double(truncating: p.maxSMBBasalMinutes as NSDecimalNumber),
            maxUAMSMBBasalMinutes: Double(truncating: p.maxUAMSMBBasalMinutes as NSDecimalNumber)
        )
        logSummary(summary)

        // If this window was linked to a SavedMealInstance, close it with
        // computed outcome metrics + serialized BG curve / SMBs / classifier
        // upgrades. See MEAL_INTELLIGENCE_DESIGN.md §6, §8.
        if let instIdStr = settingsManager.settings.mealWindowSavedMealInstanceId,
           let instId = UUID(uuidString: instIdStr)
        {
            let finalClassification = settingsManager.settings.mealCurrentClassification
            // Phase 2 trough is the better baseline than activation BG (Round 9
            // finding) — fall back to activation BG if the trough isn't set.
            let baseline = settingsManager.settings.mealClassifierPhase1Trough
                ?? settingsManager.settings.mealClassifierActivationBG
                ?? bgAtActivation

            // Build the classifier-upgrade history from settings. Phase A
            // tracks only one upgrade per window (Simple → Medium → Complex
            // is collapsed); we record at most one upgrade event.
            var upgrades: [SavedMealOutcomeCalculator.ClassifierUpgradeSample] = []
            if let upgradedAt = settingsManager.settings.mealClassifierUpgradedAt {
                upgrades.append(SavedMealOutcomeCalculator.ClassifierUpgradeSample(
                    t: upgradedAt.timeIntervalSince(activatedAt) / 60,
                    from: MealClassification.medium.rawValue,
                    to: finalClassification.rawValue
                ))
            }

            let calc = SavedMealOutcomeCalculator(
                viewContext: CoreDataStack.shared.persistentContainer.viewContext
            )
            let result = calc.compute(
                activatedAt: activatedAt,
                closedAt: closedAt,
                baselineBG: baseline,
                classifierUpgrades: upgrades
            )
            // Floor count came from our running tally during the window.
            let finalMetrics = SavedMealInstanceMetrics(
                peakBG: result.metrics.peakBG,
                timeInRangeMinutes: result.metrics.timeInRangeMinutes,
                timeAboveRangeMinutes: result.metrics.timeAboveRangeMinutes,
                timeBelowRangeMinutes: result.metrics.timeBelowRangeMinutes,
                lowsCount: result.metrics.lowsCount,
                timeToBaselineMinutes: result.metrics.timeToBaselineMinutes,
                totalInsulinDeliveredU: result.metrics.totalInsulinDeliveredU,
                smbCount: result.metrics.smbCount,
                floorActivationCount: floorActivationsThisWindow
            )
            savedMealStorage?.closeInstance(
                instanceId: instId,
                closedAt: closedAt,
                finalClassification: finalClassification,
                bgCurveJSON: result.bgCurveJSON,
                smbsJSON: result.smbsJSON,
                floorActivationsJSON: result.floorActivationsJSON,
                classifierUpgradesJSON: result.classifierUpgradesJSON,
                outcomeScore: result.score,
                metrics: finalMetrics
            )
            // Phase D: also emit a meals.jsonl telemetry row + per-meal
            // history append for retrospective analysis off-device.
            emitSavedMealInstanceTelemetry(
                instanceId: instId,
                windowId: resolvedWindowId,
                activatedAt: activatedAt,
                closedAt: closedAt,
                finalClassification: finalClassification,
                metrics: finalMetrics,
                score: result.score,
                bgCurveJSON: result.bgCurveJSON,
                smbsJSON: result.smbsJSON,
                classifierUpgradesJSON: result.classifierUpgradesJSON
            )
        }

        // Queue this window for the +6h post-prandial outcome pass. The next
        // foreground after closedAt + 6h will compute peak BG / time-above-180 /
        // total insulin from CoreData and emit a second summary row.
        outcomes.enqueue(AlgorithmTelemetryOutcomes.Pending(
            windowId: resolvedWindowId,
            activatedAt: activatedAt,
            closedAt: closedAt,
            closeReason: closeReason,
            estimatedCarbs: estimatedCarbs,
            carbsConfirmed: carbsConfirmed
        ))
    }

    /// Process any pending outcome computations whose +6h tail has elapsed. Called
    /// from app foreground. Writes a second summary.jsonl row per resolved window
    /// (carrying the outcome metrics that need post-prandial data to compute).
    func processReadyOutcomes() {
        guard settingsManager.settings.telemetryEnabled else { return }
        let ready = outcomes.dequeueReady()
        guard !ready.isEmpty else { return }

        let ctx = CoreDataStack.shared.newTaskContext()
        let p = settingsManager.preferences
        for pending in ready {
            // Re-use the floor activation count we tracked at close-time. If the app was
            // restarted in between we don't have it; fall back to 0.
            let count = pending.windowId == lastWindowIdForFloorTracking
                ? floorActivationsThisWindow : 0
            if let summary = outcomes.computeOutcome(
                for: pending,
                bgAtActivation: nil,
                iobAtActivation: nil,
                cobAtActivation: nil,
                floorActivationCount: count,
                currentMaxIOB: p.maxIOB,
                currentSmbDeliveryRatio: p.smbDeliveryRatio,
                currentMaxSMBBasalMinutes: p.maxSMBBasalMinutes,
                currentMaxUAMSMBBasalMinutes: p.maxUAMSMBBasalMinutes,
                context: ctx
            ) {
                logSummary(summary)
            }
        }
    }
}
