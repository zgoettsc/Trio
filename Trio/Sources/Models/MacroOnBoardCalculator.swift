import Foundation

/// Computes Carbs/Protein/Fat "on board" from V2 curve-distributed entries.
///
/// V2 entries are stored as CarbEntryStored with isFPU=true and tagged notes:
///   - "carb-absorption" — real carb entries distributed along the gamma curve
///   - "protein-gluconeogenesis" — protein glucose-equivalent entries (sigmoid curve)
///   - "fat-resistance" — fat insulin-resistance equivalent entries (gaussian curve)
///
/// "On board" means entries whose scheduled date is still in the future (not yet absorbed).
/// The initial upfront carbs (bolused immediately) are NOT stored as entries, so they
/// don't appear here — only the extended/future portions do.
enum MacroOnBoardCalculator {
    struct MacroBreakdown {
        /// Remaining carb-absorption entries (grams, curve-distributed)
        let carbsOnBoard: Double
        /// Remaining protein-gluconeogenesis entries (gram carb-equivalent)
        let proteinOnBoard: Double
        /// Remaining fat-resistance entries (gram carb-equivalent)
        let fatOnBoard: Double
        /// Sum of all three = total effective COB from V2 entries
        var totalEffective: Double { carbsOnBoard + proteinOnBoard + fatOnBoard }
        /// Whether any V2 entries exist (i.e., V2 engine was used)
        var hasV2Entries: Bool { carbsOnBoard > 0 || proteinOnBoard > 0 || fatOnBoard > 0 }
    }

    /// Data point for the macro decay chart: remaining grams at a given time.
    struct DecayPoint: Identifiable {
        let id = UUID()
        let date: Date
        let carbs: Double
        let protein: Double
        let fat: Double
    }

    /// Compute current macro breakdown from FPU entries.
    /// - Parameter fpuEntries: All isFPU=true entries (from fpusFromPersistence or a Core Data fetch)
    /// - Returns: Breakdown of remaining carbs/protein/fat on board
    static func currentBreakdown(from fpuEntries: [CarbEntryStored]) -> MacroBreakdown {
        let now = Date()
        var carbs = 0.0
        var protein = 0.0
        var fat = 0.0

        for entry in fpuEntries {
            guard let date = entry.date, date > now else { continue }
            let grams = entry.carbs

            switch entry.note {
            case "carb-absorption":
                carbs += grams
            case "protein-gluconeogenesis":
                protein += grams
            case "fat-resistance":
                fat += grams
            default:
                // Legacy FPU entries (V1) or untagged — count as carbs
                carbs += grams
            }
        }

        return MacroBreakdown(carbsOnBoard: carbs, proteinOnBoard: protein, fatOnBoard: fat)
    }

    /// Generate decay timeline data points for charting.
    /// Shows how each macro component decays over time from now until all entries are absorbed.
    /// - Parameters:
    ///   - fpuEntries: All isFPU=true entries
    ///   - intervalMinutes: Sampling interval (default 10 min, matching V2 entry spacing)
    /// - Returns: Array of DecayPoints from now until all entries are consumed
    static func decayTimeline(
        from fpuEntries: [CarbEntryStored],
        intervalMinutes: Int = 10
    ) -> [DecayPoint] {
        let now = Date()

        // Find the latest entry date to know when to stop
        let futureEntries = fpuEntries.filter { ($0.date ?? .distantPast) > now }
        guard let lastDate = futureEntries.compactMap(\.date).max() else {
            return [DecayPoint(date: now, carbs: 0, protein: 0, fat: 0)]
        }

        var points: [DecayPoint] = []
        var currentTime = now
        let interval = TimeInterval(intervalMinutes * 60)

        while currentTime <= lastDate {
            var carbs = 0.0
            var protein = 0.0
            var fat = 0.0

            for entry in fpuEntries {
                guard let date = entry.date, date > currentTime else { continue }
                let grams = entry.carbs

                switch entry.note {
                case "carb-absorption":
                    carbs += grams
                case "protein-gluconeogenesis":
                    protein += grams
                case "fat-resistance":
                    fat += grams
                default:
                    carbs += grams
                }
            }

            points.append(DecayPoint(date: currentTime, carbs: carbs, protein: protein, fat: fat))
            currentTime = currentTime.addingTimeInterval(interval)
        }

        // Add final zero point
        points.append(DecayPoint(date: lastDate, carbs: 0, protein: 0, fat: 0))

        return points
    }
}
