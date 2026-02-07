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
    let forDate: Date // The calendar day these totals apply to

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        cumulativeCarbs: Double,
        cumulativeFat: Double,
        cumulativeProtein: Double,
        forDate: Date
    ) {
        self.id = id
        self.timestamp = timestamp
        self.cumulativeCarbs = cumulativeCarbs
        self.cumulativeFat = cumulativeFat
        self.cumulativeProtein = cumulativeProtein
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

    init(
        id: UUID = UUID(),
        detectedAt: Date,
        carbsDelta: Double,
        fatDelta: Double,
        proteinDelta: Double
    ) {
        self.id = id
        self.detectedAt = detectedAt
        self.carbsDelta = carbsDelta
        self.fatDelta = fatDelta
        self.proteinDelta = proteinDelta
    }

    var totalCalories: Double {
        (carbsDelta * 4) + (fatDelta * 9) + (proteinDelta * 4)
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
    /// Special case: if only 1 snapshot exists for a day, the baseline is implicitly
    /// midnight with 0g across all macros (since Cronometer's daily totals start at zero).
    /// This means the first snapshot's cumulative values ARE the food logged so far.
    func inferredMealEvents(for date: Date) -> [InferredMealEvent] {
        let snapshots = snapshotsForDate(date).sorted { $0.timestamp < $1.timestamp }
        guard !snapshots.isEmpty else { return [] }

        var events: [InferredMealEvent] = []

        // Create a synthetic midnight baseline — Cronometer daily totals start at 0
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: date)
        let baseline = NutritionSnapshot(
            timestamp: midnight,
            cumulativeCarbs: 0,
            cumulativeFat: 0,
            cumulativeProtein: 0,
            forDate: midnight
        )

        // Prepend baseline so we can always diff against it
        let allSnapshots = [baseline] + snapshots

        for i in 1 ..< allSnapshots.count {
            let prev = allSnapshots[i - 1]
            let curr = allSnapshots[i]
            let carbDelta = curr.cumulativeCarbs - prev.cumulativeCarbs
            let fatDelta = curr.cumulativeFat - prev.cumulativeFat
            let proteinDelta = curr.cumulativeProtein - prev.cumulativeProtein

            // Only create an event if there's a meaningful change (> 1g of any macro)
            if carbDelta > 1 || fatDelta > 1 || proteinDelta > 1 {
                events.append(InferredMealEvent(
                    detectedAt: curr.timestamp,
                    carbsDelta: max(0, carbDelta),
                    fatDelta: max(0, fatDelta),
                    proteinDelta: max(0, proteinDelta)
                ))
            }
        }
        return events
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
