import Foundation

@available(iOS 16.0, *) final class AnnounceMealIntentRequest: BaseIntentsRequest {
    /// Open a meal-announcement window. The loop will read `mealWindowActive` from
    /// `TrioCustomOrefVariables` on its next pass and apply more aggressive coverage
    /// (auto-enabled tough-meal SMB cap, insulinReq floor when BG is rising, slowed
    /// COB drain). The window auto-expires; the user does not need to cancel it.
    func announce(estimatedCarbs: Decimal?) async throws -> String {
        var s = settingsManager.settings
        let now = Date()
        s.mealWindowActivationDate = now
        if let c = estimatedCarbs, c > 0 {
            s.mealWindowEstimatedCarbs = min(c, settingsManager.settings.maxCarbs)
            s.mealWindowCarbsConfirmed = false
        } else {
            s.mealWindowEstimatedCarbs = 0
            s.mealWindowCarbsConfirmed = false
        }
        settingsManager.settings = s

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
        var s = settingsManager.settings
        s.mealWindowActivationDate = nil
        s.mealWindowEstimatedCarbs = 0
        s.mealWindowCarbsConfirmed = false
        settingsManager.settings = s

        try await apsManager.determineBasalSync()
        return String(localized: "Eating mode cancelled.")
    }
}
