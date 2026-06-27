import CoreData
import Foundation

/// Three-phase live classifier for active meal windows. See
/// `docs/MEAL_INTELLIGENCE_DESIGN.md` §4 for the full rule.
///
/// Runs once per loop pass (called by `APSManager` after the loop sample is
/// written). Reads BG/event history from CoreData + the active window state
/// in `SettingsManager`, applies the 3-phase rule, and — if the rule fires —
/// emits an upgrade by:
///   1. Writing `mealCurrentClassification = .complex` back to settings
///   2. Extending the window's effective end time
///   3. Logging a `mealWindowClassifierUpgraded` telemetry event
///   4. Optionally injecting phantom COB (handled by oref next pass)
///
/// Upgrade-only — never downgrades. State carried in `TrioSettings` so it
/// survives app restarts (windows are long-lived; we can't assume the app
/// stayed in memory).
final class MealClassifier {
    private let settingsManager: SettingsManager
    private let telemetry: AlgorithmTelemetryManager?
    private let viewContext: NSManagedObjectContext

    init(
        settingsManager: SettingsManager,
        telemetry: AlgorithmTelemetryManager?,
        viewContext: NSManagedObjectContext
    ) {
        self.settingsManager = settingsManager
        self.telemetry = telemetry
        self.viewContext = viewContext
    }

    /// Call once on every meal-window activation to reset per-window state.
    /// Captures the activation BG as the Phase 2 baseline reference.
    func onWindowActivated(activationBG: Double?) {
        var s = settingsManager.settings
        s.mealCurrentClassification = .simple
        s.mealClassifierActivationBG = activationBG
        s.mealClassifierPhase1ConfirmedAt = nil
        s.mealClassifierPhase1Trough = nil
        s.mealClassifierPhase2ConfirmedAt = nil
        s.mealClassifierUpgradedAt = nil
        settingsManager.settings = s
    }

    /// Call when a meal-window ends (expired / cancelled). Wipes classifier
    /// state so the next window starts clean. Doesn't touch the historical
    /// telemetry records that already shipped.
    func onWindowEnded() {
        var s = settingsManager.settings
        s.mealCurrentClassification = .simple
        s.mealClassifierActivationBG = nil
        s.mealClassifierPhase1ConfirmedAt = nil
        s.mealClassifierPhase1Trough = nil
        s.mealClassifierPhase2ConfirmedAt = nil
        s.mealClassifierUpgradedAt = nil
        settingsManager.settings = s
    }

    /// Called by APSManager after each loop pass. Reads recent BG, applies
    /// the 3-phase rule, and may emit an upgrade. No-op if the window is
    /// inactive, the classifier is disabled, or no upgrade is warranted.
    func evaluate() {
        let s = settingsManager.settings
        guard s.mealClassifierEnabled else { return }
        guard let activatedAt = s.mealWindowActivationDate else { return }
        guard let activationBG = s.mealClassifierActivationBG else { return }
        // Already at the top — nothing to do.
        guard s.mealCurrentClassification != .complex else { return }

        let now = Date()
        let recent = fetchRecentBG(limit: 12)  // ~60 min of 5-min readings
        guard recent.count >= 2 else { return }

        // Recent readings come out newest-first; classifier wants oldest-first.
        let chronological = recent.reversed().map { (date: $0.date ?? now, bg: Double($0.glucose)) }

        evaluatePhase1(now: now, activatedAt: activatedAt, activationBG: activationBG, samples: chronological)
        evaluatePhase2(now: now, activatedAt: activatedAt, activationBG: activationBG, samples: chronological)
        evaluatePhase3(now: now, activatedAt: activatedAt, samples: chronological)
    }

    // MARK: - Phase 1: carb absorption climb

    private func evaluatePhase1(
        now: Date,
        activatedAt: Date,
        activationBG: Double,
        samples: [(date: Date, bg: Double)]
    ) {
        let s = settingsManager.settings
        guard s.mealClassifierPhase1ConfirmedAt == nil else {
            // Already confirmed — but we still maintain the running trough
            // for Phase 2 to reference.
            updatePhase1Trough(samples: samples)
            return
        }

        // Only consider Phase 1 in the first 90 minutes after activation
        // (after that, "rising from baseline" is more likely a snack than the
        // initial meal climb).
        let minutesSinceActivation = now.timeIntervalSince(activatedAt) / 60
        guard minutesSinceActivation <= 90 else { return }

        let deltaThreshold = Double(truncating: s.mealClassifierPhase1DeltaThreshold as NSNumber)
        let sustainedCount = Int(truncating: s.mealClassifierPhase1SustainedReadings as NSNumber)
        let absoluteRise = Double(truncating: s.mealClassifierPhase1AbsoluteRiseMgdL as NSNumber)

        // Path 1: absolute BG rise from activation
        let currentBG = samples.last?.bg ?? activationBG
        let absoluteRisePath = (currentBG - activationBG) >= absoluteRise

        // Path 2: sustained rising delta — last N readings each > deltaThreshold above the prior one
        let sustainedDeltaPath: Bool = {
            guard samples.count >= sustainedCount + 1 else { return false }
            let tail = samples.suffix(sustainedCount + 1)
            let deltas = zip(tail.dropLast(), tail.dropFirst()).map { $1.bg - $0.bg }
            return deltas.allSatisfy { $0 >= deltaThreshold }
        }()

        guard absoluteRisePath || sustainedDeltaPath else { return }

        // Confirmed.
        var newSettings = s
        newSettings.mealClassifierPhase1ConfirmedAt = now
        // Initial trough = current BG; will be updated as BG falls during recovery.
        newSettings.mealClassifierPhase1Trough = currentBG
        // Upgrade Simple → Medium (classifier baseline once Phase 1 fires).
        if newSettings.mealCurrentClassification.rank < MealClassification.medium.rank {
            newSettings.mealCurrentClassification = .medium
        }
        settingsManager.settings = newSettings

        telemetry?.logEvent(AlgorithmTelemetryEvent(
            kind: .mealWindowClassifierPhase,
            timestamp: now,
            windowId: s.mealWindowId,
            payload: [
                "phase": .string("phase1"),
                "trigger": .string(absoluteRisePath ? "absoluteRise" : "sustainedDelta"),
                "bg": .double(currentBG),
                "activationBG": .double(activationBG),
                "minutesSinceActivation": .double(minutesSinceActivation)
            ]
        ))
    }

    /// While Phase 1 has confirmed but Phase 2 hasn't, keep updating the
    /// post-peak trough — it's the baseline reference for Phase 2.
    private func updatePhase1Trough(samples: [(date: Date, bg: Double)]) {
        let s = settingsManager.settings
        guard s.mealClassifierPhase2ConfirmedAt == nil,
              let currentTrough = s.mealClassifierPhase1Trough,
              let currentBG = samples.last?.bg
        else { return }
        if currentBG < currentTrough {
            var newSettings = s
            newSettings.mealClassifierPhase1Trough = currentBG
            settingsManager.settings = newSettings
        }
    }

    // MARK: - Phase 2: recovery into stable band

    private func evaluatePhase2(
        now: Date,
        activatedAt: Date,
        activationBG: Double,
        samples: [(date: Date, bg: Double)]
    ) {
        let s = settingsManager.settings
        // Requires Phase 1 first; if already confirmed, nothing to do.
        guard s.mealClassifierPhase1ConfirmedAt != nil else { return }
        guard s.mealClassifierPhase2ConfirmedAt == nil else { return }

        let rangeMgdL = Double(truncating: s.mealClassifierPhase2RangeMgdL as NSNumber)
        let minMinutes = Double(truncating: s.mealClassifierPhase2MinDurationMinutes as NSNumber)

        // Baseline is min(activationBG, postPhase1Trough) per Round-9 finding.
        let trough = s.mealClassifierPhase1Trough ?? activationBG
        let baseline = min(activationBG, trough)

        // Require N minutes of samples within ±range of baseline.
        let cutoff = now.addingTimeInterval(-minMinutes * 60)
        let recentEnoughSamples = samples.filter { $0.date >= cutoff }
        guard !recentEnoughSamples.isEmpty else { return }
        // Span check — earliest sample in the recent window must be at least
        // `minMinutes` old, otherwise we haven't observed `minMinutes` yet.
        guard let earliest = recentEnoughSamples.first?.date,
              now.timeIntervalSince(earliest) >= minMinutes * 60 - 30  // 30s slack
        else { return }
        // Every sample in the window must be within range.
        let allInRange = recentEnoughSamples.allSatisfy { abs($0.bg - baseline) <= rangeMgdL }
        guard allInRange else { return }

        // Confirmed.
        var newSettings = s
        newSettings.mealClassifierPhase2ConfirmedAt = now
        settingsManager.settings = newSettings

        telemetry?.logEvent(AlgorithmTelemetryEvent(
            kind: .mealWindowClassifierPhase,
            timestamp: now,
            windowId: s.mealWindowId,
            payload: [
                "phase": .string("phase2"),
                "baseline": .double(baseline),
                "trough": .double(trough),
                "rangeMgdL": .double(rangeMgdL),
                "stableMinutes": .double(now.timeIntervalSince(earliest) / 60)
            ]
        ))
    }

    // MARK: - Phase 3: late fat onset → upgrade to Complex

    private func evaluatePhase3(
        now: Date,
        activatedAt: Date,
        samples: [(date: Date, bg: Double)]
    ) {
        let s = settingsManager.settings
        // Requires Phase 2 first; if already at Complex, nothing to do.
        guard s.mealClassifierPhase2ConfirmedAt != nil else { return }
        guard s.mealCurrentClassification.rank < MealClassification.complex.rank else { return }

        let deltaThreshold = Double(truncating: s.mealClassifierPhase3DeltaThreshold as NSNumber)
        let sustainedMinutes = Double(truncating: s.mealClassifierPhase3SustainedDurationMinutes as NSNumber)
        let exclusionMinutes = Double(truncating: s.mealClassifierPhase3CarbExclusionMinutes as NSNumber)

        // Recent carb entry exclusion — if user logged carbs in last N min,
        // the rise might just be a snack, not late fat.
        if hasRecentCarbEntry(within: exclusionMinutes * 60, at: now) { return }

        // Sustained rising delta for last `sustainedMinutes` of samples.
        let cutoff = now.addingTimeInterval(-sustainedMinutes * 60)
        let tail = samples.filter { $0.date >= cutoff }
        guard tail.count >= 2,
              let earliest = tail.first?.date,
              now.timeIntervalSince(earliest) >= sustainedMinutes * 60 - 30
        else { return }
        let deltas = zip(tail.dropLast(), tail.dropFirst()).map { $1.bg - $0.bg }
        guard deltas.allSatisfy({ $0 >= deltaThreshold }) else { return }

        // Trigger upgrade.
        triggerComplexUpgrade(at: now, activatedAt: activatedAt, samples: samples)
    }

    /// Performs the Complex upgrade side effects:
    /// - Settings: classification = .complex, upgradedAt = now, phantomCOB on
    /// - Window: extend to maxTotalDurationMinutes from activation (per design Q1)
    /// - Telemetry: upgrade event with full context
    private func triggerComplexUpgrade(
        at now: Date,
        activatedAt: Date,
        samples: [(date: Date, bg: Double)]
    ) {
        var s = settingsManager.settings
        let previousClassification = s.mealCurrentClassification
        s.mealCurrentClassification = .complex
        s.mealClassifierUpgradedAt = now

        // Enable phantom COB for the remainder of this window. We toggle the
        // existing per-window setting on; oref reads it next pass. The
        // window-end logic (onWindowEnded) does NOT reset this flag — it's a
        // persistent user preference normally; for the Complex-upgrade case
        // we accept that it stays on for any future window until the user
        // turns it off manually. That's the documented design tradeoff.
        s.mealWindowPhantomCOB = true
        // Use the classifier's dedicated phantom dose, not the standing one,
        // so the user can tune Complex-upgrade aggression separately.
        s.mealWindowPhantomCOBGrams = s.mealClassifierPhantomCOBGramsOnUpgrade

        // Bump window duration to the classifier max (per Q1 recommendation:
        // push to max for full late-phase coverage; user has Cancel for safety).
        // We do this by overriding the relevant duration field that
        // APSManager uses to compute window-end. With carbsConfirmed=true,
        // APSManager uses mealWindowExtendedDurationMinutes — promote it.
        let maxTotal = Double(truncating: s.mealClassifierMaxTotalDurationMinutes as NSNumber)
        let bumpedExtended = Decimal(maxTotal)
        if s.mealWindowExtendedDurationMinutes < bumpedExtended {
            s.mealWindowExtendedDurationMinutes = bumpedExtended
        }
        // Make sure carbsConfirmed is true so the extended duration is
        // actually used by APSManager's expiry math. Safe even if it wasn't
        // confirmed by an explicit carb entry — the classifier IS the
        // confirmation here.
        s.mealWindowCarbsConfirmed = true

        settingsManager.settings = s

        let currentBG = samples.last?.bg ?? 0
        telemetry?.logEvent(AlgorithmTelemetryEvent(
            kind: .mealWindowClassifierUpgraded,
            timestamp: now,
            windowId: s.mealWindowId,
            payload: [
                "from": .string(previousClassification.rawValue),
                "to": .string(MealClassification.complex.rawValue),
                "trigger": .string("lateRiseDetected"),
                "bgAtTrigger": .double(currentBG),
                "minutesSinceActivation": .double(now.timeIntervalSince(activatedAt) / 60),
                "newExtendedDurationMinutes": .from(s.mealWindowExtendedDurationMinutes),
                "phantomCOBGrams": .from(s.mealWindowPhantomCOBGrams)
            ]
        ))
    }

    // MARK: - Helpers

    private func fetchRecentBG(limit: Int) -> [GlucoseStored] {
        var results: [GlucoseStored] = []
        viewContext.performAndWait {
            let req = GlucoseStored.fetchRequest()
            req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            req.fetchLimit = limit
            results = (try? viewContext.fetch(req)) ?? []
        }
        return results
    }

    private func hasRecentCarbEntry(within seconds: TimeInterval, at now: Date) -> Bool {
        var found = false
        viewContext.performAndWait {
            let req = CarbEntryStored.fetchRequest()
            req.fetchLimit = 1
            let cutoff = now.addingTimeInterval(-seconds)
            req.predicate = NSPredicate(format: "date >= %@ AND carbs > 0", cutoff as NSDate)
            found = ((try? viewContext.count(for: req)) ?? 0) > 0
        }
        return found
    }
}
