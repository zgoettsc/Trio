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

// MARK: - Low Episode

/// A detected low blood glucose episode with recovery tracking
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
        duration: TimeInterval = 0
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

    /// Derive inferred meal events from snapshot deltas for a given day
    func inferredMealEvents(for date: Date) -> [InferredMealEvent] {
        let snapshots = snapshotsForDate(date).sorted { $0.timestamp < $1.timestamp }
        guard snapshots.count >= 2 else { return [] }

        var events: [InferredMealEvent] = []
        for i in 1 ..< snapshots.count {
            let prev = snapshots[i - 1]
            let curr = snapshots[i]
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
}
