import CoreData
import Foundation

@available(iOS 16.0, *) final class AnnounceMealIntentRequest: BaseIntentsRequest {
    /// Open a meal-announcement window. The loop will read `mealWindowActive` from
    /// `TrioCustomOrefVariables` on its next pass and apply more aggressive coverage
    /// (auto-enabled tough-meal SMB cap, insulinReq floor when BG is rising, slowed
    /// COB drain). The window auto-expires; the user does not need to cancel it.
    func announce(estimatedCarbs: Decimal?) async throws -> String {
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
        settingsManager.settings = s

        // Telemetry: log activation with whatever context we have on-hand. Loop samples
        // (Phase 2 hook in OpenAPS) will fill in signal/velocity data on the next pass.
        let snapshot = await currentSnapshot()
        algorithmTelemetryManager?.logEvent(AlgorithmTelemetryEvent(
            kind: .mealWindowActivated,
            timestamp: now,
            windowId: windowId,
            payload: [
                "source": .string("shortcut"),
                "estimatedCarbs": .from(estimatedCarbs),
                "bg": .from(snapshot.bg),
                "iob": .from(snapshot.iob),
                "cob": .from(snapshot.cob),
                "delta5m": .from(snapshot.delta5m),
                "durationMinutes": .from(s.mealWindowDurationMinutes)
            ]
        ))

        // Force a loop pass so coverage starts immediately rather than on the next 5-min tick.
        try await apsManager.determineBasalSync()

        let durationMin = Int(truncating: settingsManager.settings.mealWindowDurationMinutes as NSDecimalNumber)
        if let c = estimatedCarbs, c > 0 {
            return String(
                localized: "Eating mode on for \(durationMin) min (~\(c.description) g hint)."
            )
        } else {
            return String(localized: "Eating mode on for \(durationMin) min.")
        }
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
