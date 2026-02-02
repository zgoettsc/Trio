import Foundation

// MARK: - Nutrition Entry from Apple Health

/// A single nutrition data point read from Apple Health (e.g., one food item logged in Cronometer)
struct HealthNutritionEntry: JSON, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let carbs: Double
    let fat: Double
    let protein: Double
    let source: String

    init(id: UUID = UUID(), date: Date, carbs: Double = 0, fat: Double = 0, protein: Double = 0, source: String = "") {
        self.id = id
        self.date = date
        self.carbs = carbs
        self.fat = fat
        self.protein = protein
        self.source = source
    }

    var totalCalories: Double {
        (carbs * 4) + (fat * 9) + (protein * 4)
    }
}

// MARK: - Grouped Meal from Apple Health

/// Multiple nutrition entries grouped into a single meal by time proximity
struct HealthNutritionMeal: JSON, Identifiable, Equatable {
    let id: UUID
    let startTime: Date
    let endTime: Date
    let entries: [HealthNutritionEntry]
    let source: String

    init(id: UUID = UUID(), startTime: Date, endTime: Date, entries: [HealthNutritionEntry], source: String = "") {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.entries = entries
        self.source = source
    }

    var totalCarbs: Double {
        entries.reduce(0) { $0 + $1.carbs }
    }

    var totalFat: Double {
        entries.reduce(0) { $0 + $1.fat }
    }

    var totalProtein: Double {
        entries.reduce(0) { $0 + $1.protein }
    }

    var totalCalories: Double {
        entries.reduce(0) { $0 + $1.totalCalories }
    }

    /// Percentage of calories from carbs (0-100)
    var carbPercentage: Double {
        guard totalCalories > 0 else { return 0 }
        return (totalCarbs * 4 / totalCalories) * 100
    }

    /// Percentage of calories from fat (0-100)
    var fatPercentage: Double {
        guard totalCalories > 0 else { return 0 }
        return (totalFat * 9 / totalCalories) * 100
    }

    /// Percentage of calories from protein (0-100)
    var proteinPercentage: Double {
        guard totalCalories > 0 else { return 0 }
        return (totalProtein * 4 / totalCalories) * 100
    }

    /// Display-friendly time string using explicit local timezone
    var timeDescription: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = .current
        formatter.locale = .current
        return formatter.string(from: startTime)
    }

    /// How long ago this meal was
    var timeAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: startTime, relativeTo: Date())
    }
}
