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

// MARK: - Daily Nutrition Summary from Apple Health

/// All nutrition entries for a single day, aggregated
struct HealthNutritionDay: JSON, Identifiable, Equatable {
    let id: UUID
    let date: Date // The calendar day (midnight)
    let entries: [HealthNutritionEntry]
    let source: String

    init(id: UUID = UUID(), date: Date, entries: [HealthNutritionEntry], source: String = "") {
        self.id = id
        self.date = date
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

    var entryCount: Int {
        entries.count
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

    /// Display-friendly date string
    var dayDescription: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            formatter.timeZone = .current
            formatter.locale = .current
            return formatter.string(from: date)
        }
    }
}

// MARK: - Backward compatibility alias

/// Alias for backward compatibility -- meals are now grouped by day since Cronometer writes midnight timestamps
typealias HealthNutritionMeal = HealthNutritionDay
