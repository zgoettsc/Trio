import Foundation

// MARK: - Phase C: Garmin Context Snapshot
//
// A point-in-time snapshot of Garmin health data relevant to insulin sensitivity.
// Queried from Firestore at meal detection time.
//
// All field names and types match the Garmin Health API v1.2.3 spec exactly.
// Firestore path: /users/{uid}/garminData/{summaryType}/{documents}

struct GarminContextSnapshot: Codable {
    let queryTime: Date

    // === Daily Summary (from "dailies" collection) ===
    // Source: Garmin Health API §7.1
    let restingHeartRateInBeatsPerMinute: Int?
    let averageHeartRateInBeatsPerMinute: Int?  // 7-day avg HR
    let averageStressLevel: Int?                // 1-100, or -1 if insufficient data
    let maxStressLevel: Int?
    let stressDurationInSeconds: Int?
    let restStressDurationInSeconds: Int?
    let lowStressDurationInSeconds: Int?
    let mediumStressDurationInSeconds: Int?
    let highStressDurationInSeconds: Int?
    let stressQualifier: String?                // "calm", "balanced", "stressful", "very_stressful", etc.
    let steps: Int?
    let activeKilocalories: Int?
    let moderateIntensityDurationInSeconds: Int?
    let vigorousIntensityDurationInSeconds: Int?
    let bodyBatteryChargedValue: Int?           // BB charged during monitoring (moved to dailies in API v1.2.1)
    let bodyBatteryDrainedValue: Int?           // BB drained during monitoring

    // === Yesterday's Daily Summary (for delayed sensitivity effects) ===
    let yesterdaySteps: Int?
    let yesterdayActiveKilocalories: Int?
    let yesterdayModerateIntensityDurationInSeconds: Int?
    let yesterdayVigorousIntensityDurationInSeconds: Int?

    // === Sleep Summary (from "sleeps" collection) ===
    // Source: Garmin Health API §7.3
    let sleepDurationInSeconds: Int?
    let deepSleepDurationInSeconds: Int?
    let lightSleepDurationInSeconds: Int?
    let remSleepInSeconds: Int?
    let awakeDurationInSeconds: Int?
    let sleepScoreValue: Int?                   // overallSleepScore.value (0-100)
    let sleepScoreQualifier: String?            // overallSleepScore.qualifierKey: EXCELLENT/GOOD/FAIR/POOR
    let sleepValidation: String?                // AUTO_FINAL, ENHANCED_FINAL, etc.

    // === Stress Details (from "stressDetails" collection) ===
    // Source: Garmin Health API §7.5
    // Body Battery readings are in timeOffsetBodyBatteryValues map.
    // We extract the most recent (current) and the first of the day (wake).
    let currentBodyBattery: Int?                // latest BB reading from timeOffsetBodyBatteryValues
    let bodyBatteryAtWake: Int?                 // earliest BB reading of the day (proxy for recovery)
    let currentStressLevel: Int?                // latest from timeOffsetStressLevelValues (1-100)

    // === HRV Summary (from "hrv" collection) ===
    // Source: Garmin Health API §7.10
    let lastNightAvg: Int?                      // lastNightAvg HRV (RMSSD ms)
    let lastNight5MinHigh: Int?                 // max 5-min HRV window

    // === User Metrics (from "userMetrics" collection) ===
    // Source: Garmin Health API §7.6
    let vo2Max: Double?
    let fitnessAge: Int?

    // === 7-Day Averages (computed from historical documents) ===
    // These are calculated by averaging the last 7 dailies/HRV documents.
    let restingHR7DayAvg: Int?
    let hrvWeeklyAvg: Int?

    // MARK: - Computed Deltas

    /// Resting HR delta from 7-day average (positive = elevated = more resistant)
    var restingHRDelta: Int? {
        guard let current = restingHeartRateInBeatsPerMinute, let avg = restingHR7DayAvg else { return nil }
        return current - avg
    }

    /// HRV delta as percentage from weekly average (negative = suppressed = more resistant)
    var hrvDeltaPercent: Double? {
        guard let current = lastNightAvg, let avg = hrvWeeklyAvg, avg > 0 else { return nil }
        return (Double(current - avg) / Double(avg)) * 100
    }

    /// Total sleep in minutes (derived from sleepDurationInSeconds)
    var totalSleepMinutes: Int? {
        guard let seconds = sleepDurationInSeconds else { return nil }
        return seconds / 60
    }

    /// Total intensity minutes today (moderate + vigorous)
    var intensityMinutesToday: Int? {
        let moderate = (moderateIntensityDurationInSeconds ?? 0) / 60
        let vigorous = (vigorousIntensityDurationInSeconds ?? 0) / 60
        let total = moderate + vigorous
        return total > 0 ? total : nil
    }

    /// Yesterday's total intensity minutes
    var yesterdayIntensityMinutes: Int? {
        let moderate = (yesterdayModerateIntensityDurationInSeconds ?? 0) / 60
        let vigorous = (yesterdayVigorousIntensityDurationInSeconds ?? 0) / 60
        let total = moderate + vigorous
        return total > 0 ? total : nil
    }

    // MARK: - Init

    init(
        queryTime: Date = Date(),
        // Daily
        restingHeartRateInBeatsPerMinute: Int? = nil,
        averageHeartRateInBeatsPerMinute: Int? = nil,
        averageStressLevel: Int? = nil,
        maxStressLevel: Int? = nil,
        stressDurationInSeconds: Int? = nil,
        restStressDurationInSeconds: Int? = nil,
        lowStressDurationInSeconds: Int? = nil,
        mediumStressDurationInSeconds: Int? = nil,
        highStressDurationInSeconds: Int? = nil,
        stressQualifier: String? = nil,
        steps: Int? = nil,
        activeKilocalories: Int? = nil,
        moderateIntensityDurationInSeconds: Int? = nil,
        vigorousIntensityDurationInSeconds: Int? = nil,
        bodyBatteryChargedValue: Int? = nil,
        bodyBatteryDrainedValue: Int? = nil,
        // Yesterday
        yesterdaySteps: Int? = nil,
        yesterdayActiveKilocalories: Int? = nil,
        yesterdayModerateIntensityDurationInSeconds: Int? = nil,
        yesterdayVigorousIntensityDurationInSeconds: Int? = nil,
        // Sleep
        sleepDurationInSeconds: Int? = nil,
        deepSleepDurationInSeconds: Int? = nil,
        lightSleepDurationInSeconds: Int? = nil,
        remSleepInSeconds: Int? = nil,
        awakeDurationInSeconds: Int? = nil,
        sleepScoreValue: Int? = nil,
        sleepScoreQualifier: String? = nil,
        sleepValidation: String? = nil,
        // Stress Details
        currentBodyBattery: Int? = nil,
        bodyBatteryAtWake: Int? = nil,
        currentStressLevel: Int? = nil,
        // HRV
        lastNightAvg: Int? = nil,
        lastNight5MinHigh: Int? = nil,
        // User Metrics
        vo2Max: Double? = nil,
        fitnessAge: Int? = nil,
        // 7-day averages
        restingHR7DayAvg: Int? = nil,
        hrvWeeklyAvg: Int? = nil
    ) {
        self.queryTime = queryTime
        self.restingHeartRateInBeatsPerMinute = restingHeartRateInBeatsPerMinute
        self.averageHeartRateInBeatsPerMinute = averageHeartRateInBeatsPerMinute
        self.averageStressLevel = averageStressLevel
        self.maxStressLevel = maxStressLevel
        self.stressDurationInSeconds = stressDurationInSeconds
        self.restStressDurationInSeconds = restStressDurationInSeconds
        self.lowStressDurationInSeconds = lowStressDurationInSeconds
        self.mediumStressDurationInSeconds = mediumStressDurationInSeconds
        self.highStressDurationInSeconds = highStressDurationInSeconds
        self.stressQualifier = stressQualifier
        self.steps = steps
        self.activeKilocalories = activeKilocalories
        self.moderateIntensityDurationInSeconds = moderateIntensityDurationInSeconds
        self.vigorousIntensityDurationInSeconds = vigorousIntensityDurationInSeconds
        self.bodyBatteryChargedValue = bodyBatteryChargedValue
        self.bodyBatteryDrainedValue = bodyBatteryDrainedValue
        self.yesterdaySteps = yesterdaySteps
        self.yesterdayActiveKilocalories = yesterdayActiveKilocalories
        self.yesterdayModerateIntensityDurationInSeconds = yesterdayModerateIntensityDurationInSeconds
        self.yesterdayVigorousIntensityDurationInSeconds = yesterdayVigorousIntensityDurationInSeconds
        self.sleepDurationInSeconds = sleepDurationInSeconds
        self.deepSleepDurationInSeconds = deepSleepDurationInSeconds
        self.lightSleepDurationInSeconds = lightSleepDurationInSeconds
        self.remSleepInSeconds = remSleepInSeconds
        self.awakeDurationInSeconds = awakeDurationInSeconds
        self.sleepScoreValue = sleepScoreValue
        self.sleepScoreQualifier = sleepScoreQualifier
        self.sleepValidation = sleepValidation
        self.currentBodyBattery = currentBodyBattery
        self.bodyBatteryAtWake = bodyBatteryAtWake
        self.currentStressLevel = currentStressLevel
        self.lastNightAvg = lastNightAvg
        self.lastNight5MinHigh = lastNight5MinHigh
        self.vo2Max = vo2Max
        self.fitnessAge = fitnessAge
        self.restingHR7DayAvg = restingHR7DayAvg
        self.hrvWeeklyAvg = hrvWeeklyAvg
    }
}
