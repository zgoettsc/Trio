import Foundation

// MARK: - Phase D: Garmin Sensitivity Model
//
// Rule-based model that computes insulin sensitivity from Garmin health data.
// Outputs an insulinDemandFactor: multiply entries by this value.
//   1.0  = normal day
//   1.25 = 25% more insulin needed (bad sleep, high stress)
//   0.83 = 17% less insulin needed (good recovery, active yesterday)

struct GarminSensitivityModel {

    /// Result of the sensitivity calculation, with breakdown for UI display.
    struct SensitivityResult {
        let sensitivityFactor: Double       // 0.60-1.40 (internal)
        let insulinDemandFactor: Double     // 0.71-1.67 (used in code)
        let contributions: [Contribution]   // breakdown of what affected the result

        struct Contribution {
            let metric: String      // e.g., "Sleep Score"
            let value: String       // e.g., "42/100"
            let impact: Double      // e.g., -0.22 (negative = more resistant)
            let description: String // e.g., "Terrible sleep: 22% more resistant"
        }
    }

    /// Compute insulin demand factor from Garmin context.
    /// Returns a SensitivityResult with the factor and a breakdown of contributions.
    ///
    /// If the context is nil (Garmin unavailable), returns demand factor 1.0 (no adjustment).
    static func computeDemandFactor(from ctx: GarminContextSnapshot?) -> SensitivityResult {
        guard let ctx = ctx else {
            return SensitivityResult(
                sensitivityFactor: 1.0,
                insulinDemandFactor: 1.0,
                contributions: [SensitivityResult.Contribution(
                    metric: "Garmin Data",
                    value: "Unavailable",
                    impact: 0,
                    description: "No Garmin data — using baseline"
                )]
            )
        }

        var factor = 1.0
        var contributions: [SensitivityResult.Contribution] = []

        // --- Sleep ---
        // Poor sleep is the strongest single predictor of next-day resistance.
        // Spiegel (1999): 4h sleep x 6 nights -> 40% reduced glucose clearance.
        if let sleep = ctx.sleepScore {
            let impact: Double
            let desc: String
            switch sleep {
            case ..<40:
                impact = -0.22
                desc = "Terrible sleep: 22% more resistant"
            case ..<55:
                impact = -0.15
                desc = "Poor sleep: 15% more resistant"
            case ..<70:
                impact = -0.08
                desc = "Fair sleep: 8% more resistant"
            case 85...:
                impact = 0.05
                desc = "Great sleep: 5% more sensitive"
            default:
                impact = 0
                desc = "Normal sleep range"
            }
            factor += impact
            contributions.append(.init(metric: "Sleep Score", value: "\(sleep)/100", impact: impact, description: desc))
        }

        // Duration matters independently of score
        if let duration = ctx.totalSleepMinutes {
            let impact: Double
            let desc: String
            if duration < 300 {
                impact = -0.10
                desc = "Less than 5h sleep: 10% more resistant"
            } else if duration < 360 {
                impact = -0.05
                desc = "Less than 6h sleep: 5% more resistant"
            } else {
                impact = 0
                desc = "Adequate sleep duration"
            }
            if impact != 0 {
                factor += impact
                let hours = duration / 60
                let mins = duration % 60
                contributions.append(.init(
                    metric: "Sleep Duration",
                    value: "\(hours)h \(mins)m",
                    impact: impact,
                    description: desc
                ))
            }
        }

        // --- Stress & Recovery ---
        if let bb = ctx.currentBodyBattery {
            let impact: Double
            let desc: String
            switch bb {
            case ..<15:
                impact = -0.18
                desc = "Critically depleted: 18% more resistant"
            case ..<30:
                impact = -0.12
                desc = "Low recovery: 12% more resistant"
            case ..<50:
                impact = -0.05
                desc = "Below average recovery: 5% more resistant"
            case 75...:
                impact = 0.05
                desc = "Well recovered: 5% more sensitive"
            default:
                impact = 0
                desc = "Normal recovery"
            }
            if impact != 0 {
                factor += impact
                contributions.append(.init(metric: "Body Battery", value: "\(bb)/100", impact: impact, description: desc))
            }
        }

        // Acute stress at meal time
        if let stress = ctx.currentStress {
            let impact: Double
            let desc: String
            if stress > 75 {
                impact = -0.08
                desc = "High acute stress: 8% more resistant"
            } else if stress > 60 {
                impact = -0.04
                desc = "Moderate stress: 4% more resistant"
            } else {
                impact = 0
                desc = "Low stress"
            }
            if impact != 0 {
                factor += impact
                contributions.append(.init(metric: "Current Stress", value: "\(stress)/100", impact: impact, description: desc))
            }
        }

        // --- Heart Rate / HRV ---
        if let hrDelta = ctx.restingHRDelta {
            let impact: Double
            let desc: String
            if hrDelta > 12 {
                impact = -0.12
                desc = "Significantly elevated RHR: 12% more resistant"
            } else if hrDelta > 8 {
                impact = -0.07
                desc = "Mildly elevated RHR: 7% more resistant"
            } else if hrDelta < -5 {
                impact = 0.03
                desc = "Low RHR (well-rested): 3% more sensitive"
            } else {
                impact = 0
                desc = "Normal resting HR"
            }
            if impact != 0 {
                factor += impact
                contributions.append(.init(
                    metric: "Resting HR Delta",
                    value: "\(hrDelta > 0 ? "+" : "")\(hrDelta) bpm",
                    impact: impact,
                    description: desc
                ))
            }
        }

        if let hrvDelta = ctx.hrvDeltaPercent {
            let impact: Double
            let desc: String
            if hrvDelta < -20 {
                impact = -0.08
                desc = "HRV >20% below baseline: 8% more resistant"
            } else if hrvDelta < -10 {
                impact = -0.04
                desc = "HRV >10% below baseline: 4% more resistant"
            } else if hrvDelta > 15 {
                impact = 0.03
                desc = "HRV well above baseline: 3% more sensitive"
            } else {
                impact = 0
                desc = "Normal HRV"
            }
            if impact != 0 {
                factor += impact
                contributions.append(.init(
                    metric: "HRV Delta",
                    value: String(format: "%+.0f%%", hrvDelta),
                    impact: impact,
                    description: desc
                ))
            }
        }

        // --- Activity ---
        // Yesterday's activity has the strongest delayed sensitivity effect.
        if let yesterdayCal = ctx.activeCaloriesYesterday {
            let impact: Double
            let desc: String
            if yesterdayCal > 600 {
                impact = 0.15
                desc = "Very active yesterday: 15% more sensitive"
            } else if yesterdayCal > 400 {
                impact = 0.10
                desc = "Active yesterday: 10% more sensitive"
            } else if yesterdayCal > 250 {
                impact = 0.05
                desc = "Moderately active yesterday: 5% more sensitive"
            } else {
                impact = 0
                desc = "Low activity yesterday"
            }
            if impact != 0 {
                factor += impact
                contributions.append(.init(
                    metric: "Yesterday Activity",
                    value: "\(yesterdayCal) cal",
                    impact: impact,
                    description: desc
                ))
            }
        }

        // Today's activity (smaller effect, still developing)
        if let todayCal = ctx.activeCaloriesToday {
            let impact: Double
            let desc: String
            if todayCal > 400 {
                impact = 0.08
                desc = "Active today: 8% more sensitive"
            } else if todayCal > 200 {
                impact = 0.04
                desc = "Moderately active today: 4% more sensitive"
            } else {
                impact = 0
                desc = "Low activity today"
            }
            if impact != 0 {
                factor += impact
                contributions.append(.init(
                    metric: "Today Activity",
                    value: "\(todayCal) cal",
                    impact: impact,
                    description: desc
                ))
            }
        }

        // --- Training Status ---
        if let status = ctx.trainingStatus {
            let impact: Double
            let desc: String
            switch status {
            case "overreaching":
                impact = -0.10
                desc = "Overreaching: 10% more resistant"
            case "detraining":
                impact = -0.05
                desc = "Detraining: 5% more resistant"
            case "productive":
                impact = 0.03
                desc = "Productive training: 3% more sensitive"
            default:
                impact = 0
                desc = "Normal training status"
            }
            if impact != 0 {
                factor += impact
                contributions.append(.init(metric: "Training Status", value: status, impact: impact, description: desc))
            }
        }

        // --- Clamp sensitivity factor ---
        let clampedFactor = max(0.60, min(1.40, factor))

        // --- Convert to insulin demand factor ---
        // insulinDemandFactor = 1.0 / sensitivityFactor
        // Higher demand = more insulin needed. Self-documenting.
        let demandFactor = 1.0 / clampedFactor

        return SensitivityResult(
            sensitivityFactor: clampedFactor,
            insulinDemandFactor: demandFactor,
            contributions: contributions
        )
    }
}
