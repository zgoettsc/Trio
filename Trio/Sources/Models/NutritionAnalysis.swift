import Foundation

// MARK: - Matched Meal (Trio entry paired with Cronometer data)

/// A single meal where we have both Trio's manual carb entry and Cronometer's actual nutrition data
struct MatchedMealAnalysis: Identifiable, Equatable {
    let id: UUID
    let date: Date

    // Trio manual entry
    let trioCarbs: Double
    let trioFat: Double
    let trioProtein: Double

    // Cronometer (Apple Health) data
    let actualCarbs: Double
    let actualFat: Double
    let actualProtein: Double
    let nutritionSource: String

    // Insulin delivered around this meal (within ±15 min)
    let bolusInsulin: Double

    // BG response
    let bgAtMeal: Int?
    let bgAt1h: Int?
    let bgAt2h: Int?
    let bgAt3h: Int?
    let bgPeak: Int?
    let bgPeakTime: Date?

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
        bgAt1h: Int? = nil,
        bgAt2h: Int? = nil,
        bgAt3h: Int? = nil,
        bgPeak: Int? = nil,
        bgPeakTime: Date? = nil
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
        self.bgAt1h = bgAt1h
        self.bgAt2h = bgAt2h
        self.bgAt3h = bgAt3h
        self.bgPeak = bgPeak
        self.bgPeakTime = bgPeakTime
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

    /// BG rise from meal time to peak
    var bgRise: Int? {
        guard let meal = bgAtMeal, let peak = bgPeak else { return nil }
        return peak - meal
    }

    /// BG change from meal to 2 hours
    var bgChange2h: Int? {
        guard let meal = bgAtMeal, let bg2h = bgAt2h else { return nil }
        return bg2h - meal
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
}

// MARK: - Aggregate Analysis

/// Summary statistics across all matched meals
struct NutritionAnalysisSummary: Equatable {
    let totalMatchedMeals: Int
    let unmatchedTrioEntries: Int
    let unmatchedHealthEntries: Int
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

    // BG outcomes
    let averageBgRise: Int?
    let averageBgChange2h: Int?

    /// Human-readable estimation description
    var estimationDescription: String {
        let pct = Int(averageEstimationRatio * 100)
        return "You typically enter \(pct)% of actual carbs"
    }

    /// If we know the apparent ICR and the ratio, what should the real ICR be?
    var suggestedICRDescription: String? {
        guard let apparent = averageApparentICR, let effective = averageEffectiveICR else { return nil }
        return "Current ICR tuned to estimates: 1:\(String(format: "%.1f", apparent))g. True ICR against actual carbs: 1:\(String(format: "%.1f", effective))g"
    }
}
