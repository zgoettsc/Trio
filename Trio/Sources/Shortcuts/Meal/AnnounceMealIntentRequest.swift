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

    /// Open a meal-announcement window. When `savedMealId` is provided, the
    /// window seeds with that meal's default classification / phantom-COB /
    /// extended duration, and a SavedMealInstance row is created and linked
    /// to the window for outcome tracking.
    func announce(estimatedCarbs: Decimal?, savedMealId: UUID?) async throws -> String {
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

        // If we have a saved meal, create the instance row now and link it.
        if let mealId = savedMealId, let meal = savedMealStorage.meal(id: mealId) {
            let instanceId = savedMealStorage.startInstance(meal: meal, windowId: windowId, startedAt: now)
            var s2 = settingsManager.settings
            s2.mealWindowSavedMealInstanceId = instanceId.uuidString
            settingsManager.settings = s2
        }

        // Telemetry: log activation with whatever context we have on-hand. Loop samples
        // (Phase 2 hook in OpenAPS) will fill in signal/velocity data on the next pass.
        let snapshot = await currentSnapshot()
        // Now we have the activation BG — write it for the classifier's
        // Phase 2 baseline reference.
        if let bg = snapshot.bg {
            var s2 = settingsManager.settings
            s2.mealClassifierActivationBG = bg
            settingsManager.settings = s2
        }
        var activationPayload: [String: AlgorithmTelemetryJSONValue] = [
            "source": .string("shortcut"),
            "estimatedCarbs": .from(estimatedCarbs),
            "bg": .from(snapshot.bg),
            "iob": .from(snapshot.iob),
            "cob": .from(snapshot.cob),
            "delta5m": .from(snapshot.delta5m),
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
        var s = settingsManager.settings
        s.mealWindowActivationDate = nil
        s.mealWindowEstimatedCarbs = 0
        s.mealWindowCarbsConfirmed = false
        s.mealWindowId = nil
        // Wipe classifier state so the next window starts clean.
        s.mealCurrentClassification = .simple
        s.mealClassifierActivationBG = nil
        s.mealClassifierPhase1ConfirmedAt = nil
        s.mealClassifierPhase1Trough = nil
        s.mealClassifierPhase2ConfirmedAt = nil
        s.mealClassifierUpgradedAt = nil
        s.mealWindowSavedMealId = nil
        s.mealWindowSavedMealInstanceId = nil
        settingsManager.settings = s

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
        if let activatedAt {
            algorithmTelemetryManager?.recordWindowClose(
                windowId: windowId,
                activatedAt: activatedAt,
                closedAt: now,
                closeReason: "userCancelledShortcut",
                estimatedCarbs: settingsManager.settings.mealWindowEstimatedCarbs > 0
                    ? Double(truncating: settingsManager.settings.mealWindowEstimatedCarbs as NSDecimalNumber)
                    : nil,
                carbsConfirmed: settingsManager.settings.mealWindowCarbsConfirmed,
                bgAtActivation: snapshot.bg,
                iobAtActivation: snapshot.iob,
                cobAtActivation: snapshot.cob.map { Double($0) }
            )
        }

        try await apsManager.determineBasalSync()
        return String(localized: "Eating mode cancelled.")
    }

    // MARK: - Snapshot helper

    private struct ContextSnapshot {
        let bg: Double?
        let iob: Double?
        let cob: Int?
        let delta5m: Double?
    }

    private func currentSnapshot() async -> ContextSnapshot {
        // Best-effort: don't fail the intent if any of these throw or return nil.
        var bg: Double?
        var delta: Double?
        var iob: Double?
        var cob: Int?

        // Glucose: latest reading + 5-min delta via CoreData (avoids depending on
        // Nightscout sync queue state).
        await viewContext.perform {
            let req = GlucoseStored.fetchRequest()
            req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
            req.fetchLimit = 2
            if let results = try? self.viewContext.fetch(req) {
                if let last = results.first { bg = Double(last.glucose) }
                if results.count >= 2 {
                    delta = Double(results[0].glucose - results[1].glucose)
                }
            }
        }
        // IOB
        if let iobValue = iobService.currentIOB {
            iob = Double(truncating: iobValue as NSDecimalNumber)
        }

        // COB from latest determination
        await viewContext.perform {
            let req = OrefDetermination.fetchRequest()
            req.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: false)]
            req.fetchLimit = 1
            if let result = try? self.viewContext.fetch(req).first {
                cob = Int(result.cob)
            }
        }

        return ContextSnapshot(bg: bg, iob: iob, cob: cob, delta5m: delta)
    }
}
