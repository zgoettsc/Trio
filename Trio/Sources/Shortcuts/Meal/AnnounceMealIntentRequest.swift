import CoreData
import Foundation

@available(iOS 16.0, *) final class AnnounceMealIntentRequest: BaseIntentsRequest {
    /// Open a meal-announcement window. The loop will read `mealWindowActive` from
    /// `TrioCustomOrefVariables` on its next pass and apply more aggressive coverage
    /// (auto-enabled tough-meal SMB cap, insulinReq floor when BG is rising, slowed
    /// COB drain). The window auto-expires; the user does not need to cancel it.
    /// Convenience overload — no saved meal, classifier auto-discovers.
    func announce(estimatedCarbs: Decimal?) async throws -> String {
        try await announce(estimatedCarbs: estimatedCarbs, savedMealId: nil)
    }

    /// Used by the Saved Meals page's "Start eating mode with this meal"
    /// button. Stores a CarbEntry with the meal's default macros (so COB
    /// updates immediately and oref sees the meal on the next pass) AND
    /// opens the eating-mode window. The user is expected to bolus
    /// separately via the Treatments screen.
    ///
    /// If the meal has no default carbs/fat/protein set, this falls back
    /// to opening the window only (same as plain announce).
    func startMealAndLogCarbs(savedMealId: UUID) async throws -> String {
        try await startMealAndLogCarbs(
            savedMealId: savedMealId,
            carbsOverride: nil,
            fatOverride: nil,
            proteinOverride: nil
        )
    }

    /// Like `startMealAndLogCarbs(savedMealId:)` but uses the supplied macro
    /// values instead of the meal's defaults. Used by the in-app confirm
    /// sheet where the user can scale a half portion / edit values before
    /// committing. Pass `nil` for any field to keep the default.
    func startMealAndLogCarbs(
        savedMealId: UUID,
        carbsOverride: Decimal?,
        fatOverride: Decimal?,
        proteinOverride: Decimal?
    ) async throws -> String {
        guard let meal = savedMealStorage.meal(id: savedMealId) else {
            return try await announce(estimatedCarbs: nil, savedMealId: savedMealId)
        }
        let carbs = carbsOverride ?? (meal.defaultCarbs as Decimal?) ?? 0
        let fat = fatOverride ?? (meal.defaultFat as Decimal?) ?? 0
        let protein = proteinOverride ?? (meal.defaultProtein as Decimal?) ?? 0

        // Only write a CarbEntry when the meal has macros configured.
        // Without macros, this collapses to a plain "open window only" call.
        if carbs > 0 || fat > 0 || protein > 0 {
            let entry = CarbsEntry(
                id: UUID().uuidString,
                createdAt: Date(),
                actualDate: Date(),
                carbs: carbs,
                fat: fat,
                protein: protein,
                note: meal.name,
                enteredBy: CarbsEntry.local,
                isFPU: false,
                fpuID: (fat > 0 || protein > 0) ? UUID().uuidString : nil
            )
            try await carbsStorage.storeCarbs([entry], areFetchedFromRemote: false)
        }

        let result = try await announce(
            estimatedCarbs: carbs > 0 ? carbs : nil,
            savedMealId: savedMealId,
            actualFat: fat > 0 ? fat : nil,
            actualProtein: protein > 0 ? protein : nil
        )
        // Append a note reminding the user to bolus separately so they don't
        // assume the carbs covered themselves.
        if carbs > 0 || fat > 0 || protein > 0 {
            return result + " " + String(localized: "Carbs logged — bolus separately.")
        }
        return result
    }

    /// Convenience overload — saved meal, no explicit fat/protein.
    func announce(estimatedCarbs: Decimal?, savedMealId: UUID?) async throws -> String {
        try await announce(
            estimatedCarbs: estimatedCarbs,
            savedMealId: savedMealId,
            actualFat: nil,
            actualProtein: nil
        )
    }

    /// Open a meal-announcement window. When `savedMealId` is provided, the
    /// window seeds with that meal's default classification / phantom-COB /
    /// extended duration, and a SavedMealInstance row is created and linked
    /// to the window for outcome tracking.
    ///
    /// `actualFat` / `actualProtein` are used to populate the
    /// SavedMealInstance row with the user's real entered macros (from the
    /// Treatments picker after they edited the fields). When nil, the
    /// instance falls back to the meal's defaults.
    func announce(
        estimatedCarbs: Decimal?,
        savedMealId: UUID?,
        actualFat: Decimal?,
        actualProtein: Decimal?
    ) async throws -> String {
        var s = settingsManager.settings
        let now = Date()
        let windowId = UUID().uuidString
        s.mealWindowActivationDate = now
        s.mealWindowId = windowId
        if let c = estimatedCarbs, c > 0 {
            s.mealWindowEstimatedCarbs = min(c, settingsManager.settings.maxCarbs)
            s.mealWindowCarbsConfirmed = false
        } else {
            s.mealWindowEstimatedCarbs = 0
            s.mealWindowCarbsConfirmed = false
        }
        // Reset live classifier state for the new window. Activation BG is set
        // below after we capture the snapshot.
        s.mealCurrentClassification = .simple
        s.mealClassifierActivationBG = nil
        s.mealClassifierPhase1ConfirmedAt = nil
        s.mealClassifierPhase1Trough = nil
        s.mealClassifierPhase2ConfirmedAt = nil
        s.mealClassifierUpgradedAt = nil
        s.mealWindowSavedMealId = nil
        s.mealWindowSavedMealInstanceId = nil

        // Apply saved-meal seed BEFORE writing settings so subsequent reads
        // see the seeded state. If the meal has a defaultClassification, we
        // seed the live classifier to start at that level (upgrade-only rule
        // means it can only go up from here).
        var resolvedMealName: String?
        if let mealId = savedMealId, let meal = savedMealStorage.meal(id: mealId) {
            resolvedMealName = meal.name
            s.mealWindowSavedMealId = mealId.uuidString
            if let seedRaw = meal.defaultClassification,
               let seed = MealClassification(rawValue: seedRaw)
            {
                s.mealCurrentClassification = seed
            }
            // Per-meal phantom COB override — if the saved meal has it on, turn
            // it on for this window with the meal's configured dose.
            if meal.defaultPhantomCOBEnabled {
                s.mealWindowPhantomCOB = true
                if let g = meal.defaultPhantomCOBGrams {
                    s.mealWindowPhantomCOBGrams = g as Decimal
                }
            }
            // Per-meal extended duration override.
            if meal.defaultExtendedDurationMinutes > 0 {
                s.mealWindowExtendedDurationMinutes = Decimal(meal.defaultExtendedDurationMinutes)
                // Mark as confirmed so APSManager uses the extended duration
                // immediately — the user explicitly told us this is a known meal.
                s.mealWindowCarbsConfirmed = true
            }
        }

        settingsManager.settings = s

        // Telemetry/context snapshot must happen BEFORE instance creation so
        // we can persist sensitivity context (Autosens, Smart-Sense, ISF) and
        // baseline BG on the instance row — analytics correlates these with
        // peak excursion later. See ANALYSIS_METHODS.md "Instance context".
        let snapshot = await currentSnapshot()
        // Now we have the activation BG — write it for the classifier's
        // Phase 2 baseline reference.
        if let bg = snapshot.bg {
            var s2 = settingsManager.settings
            s2.mealClassifierActivationBG = bg
            settingsManager.settings = s2
        }

        // If we have a saved meal, create the instance row now and link it,
        // capturing the sensitivity/BG context as a one-shot snapshot.
        if let mealId = savedMealId, let meal = savedMealStorage.meal(id: mealId) {
            let instanceId = savedMealStorage.startInstance(
                meal: meal,
                windowId: windowId,
                startedAt: now,
                actualCarbs: estimatedCarbs,
                actualFat: actualFat,
                actualProtein: actualProtein,
                bgAtActivation: snapshot.bg,
                bgTrendAtActivation: snapshot.bgTrend30m,
                autosensRatio: snapshot.autosensRatio,
                smartSenseRatio: snapshot.smartSenseRatio,
                effectiveISF: snapshot.effectiveISF,
                carbRatio: snapshot.carbRatio
            )
            var s2 = settingsManager.settings
            s2.mealWindowSavedMealInstanceId = instanceId.uuidString
            settingsManager.settings = s2
        }

        var activationPayload: [String: AlgorithmTelemetryJSONValue] = [
            "source": .string("shortcut"),
            "estimatedCarbs": .from(estimatedCarbs),
            "bg": .from(snapshot.bg),
            "iob": .from(snapshot.iob),
            "cob": .from(snapshot.cob),
            "delta5m": .from(snapshot.delta5m),
            "bgTrend30m": .from(snapshot.bgTrend30m),
            "autosensRatio": .from(snapshot.autosensRatio),
            "smartSenseRatio": .from(snapshot.smartSenseRatio),
            "effectiveISF": .from(snapshot.effectiveISF),
            "carbRatio": .from(snapshot.carbRatio),
            "durationMinutes": .from(s.mealWindowDurationMinutes)
        ]
        if let mealId = savedMealId {
            activationPayload["savedMealId"] = .string(mealId.uuidString)
            activationPayload["savedMealName"] = .from(resolvedMealName)
            activationPayload["seededClassification"] = .string(s.mealCurrentClassification.rawValue)
        }
        algorithmTelemetryManager?.logEvent(AlgorithmTelemetryEvent(
            kind: .mealWindowActivated,
            timestamp: now,
            windowId: windowId,
            payload: activationPayload
        ))

        // Force a loop pass so coverage starts immediately rather than on the next 5-min tick.
        try await apsManager.determineBasalSync()

        // Check whether an active override is suppressing SMB delivery — meal
        // window aggression can't fire if microBolusAllowed is false. Surface
        // a one-line warning so the user knows what they're getting.
        let overrideWarning = detectActiveSMBSuppression()

        let durationMin = Int(truncating: settingsManager.settings.mealWindowDurationMinutes as NSDecimalNumber)
        let base: String
        if let c = estimatedCarbs, c > 0 {
            base = String(localized: "Eating mode on for \(durationMin) min (~\(c.description) g hint).")
        } else {
            base = String(localized: "Eating mode on for \(durationMin) min.")
        }
        if let warning = overrideWarning {
            return base + " " + warning
        }
        return base
    }

    /// Returns a user-facing warning string when an active override is
    /// suppressing SMBs (its smbIsOff flag is true). Nil when no override is
    /// active or none suppress SMB. See Round-9 case study — Running override
    /// silently disabled SMBs during a meal window and no aggression fired.
    private func detectActiveSMBSuppression() -> String? {
        var warning: String?
        viewContext.performAndWait {
            let req = OverrideStored.fetchRequest()
            req.predicate = NSPredicate(format: "enabled == YES AND smbIsOff == YES")
            req.fetchLimit = 1
            if let active = (try? viewContext.fetch(req))?.first {
                let name = active.name ?? "Active override"
                warning = String(
                    localized: "⚠ \(name) is suppressing SMBs — eating mode boost won't fire."
                )
            }
        }
        return warning
    }

    /// Cancel an active meal window immediately. Safe to call when no window is active.
    func cancel() async throws -> String {
        guard settingsManager.settings.mealWindowActivationDate != nil else {
            return String(localized: "No active eating mode to cancel.")
        }
        let windowId = settingsManager.settings.mealWindowId
        let activatedAt = settingsManager.settings.mealWindowActivationDate
        // Capture the carbs-confirmed + estimated values BEFORE wiping settings
        // so the recordWindowClose call below has accurate context.
        let estimatedCarbs = settingsManager.settings.mealWindowEstimatedCarbs
        let carbsConfirmed = settingsManager.settings.mealWindowCarbsConfirmed

        let snapshot = await currentSnapshot()
        let now = Date()
        algorithmTelemetryManager?.logEvent(AlgorithmTelemetryEvent(
            kind: .mealWindowCancelled,
            timestamp: now,
            windowId: windowId,
            payload: [
                "source": .string("shortcut"),
                "minutesSinceActivation": .from(activatedAt.map { now.timeIntervalSince($0) / 60 }),
                "bg": .from(snapshot.bg),
                "iob": .from(snapshot.iob)
            ]
        ))
        // IMPORTANT: recordWindowClose reads mealWindowSavedMealInstanceId
        // from settings to find the linked SavedMealInstance and close it
        // with computed outcome metrics. We MUST call it BEFORE wiping
        // those settings fields below — otherwise the instance is orphaned
        // (left with closedAt=nil in CoreData and no telemetry emit).
        if let activatedAt {
            algorithmTelemetryManager?.recordWindowClose(
                windowId: windowId,
                activatedAt: activatedAt,
                closedAt: now,
                closeReason: "userCancelledShortcut",
                estimatedCarbs: estimatedCarbs > 0
                    ? Double(truncating: estimatedCarbs as NSDecimalNumber)
                    : nil,
                carbsConfirmed: carbsConfirmed,
                bgAtActivation: snapshot.bg,
                iobAtActivation: snapshot.iob,
                cobAtActivation: snapshot.cob.map { Double($0) }
            )
        }

        // Now wipe all the meal-window + classifier state.
        var s = settingsManager.settings
        s.mealWindowActivationDate = nil
        s.mealWindowEstimatedCarbs = 0
        s.mealWindowCarbsConfirmed = false
        s.mealWindowId = nil
        s.mealCurrentClassification = .simple
        s.mealClassifierActivationBG = nil
        s.mealClassifierPhase1ConfirmedAt = nil
        s.mealClassifierPhase1Trough = nil
        s.mealClassifierPhase2ConfirmedAt = nil
        s.mealClassifierUpgradedAt = nil
        s.mealWindowSavedMealId = nil
        s.mealWindowSavedMealInstanceId = nil
        settingsManager.settings = s

        try await apsManager.determineBasalSync()
        return String(localized: "Eating mode cancelled.")
    }

    // MARK: - Snapshot helper

    private struct ContextSnapshot {
        let bg: Double?
        let iob: Double?
        let cob: Int?
        let delta5m: Double?
        let bgTrend30m: Double?
        let autosensRatio: Double?
        let smartSenseRatio: Double?
        let effectiveISF: Double?
        let carbRatio: Double?
    }

    private func currentSnapshot() async -> ContextSnapshot {
        // Best-effort: don't fail the intent if any of these throw or return nil.
        var bg: Double?
        var delta: Double?
        var iob: Double?
        var cob: Int?
        var bgTrend30m: Double?
        var autosensRatio: Double?
        var effectiveISF: Double?
        var carbRatio: Double?

        // Glucose: latest reading + 5-min delta + 30-min trend via CoreData
        // (avoids depending on Nightscout sync queue state). Pulling enough
        // readings to cover ~30 min back (12 samples at 5-min spacing + slack).
        let now = Date()
        await viewContext.perform {
            let req = GlucoseStored.fetchRequest()
            req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            req.fetchLimit = 12
            if let results = try? self.viewContext.fetch(req), let first = results.first {
                bg = Double(first.glucose)
                if results.count >= 2 {
                    delta = Double(results[0].glucose - results[1].glucose)
                }
                // 30-min trend: find the reading closest to (now - 30min) and
                // diff against the latest. Falls back to nil if we don't have
                // 30+ minutes of data.
                let target = now.addingTimeInterval(-30 * 60)
                let candidate = results.min { lhs, rhs in
                    guard let ld = lhs.date, let rd = rhs.date else { return false }
                    return abs(ld.timeIntervalSince(target)) < abs(rd.timeIntervalSince(target))
                }
                if let cand = candidate, let cd = cand.date,
                   abs(cd.timeIntervalSince(target)) < 10 * 60
                {
                    bgTrend30m = Double(first.glucose - cand.glucose)
                }
            }
        }
        // IOB
        if let iobValue = iobService.currentIOB {
            iob = Double(truncating: iobValue as NSDecimalNumber)
        }

        // COB + Autosens + post-Autosens ISF from latest determination.
        await viewContext.perform {
            let req = OrefDetermination.fetchRequest()
            req.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: false)]
            req.fetchLimit = 1
            if let result = try? self.viewContext.fetch(req).first {
                cob = Int(result.cob)
                if let s = result.sensitivityRatio {
                    autosensRatio = s.doubleValue
                }
                if let isf = result.insulinSensitivity {
                    effectiveISF = isf.doubleValue
                }
                if let cr = result.carbRatio {
                    carbRatio = cr.doubleValue
                }
            }
        }

        // SmartSense final ratio — latest computed result from the manager.
        let smartSenseRatio = smartSenseManager?.latestResult?.finalRatio

        return ContextSnapshot(
            bg: bg,
            iob: iob,
            cob: cob,
            delta5m: delta,
            bgTrend30m: bgTrend30m,
            autosensRatio: autosensRatio,
            smartSenseRatio: smartSenseRatio,
            effectiveISF: effectiveISF,
            carbRatio: carbRatio
        )
    }
}
