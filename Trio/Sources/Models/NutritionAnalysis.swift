import Foundation

// MARK: - Matched Day (Trio daily carbs paired with Cronometer daily totals)

/// A single day where we have both Trio's manual carb entries and Cronometer's actual nutrition data
struct MatchedMealAnalysis: Identifiable, Equatable {
    let id: UUID
    let date: Date

    // Trio manual entries (daily totals)
    let trioCarbs: Double
    let trioFat: Double
    let trioProtein: Double

    // Cronometer (Apple Health) daily totals
    let actualCarbs: Double
    let actualFat: Double
    let actualProtein: Double
    let nutritionSource: String

    // Total meal bolus insulin for the day (non-SMB)
    let bolusInsulin: Double

    // Daily BG summary
    let bgAtMeal: Int? // Daily average BG
    let bgPeak: Int? // Daily max BG

    // Low treatment analysis
    let lowEpisodes: [LowEpisode]
    let estimatedTreatmentCarbs: Double // Estimated carbs consumed to treat lows

    init(
        id: UUID = UUID(),
        date: Date,
        trioCarbs: Double,
        trioFat: Double = 0,
        trioProtein: Double = 0,
        actualCarbs: Double,
        actualFat: Double = 0,
        actualProtein: Double = 0,
        nutritionSource: String = "",
        bolusInsulin: Double = 0,
        bgAtMeal: Int? = nil,
        bgPeak: Int? = nil,
        lowEpisodes: [LowEpisode] = [],
        estimatedTreatmentCarbs: Double = 0
    ) {
        self.id = id
        self.date = date
        self.trioCarbs = trioCarbs
        self.trioFat = trioFat
        self.trioProtein = trioProtein
        self.actualCarbs = actualCarbs
        self.actualFat = actualFat
        self.actualProtein = actualProtein
        self.nutritionSource = nutritionSource
        self.bolusInsulin = bolusInsulin
        self.bgAtMeal = bgAtMeal
        self.bgPeak = bgPeak
        self.lowEpisodes = lowEpisodes
        self.estimatedTreatmentCarbs = estimatedTreatmentCarbs
    }

    /// Ratio of entered carbs to actual carbs (e.g., 0.41 = entered 41% of actual)
    var estimationRatio: Double {
        guard actualCarbs > 0 else { return 0 }
        return trioCarbs / actualCarbs
    }

    /// Carbs that were unaccounted for
    var missedCarbs: Double {
        max(0, actualCarbs - trioCarbs)
    }

    /// Cronometer carbs minus estimated low treatment carbs = meal-only carbs
    var adjustedActualCarbs: Double {
        max(0, actualCarbs - estimatedTreatmentCarbs)
    }

    /// Adjusted ratio: Trio entered carbs vs meal-only actual carbs (excluding low treatments)
    var adjustedEstimationRatio: Double {
        guard adjustedActualCarbs > 0 else { return 0 }
        return trioCarbs / adjustedActualCarbs
    }

    /// Adjusted missed carbs (excluding low treatment carbs from the gap)
    var adjustedMissedCarbs: Double {
        max(0, adjustedActualCarbs - trioCarbs)
    }

    /// Actual ICR based on actual carbs and insulin given
    var effectiveICR: Double? {
        guard bolusInsulin > 0, actualCarbs > 0 else { return nil }
        return actualCarbs / bolusInsulin
    }

    /// Apparent ICR based on Trio's entered carbs (what your settings are tuned to)
    var apparentICR: Double? {
        guard bolusInsulin > 0, trioCarbs > 0 else { return nil }
        return trioCarbs / bolusInsulin
    }

    /// Daily average BG
    var averageBG: Int? {
        bgAtMeal
    }

    /// Daily max BG
    var maxBG: Int? {
        bgPeak
    }

    /// Actual macro percentages from Cronometer
    var actualCarbPercent: Double {
        let totalCal = (actualCarbs * 4) + (actualFat * 9) + (actualProtein * 4)
        guard totalCal > 0 else { return 0 }
        return (actualCarbs * 4 / totalCal) * 100
    }

    var actualFatPercent: Double {
        let totalCal = (actualCarbs * 4) + (actualFat * 9) + (actualProtein * 4)
        guard totalCal > 0 else { return 0 }
        return (actualFat * 9 / totalCal) * 100
    }

    var actualProteinPercent: Double {
        let totalCal = (actualCarbs * 4) + (actualFat * 9) + (actualProtein * 4)
        guard totalCal > 0 else { return 0 }
        return (actualProtein * 4 / totalCal) * 100
    }

    /// Display-friendly day label
    var dayDescription: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, MMM d"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Aggregate Analysis

/// Summary statistics across all matched days
struct NutritionAnalysisSummary: Equatable {
    let totalMatchedDays: Int
    let unmatchedTrioDays: Int
    let unmatchedHealthDays: Int
    let analysisPeriodDays: Int

    // Estimation accuracy
    let averageEstimationRatio: Double
    let medianEstimationRatio: Double
    let minEstimationRatio: Double
    let maxEstimationRatio: Double

    // Carb counting
    let averageMissedCarbs: Double
    let totalMissedCarbs: Double
    let averageTrioCarbs: Double
    let averageActualCarbs: Double

    // ICR analysis
    let averageApparentICR: Double?
    let averageEffectiveICR: Double?
    let suggestedICRAdjustment: Double?

    // Daily BG summary
    let averageDailyBG: Int?
    let averageDailyMaxBG: Int?

    // Low treatment analysis
    let lowTreatmentSummary: LowTreatmentSummary?

    // Adjusted estimation (excluding low treatment carbs)
    let adjustedAverageEstimationRatio: Double?
    let adjustedAverageActualCarbs: Double?

    /// Human-readable estimation description
    var estimationDescription: String {
        let pct = Int(averageEstimationRatio * 100)
        return "You typically enter \(pct)% of actual carbs"
    }

    /// Adjusted description accounting for low treatment carbs
    var adjustedEstimationDescription: String? {
        guard let adjRatio = adjustedAverageEstimationRatio, adjRatio != averageEstimationRatio else { return nil }
        let pct = Int(adjRatio * 100)
        return "Excluding low treatments: you enter \(pct)% of meal carbs"
    }

    /// If we know the apparent ICR and the ratio, what should the real ICR be?
    var suggestedICRDescription: String? {
        guard let apparent = averageApparentICR, let effective = averageEffectiveICR else { return nil }
        return "Current ICR tuned to estimates: 1:\(String(format: "%.1f", apparent))g. True ICR against actual carbs: 1:\(String(format: "%.1f", effective))g"
    }
}
