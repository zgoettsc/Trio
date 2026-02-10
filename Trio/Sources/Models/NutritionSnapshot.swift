import Foundation

// MARK: - Nutrition Snapshot (for tracking Apple Health changes over time)

/// A point-in-time snapshot of today's cumulative nutrition totals from Apple Health.
/// By comparing consecutive snapshots, we can infer when food was logged.
struct NutritionSnapshot: JSON, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let cumulativeCarbs: Double
    let cumulativeFat: Double
    let cumulativeProtein: Double
    let cumulativeFiber: Double
    let forDate: Date // The calendar day these totals apply to

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        cumulativeCarbs: Double,
        cumulativeFat: Double,
        cumulativeProtein: Double,
        cumulativeFiber: Double = 0,
        forDate: Date
    ) {
        self.id = id
        self.timestamp = timestamp
        self.cumulativeCarbs = cumulativeCarbs
        self.cumulativeFat = cumulativeFat
        self.cumulativeProtein = cumulativeProtein
        self.cumulativeFiber = cumulativeFiber
        self.forDate = forDate
    }
}

// MARK: - Inferred Meal Event

/// A meal event inferred from the delta between two consecutive nutrition snapshots.
/// The timestamp is when the change was detected (approximate meal time).
struct InferredMealEvent: Identifiable, Equatable {
    let id: UUID
    let detectedAt: Date // When we noticed the change (approximate meal time)
    let carbsDelta: Double
    let fatDelta: Double
    let proteinDelta: Double
    let fiberDelta: Double

    init(
        id: UUID = UUID(),
        detectedAt: Date,
        carbsDelta: Double,
        fatDelta: Double,
        proteinDelta: Double,
        fiberDelta: Double = 0
    ) {
        self.id = id
        self.detectedAt = detectedAt
        self.carbsDelta = carbsDelta
        self.fatDelta = fatDelta
        self.proteinDelta = proteinDelta
        self.fiberDelta = fiberDelta
    }

    var totalCalories: Double {
        (carbsDelta * 4) + (fatDelta * 9) + (proteinDelta * 4)
    }

    /// Minutes since this meal was detected
    var minutesAgo: Double {
        Date().timeIntervalSince(detectedAt) / 60
    }

    /// Human-readable time-ago string
    var timeAgoString: String {
        let mins = Int(minutesAgo)
        if mins < 60 {
            return "\(mins) min ago"
        } else {
            let hours = mins / 60
            let remainingMins = mins % 60
            if remainingMins == 0 {
                return "\(hours)h ago"
            }
            return "\(hours)h \(remainingMins)m ago"
        }
    }
}

// MARK: - Carb Decay Model

/// Estimates how much of a meal's macros remain un-absorbed based on elapsed time.
/// Uses a hybrid approach: time-based exponential decay cross-checked against
/// actual BG rise (if available) to adapt to fast/slow absorbing meals.
enum CarbDecayModel {
    /// Exponential decay rate for carb absorption.
    /// Calibrated so ~50% absorbed at ~30 min, ~80% at ~60 min.
    private static let carbDecayRate: Double = 0.025

    /// FPU delay before fat/protein absorption starts (minutes)
    private static let fpuDelayMinutes: Double = 60

    /// Fraction of original carbs remaining after `minutes` since the meal.
    static func carbsRemainingFraction(minutesSinceMeal: Double) -> Double {
        guard minutesSinceMeal > 0 else { return 1.0 }
        return max(0, exp(-carbDecayRate * minutesSinceMeal))
    }

    /// Fraction of fat/protein remaining, accounting for the 60-min FPU delay.
    /// Fat/protein don't start absorbing until the delay elapses, then absorb
    /// over the FPU duration (3-8 hours depending on FPU count).
    static func fpuRemainingFraction(minutesSinceMeal: Double, fpuDurationHours: Double) -> Double {
        guard minutesSinceMeal > fpuDelayMinutes else { return 1.0 }
        let fpuDurationMinutes = fpuDurationHours * 60
        guard fpuDurationMinutes > 0 else { return 0 }
        let minutesIntoAbsorption = minutesSinceMeal - fpuDelayMinutes
        return max(0, 1.0 - (minutesIntoAbsorption / fpuDurationMinutes))
    }

    /// BG-informed estimate of carbs already absorbed.
    /// Uses the BG rise since meal time and the user's ISF/CR to back-calculate.
    static func bgInformedCarbsAbsorbed(
        bgRise: Double,
        isf: Double,
        carbRatio: Double
    ) -> Double? {
        guard isf > 0, carbRatio > 0, bgRise > 0 else { return nil }
        // bgRise = carbsAbsorbed / CR * ISF → carbsAbsorbed = bgRise * CR / ISF
        return bgRise * carbRatio / isf
    }

    /// Hybrid remaining carbs: takes the minimum of time-based and BG-informed estimates.
    /// More conservative = safer (won't over-dose).
    static func remainingCarbs(
        originalCarbs: Double,
        minutesSinceMeal: Double,
        bgRise: Double?,
        isf: Double,
        carbRatio: Double
    ) -> Double {
        let timeBased = originalCarbs * carbsRemainingFraction(minutesSinceMeal: minutesSinceMeal)

        if let rise = bgRise,
           let absorbed = bgInformedCarbsAbsorbed(bgRise: rise, isf: isf, carbRatio: carbRatio)
        {
            let bgBased = max(0, originalCarbs - absorbed)
            return min(timeBased, bgBased) // More conservative
        }

        return timeBased
    }

    /// Warning level for late dosing based on meal age
    static func warningLevel(minutesSinceMeal: Double) -> LateDoseWarning {
        if minutesSinceMeal <= 15 {
            return .none
        } else if minutesSinceMeal <= 60 {
            return .mild
        } else if minutesSinceMeal <= 180 {
            return .moderate
        } else {
            return .severe
        }
    }

    enum LateDoseWarning {
        case none      // Fresh meal, no warning
        case mild      // 15-60 min: "dosing slightly late"
        case moderate  // 1-3 hours: "significant absorption, reduced dose"
        case severe    // >3 hours: "most carbs absorbed, dosing may cause low"

        var message: String {
            switch self {
            case .none: return ""
            case .mild: return "Dosing slightly late. Carb recommendation reduced for absorption."
            case .moderate: return "Significant time has passed. Most fast carbs absorbed. Reduced dose recommended."
            case .severe: return "Most carbs likely absorbed. Late dosing may cause a low. Consider skipping."
            }
        }

        var color: String {
            switch self {
            case .none: return "green"
            case .mild: return "yellow"
            case .moderate: return "orange"
            case .severe: return "red"
            }
        }
    }
}

// MARK: - Low Episode Classification

/// The probable cause of a low BG episode, determined by context
enum LowEpisodeCause: String, Equatable {
    /// Workout ended 0-4 hours before the low (exercise increases insulin sensitivity)
    case exercise
    /// Non-SMB bolus delivered 1-4 hours before the low (too much insulin for food)
    case postBolus
    /// No recent bolus (>4h) and no recent exercise (>4h) — basal rate likely too high
    case fasting
    /// Both exercise and bolus contributed
    case mixed
    /// Insufficient data to classify
    case unknown

    var displayName: String {
        switch self {
        case .exercise: return "Exercise"
        case .postBolus: return "Post-Bolus"
        case .fasting: return "Fasting/Basal"
        case .mixed: return "Mixed"
        case .unknown: return "Unknown"
        }
    }

    var emoji: String {
        switch self {
        case .exercise: return "🏃"
        case .postBolus: return "💉"
        case .fasting: return "🌙"
        case .mixed: return "⚡"
        case .unknown: return "❓"
        }
    }
}

// MARK: - Low Episode

/// A detected low blood glucose episode with recovery tracking and cause classification
struct LowEpisode: Identifiable, Equatable {
    let id: UUID
    let startTime: Date // When BG first dropped below threshold
    let nadirTime: Date // Time of lowest BG
    let nadirBG: Int // Lowest BG during the episode
    let recoveryTime: Date? // When BG first returned above threshold
    let recoveryBG: Int? // BG at recovery time
    let peakAfterTime: Date? // Time of highest BG within 3h of nadir
    let peakAfterBG: Int? // Highest BG within 3h of nadir
    let bgAtStart: Int // BG when episode started
    let duration: TimeInterval // Time from start to recovery (or end of data)
    let cause: LowEpisodeCause // Classified cause of the low
    let relatedWorkout: String? // Workout type if exercise-related
    let recentBolusAmount: Double? // Bolus amount if post-bolus

    init(
        id: UUID = UUID(),
        startTime: Date,
        nadirTime: Date,
        nadirBG: Int,
        recoveryTime: Date? = nil,
        recoveryBG: Int? = nil,
        peakAfterTime: Date? = nil,
        peakAfterBG: Int? = nil,
        bgAtStart: Int,
        duration: TimeInterval = 0,
        cause: LowEpisodeCause = .unknown,
        relatedWorkout: String? = nil,
        recentBolusAmount: Double? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.nadirTime = nadirTime
        self.nadirBG = nadirBG
        self.recoveryTime = recoveryTime
        self.recoveryBG = recoveryBG
        self.peakAfterTime = peakAfterTime
        self.peakAfterBG = peakAfterBG
        self.bgAtStart = bgAtStart
        self.duration = duration
        self.cause = cause
        self.relatedWorkout = relatedWorkout
        self.recentBolusAmount = recentBolusAmount
    }

    /// Did the recovery peak overshoot target range?
    var overCorrected: Bool {
        guard let peak = peakAfterBG else { return false }
        return peak > 180
    }

    /// BG rise from nadir to peak (treatment response magnitude)
    var recoveryRise: Int? {
        guard let peak = peakAfterBG else { return nil }
        return peak - nadirBG
    }

    /// Duration in minutes
    var durationMinutes: Int {
        Int(duration / 60)
    }
}

// MARK: - Setting Recommendation

/// A guardrailed recommendation to adjust a Trio setting based on low episode analysis
struct SettingRecommendation: Identifiable, Equatable {
    let id: UUID
    let setting: RecommendedSetting
    let rationale: String
    let confidence: RecommendationConfidence
    let severity: RecommendationSeverity

    init(
        id: UUID = UUID(),
        setting: RecommendedSetting,
        rationale: String,
        confidence: RecommendationConfidence,
        severity: RecommendationSeverity
    ) {
        self.id = id
        self.setting = setting
        self.rationale = rationale
        self.confidence = confidence
        self.severity = severity
    }
}

enum RecommendedSetting: Equatable {
    /// Reduce basal rate during a time window (e.g., "reduce 10pm-2am by 10%")
    case reduceBasal(timeWindow: String, percentReduction: Double)
    /// Weaken ICR (increase the ratio number, meaning less insulin per gram)
    case weakenICR(percentChange: Double)
    /// Reduce pre-exercise basal or add pre-exercise carbs
    case exerciseAdjustment(suggestion: String)
    /// General recommendation (free text)
    case general(suggestion: String)

    var displayName: String {
        switch self {
        case .reduceBasal: return "Basal Rate"
        case .weakenICR: return "Carb Ratio"
        case .exerciseAdjustment: return "Exercise"
        case .general: return "General"
        }
    }

    var description: String {
        switch self {
        case let .reduceBasal(window, pct):
            return "Consider reducing basal rate \(window) by ~\(Int(pct))%"
        case let .weakenICR(pct):
            return "Consider weakening ICR by ~\(Int(pct))% (more carbs per unit)"
        case let .exerciseAdjustment(suggestion):
            return suggestion
        case let .general(suggestion):
            return suggestion
        }
    }

    /// Whether this recommendation can be directly applied to settings
    var isActionable: Bool {
        switch self {
        case .reduceBasal, .weakenICR: return true
        case .exerciseAdjustment, .general: return false
        }
    }
}

enum RecommendationConfidence: String, Equatable {
    case low
    case medium
    case high

    var displayName: String { rawValue.capitalized }
}

enum RecommendationSeverity: String, Equatable {
    case informational
    case suggested
    case recommended

    var displayName: String { rawValue.capitalized }
}

// MARK: - Low Treatment Analysis Summary

/// Aggregate statistics about low episode treatment patterns
struct LowTreatmentSummary: Equatable {
    let totalEpisodes: Int
    let episodesPerDay: Double
    let averageNadir: Int
    let averageDurationMinutes: Int
    let averageRecoveryRise: Int?
    let overCorrectionCount: Int
    let overCorrectionRate: Double // 0-1
    let averagePeakAfterLow: Int?
    let estimatedDailyTreatmentCarbs: Double // Based on episode count * estimated carbs per episode

    // Cause breakdown
    let exerciseCount: Int
    let postBolusCount: Int
    let fastingCount: Int
    let mixedCount: Int
    let unknownCount: Int

    // Setting recommendations
    let recommendations: [SettingRecommendation]

    var exerciseRate: Double { totalEpisodes > 0 ? Double(exerciseCount) / Double(totalEpisodes) : 0 }
    var postBolusRate: Double { totalEpisodes > 0 ? Double(postBolusCount) / Double(totalEpisodes) : 0 }
    var fastingRate: Double { totalEpisodes > 0 ? Double(fastingCount) / Double(totalEpisodes) : 0 }
    var mixedRate: Double { totalEpisodes > 0 ? Double(mixedCount) / Double(totalEpisodes) : 0 }

    /// The dominant cause of lows
    var dominantCause: LowEpisodeCause {
        let counts = [
            (LowEpisodeCause.exercise, exerciseCount),
            (.postBolus, postBolusCount),
            (.fasting, fastingCount),
            (.mixed, mixedCount)
        ]
        return counts.max(by: { $0.1 < $1.1 })?.0 ?? .unknown
    }

    /// Human-readable correction pattern description
    var correctionPattern: String {
        if overCorrectionRate > 0.5 {
            return "Over-correction pattern: \(Int(overCorrectionRate * 100))% of lows spike above 180 mg/dL after treatment"
        } else if overCorrectionRate > 0.25 {
            return "Mixed pattern: \(Int(overCorrectionRate * 100))% of lows result in over-correction above 180 mg/dL"
        } else {
            return "Good correction pattern: only \(Int(overCorrectionRate * 100))% of lows result in over-correction"
        }
    }

    /// Human-readable cause breakdown
    var causeBreakdown: String {
        var parts: [String] = []
        if exerciseCount > 0 { parts.append("\(exerciseCount) exercise-related") }
        if postBolusCount > 0 { parts.append("\(postBolusCount) post-bolus") }
        if fastingCount > 0 { parts.append("\(fastingCount) fasting/basal") }
        if mixedCount > 0 { parts.append("\(mixedCount) mixed") }
        if unknownCount > 0 { parts.append("\(unknownCount) unclassified") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Snapshot Storage

/// Manages persistence of nutrition snapshots for change detection
final class NutritionSnapshotStore {
    static let shared = NutritionSnapshotStore()

    private let fileManager = FileManager.default
    private let maxSnapshotAge: TimeInterval = 14 * 24 * 3600 // 14 days

    private var snapshotsURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("nutrition_snapshots.json")
    }

    private var doseTimestampsURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("v2_dose_timestamps.json")
    }

    private init() {}

    func loadSnapshots() -> [NutritionSnapshot] {
        guard let data = try? Data(contentsOf: snapshotsURL),
              let snapshots = try? JSONDecoder().decode([NutritionSnapshot].self, from: data)
        else {
            return []
        }
        // Prune old snapshots
        let cutoff = Date().addingTimeInterval(-maxSnapshotAge)
        return snapshots.filter { $0.timestamp > cutoff }
    }

    func saveSnapshot(_ snapshot: NutritionSnapshot) {
        var snapshots = loadSnapshots()
        snapshots.append(snapshot)
        // Prune old
        let cutoff = Date().addingTimeInterval(-maxSnapshotAge)
        snapshots = snapshots.filter { $0.timestamp > cutoff }

        if let data = try? JSONEncoder().encode(snapshots) {
            try? data.write(to: snapshotsURL, options: .atomic)
        }
    }

    // MARK: - Dose Timestamps
    // When a V2 dose is applied, we record the timestamp. This "closes" the current
    // meal group so any new deltas — even within 15 minutes — become a separate meal.
    // Example: dinner logged and dosed, then dessert logged 13 minutes later → two meals.

    /// Record that a V2 dose was applied at this moment.
    func recordDoseTimestamp() {
        var timestamps = loadDoseTimestamps()
        timestamps.append(Date())
        // Prune old (keep last 14 days)
        let cutoff = Date().addingTimeInterval(-maxSnapshotAge)
        timestamps = timestamps.filter { $0 > cutoff }
        if let data = try? JSONEncoder().encode(timestamps) {
            try? data.write(to: doseTimestampsURL, options: .atomic)
        }
    }

    /// Load all dose timestamps.
    func loadDoseTimestamps() -> [Date] {
        guard let data = try? Data(contentsOf: doseTimestampsURL),
              let timestamps = try? JSONDecoder().decode([Date].self, from: data)
        else {
            return []
        }
        let cutoff = Date().addingTimeInterval(-maxSnapshotAge)
        return timestamps.filter { $0 > cutoff }
    }

    func snapshotsForDate(_ date: Date) -> [NutritionSnapshot] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        return loadSnapshots().filter { $0.forDate >= dayStart && $0.forDate < dayEnd }
    }

    /// Derive inferred meal events from snapshot deltas for a given day.
    /// Cronometer writes cumulative daily totals to Apple Health. Each snapshot captures
    /// the running total at the time the observer fired. Meals are inferred from deltas
    /// between consecutive snapshots.
    ///
    /// Individual food items entered within 15 minutes of each other are merged into
    /// a single meal event. For example, entering bread, almond butter, blueberries,
    /// and honey over 5 minutes produces one meal event with the combined macros.
    func inferredMealEvents(for date: Date) -> [InferredMealEvent] {
        let snapshots = snapshotsForDate(date).sorted { $0.timestamp < $1.timestamp }
        guard !snapshots.isEmpty else { return [] }

        // Bootstrap: if only one snapshot exists (no background observer fired before the meal),
        // use a midnight baseline of zeros — same approach as recordAndComputeLatestMeal().
        // This returns the entire day's cumulative intake as a single meal event.
        if snapshots.count == 1 {
            let snap = snapshots[0]
            let carbDelta = snap.cumulativeCarbs
            let fatDelta = snap.cumulativeFat
            let proteinDelta = snap.cumulativeProtein
            let fiberDelta = snap.cumulativeFiber
            guard carbDelta > 1 || fatDelta > 1 || proteinDelta > 1 else { return [] }
            return [InferredMealEvent(
                detectedAt: snap.timestamp,
                carbsDelta: max(0, carbDelta),
                fatDelta: max(0, fatDelta),
                proteinDelta: max(0, proteinDelta),
                fiberDelta: max(0, fiberDelta)
            )]
        }

        // First pass: compute raw deltas between consecutive snapshots.
        // Start with a midnight baseline for the first snapshot, so food logged before
        // the first observer fire isn't lost. This mirrors recordAndComputeLatestMeal().
        var rawEvents: [(detectedAt: Date, carbsDelta: Double, fatDelta: Double, proteinDelta: Double, fiberDelta: Double)] = []

        // Check first snapshot against midnight baseline
        let first = snapshots[0]
        if first.cumulativeCarbs > 1 || first.cumulativeFat > 1 || first.cumulativeProtein > 1 {
            rawEvents.append((
                detectedAt: first.timestamp,
                carbsDelta: max(0, first.cumulativeCarbs),
                fatDelta: max(0, first.cumulativeFat),
                proteinDelta: max(0, first.cumulativeProtein),
                fiberDelta: max(0, first.cumulativeFiber)
            ))
        }

        for i in 1 ..< snapshots.count {
            let prev = snapshots[i - 1]
            let curr = snapshots[i]
            let carbDelta = curr.cumulativeCarbs - prev.cumulativeCarbs
            let fatDelta = curr.cumulativeFat - prev.cumulativeFat
            let proteinDelta = curr.cumulativeProtein - prev.cumulativeProtein
            let fiberDelta = curr.cumulativeFiber - prev.cumulativeFiber

            // Only include meaningful changes (> 1g of any macro)
            if carbDelta > 1 || fatDelta > 1 || proteinDelta > 1 {
                rawEvents.append((
                    detectedAt: curr.timestamp,
                    carbsDelta: max(0, carbDelta),
                    fatDelta: max(0, fatDelta),
                    proteinDelta: max(0, proteinDelta),
                    fiberDelta: max(0, fiberDelta)
                ))
            }
        }

        guard !rawEvents.isEmpty else { return [] }

        // Load dose timestamps to detect group boundaries.
        // A dose "closes" the current meal: any subsequent delta — even within 15 minutes —
        // becomes a new meal. Example: dinner dosed, then dessert logged 13 min later → two meals.
        let doseTimestamps = loadDoseTimestamps().sorted()

        // Second pass: merge events within 15 minutes of each other into single meals,
        // UNLESS a dose occurred between consecutive events (which closes the group).
        var meals: [InferredMealEvent] = []
        var currentCarbs = rawEvents[0].carbsDelta
        var currentFat = rawEvents[0].fatDelta
        var currentProtein = rawEvents[0].proteinDelta
        var currentFiber = rawEvents[0].fiberDelta
        var currentTime = rawEvents[0].detectedAt

        for i in 1 ..< rawEvents.count {
            let prevTime = rawEvents[i - 1].detectedAt
            let thisTime = rawEvents[i].detectedAt
            let gap = thisTime.timeIntervalSince(prevTime)

            // Check if a dose was applied between these two events
            let doseBetween = doseTimestamps.contains { $0 > prevTime && $0 <= thisTime }

            if gap <= Self.mealGroupingWindow, !doseBetween {
                // Same meal — accumulate macros
                currentCarbs += rawEvents[i].carbsDelta
                currentFat += rawEvents[i].fatDelta
                currentProtein += rawEvents[i].proteinDelta
                currentFiber += rawEvents[i].fiberDelta
                currentTime = rawEvents[i].detectedAt
            } else {
                // New meal — either time gap exceeded OR a dose was applied between events
                meals.append(InferredMealEvent(
                    detectedAt: currentTime,
                    carbsDelta: currentCarbs,
                    fatDelta: currentFat,
                    proteinDelta: currentProtein,
                    fiberDelta: currentFiber
                ))
                currentCarbs = rawEvents[i].carbsDelta
                currentFat = rawEvents[i].fatDelta
                currentProtein = rawEvents[i].proteinDelta
                currentFiber = rawEvents[i].fiberDelta
                currentTime = rawEvents[i].detectedAt
            }
        }

        // Don't forget the last accumulated meal
        meals.append(InferredMealEvent(
            detectedAt: currentTime,
            carbsDelta: currentCarbs,
            fatDelta: currentFat,
            proteinDelta: currentProtein,
            fiberDelta: currentFiber
        ))

        return meals
    }

    /// How close two snapshots must be (in seconds) to be considered part of the same meal.
    /// Food items entered in Cronometer within this window are grouped together.
    private static let mealGroupingWindow: TimeInterval = 15 * 60 // 15 minutes

    /// Compute the meal delta between current HealthKit totals and the pre-meal baseline.
    /// Used when the Crono button is tapped: we query HealthKit for current totals and diff
    /// against the baseline snapshot from BEFORE the current meal started.
    ///
    /// Cronometer fires a HealthKit update per food item, so entering bread, almond butter,
    /// blueberries, and honey creates 4 separate snapshots. We group all snapshots within
    /// 15 minutes of each other as a single meal and diff against the snapshot before that cluster.
    func recordAndComputeLatestMeal(
        currentCarbs: Double,
        currentFat: Double,
        currentProtein: Double,
        currentFiber: Double = 0
    ) -> InferredMealEvent? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Save the fresh snapshot
        let freshSnapshot = NutritionSnapshot(
            timestamp: Date(),
            cumulativeCarbs: currentCarbs,
            cumulativeFat: currentFat,
            cumulativeProtein: currentProtein,
            cumulativeFiber: currentFiber,
            forDate: today
        )
        saveSnapshot(freshSnapshot)

        // Get all today's snapshots INCLUDING the fresh one, sorted ascending by time
        var allSnapshots = snapshotsForDate(today).sorted { $0.timestamp < $1.timestamp }

        // Deduplicate: if the fresh snapshot has the same cumulative values as the last one,
        // it's already represented. Keep it anyway since it has the latest timestamp.
        guard !allSnapshots.isEmpty else {
            // Should not happen since we just saved one, but handle gracefully
            return nil
        }

        // Walk backwards from the end, grouping snapshots within 15 minutes of each other.
        // The "meal cluster" is all consecutive snapshots where each pair is within 15 min.
        // The baseline is the snapshot just BEFORE this cluster.
        var mealStartIndex = allSnapshots.count - 1
        while mealStartIndex > 0 {
            let gap = allSnapshots[mealStartIndex].timestamp.timeIntervalSince(
                allSnapshots[mealStartIndex - 1].timestamp
            )
            if gap <= Self.mealGroupingWindow {
                mealStartIndex -= 1
            } else {
                break
            }
        }

        // The baseline is the snapshot just before the meal cluster
        let prev: NutritionSnapshot
        if mealStartIndex > 0 {
            prev = allSnapshots[mealStartIndex - 1]
        } else {
            // All snapshots are in one cluster (or only one exists) — use midnight baseline
            prev = NutritionSnapshot(
                timestamp: today,
                cumulativeCarbs: 0,
                cumulativeFat: 0,
                cumulativeProtein: 0,
                cumulativeFiber: 0,
                forDate: today
            )
        }

        let carbDelta = currentCarbs - prev.cumulativeCarbs
        let fatDelta = currentFat - prev.cumulativeFat
        let proteinDelta = currentProtein - prev.cumulativeProtein
        let fiberDelta = currentFiber - prev.cumulativeFiber

        // Only return a meal if there's a meaningful change
        guard carbDelta > 1 || fatDelta > 1 || proteinDelta > 1 else { return nil }

        return InferredMealEvent(
            detectedAt: Date(),
            carbsDelta: max(0, carbDelta),
            fatDelta: max(0, fatDelta),
            proteinDelta: max(0, proteinDelta),
            fiberDelta: max(0, fiberDelta)
        )
    }

    /// Derive inferred meal events from snapshot deltas for the last N hours.
    /// Covers today and yesterday (if the time window extends past midnight).
    func inferredMealEvents(forLastHours hours: Int) -> [InferredMealEvent] {
        let cutoff = Date().addingTimeInterval(-TimeInterval(hours * 3600))
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Always get today's events
        var allEvents = inferredMealEvents(for: today)

        // If the window extends into yesterday, include yesterday's events too
        if cutoff < today, let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            allEvents += inferredMealEvents(for: yesterday)
        }

        // Filter to only events within the time window
        return allEvents
            .filter { $0.detectedAt >= cutoff }
            .sorted { $0.detectedAt < $1.detectedAt }
    }
}
