import Foundation

// MARK: - Phase C: Garmin Context Snapshot
//
// A point-in-time snapshot of Garmin health data relevant to insulin sensitivity.
// Queried from Firestore at meal detection time.

struct GarminContextSnapshot: Codable {
    let queryTime: Date

    // === Sleep (last night) ===
    let sleepScore: Int?              // 0-100, Garmin's composite score
    let totalSleepMinutes: Int?
    let deepSleepMinutes: Int?
    let remSleepMinutes: Int?
    let awakeSleepMinutes: Int?
    let averageSpO2: Double?

    // === Stress & Recovery (current) ===
    let currentBodyBattery: Int?      // 0-100, queried at meal time
    let bodyBatteryAtWake: Int?       // morning level (recovery quality)
    let currentStress: Int?           // 0-100, current reading
    let averageStressToday: Int?

    // === Heart Rate / HRV ===
    let restingHR: Int?
    let restingHR7DayAvg: Int?        // for delta computation
    let hrvLastNight: Double?         // ms
    let hrvWeeklyAvg: Double?         // for delta computation
    let hrvStatus: String?            // "balanced" / "low" / "unbalanced"

    // === Activity (today) ===
    let stepsToday: Int?
    let activeCaloriesToday: Int?
    let intensityMinutesToday: Int?

    // === Activity (yesterday -- for delayed sensitivity effects) ===
    let stepsYesterday: Int?
    let activeCaloriesYesterday: Int?

    // === Training ===
    let trainingLoad: String?         // "low"/"optimal"/"high"/"very high"
    let trainingStatus: String?       // "productive"/"recovery"/"overreaching"/"detraining"
    let recoveryTimeHours: Int?

    // === Computed Deltas ===
    var restingHRDelta: Int? {
        guard let current = restingHR, let avg = restingHR7DayAvg else { return nil }
        return current - avg
    }

    var hrvDeltaPercent: Double? {
        guard let current = hrvLastNight, let avg = hrvWeeklyAvg, avg > 0 else { return nil }
        return ((current - avg) / avg) * 100
    }

    /// Create a snapshot with only the data that is available.
    /// All fields are optional — missing Garmin data = no adjustment.
    init(
        queryTime: Date = Date(),
        sleepScore: Int? = nil,
        totalSleepMinutes: Int? = nil,
        deepSleepMinutes: Int? = nil,
        remSleepMinutes: Int? = nil,
        awakeSleepMinutes: Int? = nil,
        averageSpO2: Double? = nil,
        currentBodyBattery: Int? = nil,
        bodyBatteryAtWake: Int? = nil,
        currentStress: Int? = nil,
        averageStressToday: Int? = nil,
        restingHR: Int? = nil,
        restingHR7DayAvg: Int? = nil,
        hrvLastNight: Double? = nil,
        hrvWeeklyAvg: Double? = nil,
        hrvStatus: String? = nil,
        stepsToday: Int? = nil,
        activeCaloriesToday: Int? = nil,
        intensityMinutesToday: Int? = nil,
        stepsYesterday: Int? = nil,
        activeCaloriesYesterday: Int? = nil,
        trainingLoad: String? = nil,
        trainingStatus: String? = nil,
        recoveryTimeHours: Int? = nil
    ) {
        self.queryTime = queryTime
        self.sleepScore = sleepScore
        self.totalSleepMinutes = totalSleepMinutes
        self.deepSleepMinutes = deepSleepMinutes
        self.remSleepMinutes = remSleepMinutes
        self.awakeSleepMinutes = awakeSleepMinutes
        self.averageSpO2 = averageSpO2
        self.currentBodyBattery = currentBodyBattery
        self.bodyBatteryAtWake = bodyBatteryAtWake
        self.currentStress = currentStress
        self.averageStressToday = averageStressToday
        self.restingHR = restingHR
        self.restingHR7DayAvg = restingHR7DayAvg
        self.hrvLastNight = hrvLastNight
        self.hrvWeeklyAvg = hrvWeeklyAvg
        self.hrvStatus = hrvStatus
        self.stepsToday = stepsToday
        self.activeCaloriesToday = activeCaloriesToday
        self.intensityMinutesToday = intensityMinutesToday
        self.stepsYesterday = stepsYesterday
        self.activeCaloriesYesterday = activeCaloriesYesterday
        self.trainingLoad = trainingLoad
        self.trainingStatus = trainingStatus
        self.recoveryTimeHours = recoveryTimeHours
    }
}
