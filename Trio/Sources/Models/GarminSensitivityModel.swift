import Foundation

// MARK: - Phase D: Garmin Sensitivity Model
//
// Rule-based model that computes insulin sensitivity from Garmin health data.
// All field references match the Garmin Health API v1.2.3 spec.
//
// Outputs an insulinDemandFactor: multiply entries by this value.
//   1.0  = normal day
//   1.15 = 15% more insulin needed (bad sleep, high stress)
//   0.90 = 10% less insulin needed (good recovery, active yesterday)
//
// V3 Change: Individual impacts scaled ~50% down from original values so that
// multiple signals contribute meaningfully before hitting the ±30% demand cap.
// Demand factor clamped directly to [0.70, 1.30] for a symmetric ±30% range.

// NOTE: Impact weights below are initial heuristics, not regression-derived (#8).
// They are directionally grounded in literature (Spiegel 1999, Donga 2010, etc.)
// but the specific magnitudes and their additive stacking are estimated, not
// calibrated against BG outcome data. The outcome learning system is intended
// to validate and adjust these over time. Users should monitor the demand
// factor's effect on their outcomes and adjust or disable if results are poor.
struct GarminSensitivityModel {

    /// Result of the sensitivity calculation, with breakdown for UI display.
    struct SensitivityResult {
        let sensitivityFactor: Double       // raw (internal, pre-clamp)
        let insulinDemandFactor: Double     // 0.70-1.30 (used in code, ±30% cap)
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

        // --- Sleep Score (overallSleepScore.value from sleeps collection) ---
        // Poor sleep is the strongest single predictor of next-day resistance.
        // Spiegel (1999): 4h sleep x 6 nights -> 40% reduced glucose clearance.
        // Garmin: EXCELLENT 90-100, GOOD 80-89, FAIR 60-79, POOR <60
        if let sleep = ctx.sleepScoreValue {
            let impact: Double
            let desc: String
            switch sleep {
            case ..<40:
                impact = -0.11
                desc = "Terrible sleep: 11% more resistant"
            case ..<55:
                impact = -0.08
                desc = "Poor sleep: 8% more resistant"
            case ..<70:
                impact = -0.04
                desc = "Fair sleep: 4% more resistant"
            case 85...:
                impact = 0.03
                desc = "Great sleep: 3% more sensitive"
            default:
                impact = 0
                desc = "Normal sleep range"
            }
            factor += impact
            contributions.append(.init(metric: "Sleep Score", value: "\(sleep)/100", impact: impact, description: desc))
        }

        // Sleep duration (sleepDurationInSeconds from sleeps collection)
        if let totalSleep = ctx.totalSleepMinutes {
            let impact: Double
            let desc: String
            if totalSleep < 300 {
                impact = -0.05
                desc = "Less than 5h sleep: 5% more resistant"
            } else if totalSleep < 360 {
                impact = -0.03
                desc = "Less than 6h sleep: 3% more resistant"
            } else {
                impact = 0
                desc = "Adequate sleep duration"
            }
            if impact != 0 {
                factor += impact
                let hours = totalSleep / 60
                let mins = totalSleep % 60
                contributions.append(.init(
                    metric: "Sleep Duration",
                    value: "\(hours)h \(mins)m",
                    impact: impact,
                    description: desc
                ))
            }
        }

        // --- Stress & Recovery ---

        // Body Battery (from stressDetails timeOffsetBodyBatteryValues, current reading)
        if let bb = ctx.currentBodyBattery {
            let impact: Double
            let desc: String
            switch bb {
            case ..<15:
                impact = -0.09
                desc = "Critically depleted: 9% more resistant"
            case ..<30:
                impact = -0.06
                desc = "Low recovery: 6% more resistant"
            case ..<50:
                impact = -0.03
                desc = "Below average recovery: 3% more resistant"
            case 75...:
                impact = 0.03
                desc = "Well recovered: 3% more sensitive"
            default:
                impact = 0
                desc = "Normal recovery"
            }
            if impact != 0 {
                factor += impact
                contributions.append(.init(metric: "Body Battery", value: "\(bb)/100", impact: impact, description: desc))
            }
        }

        // Current stress level (from stressDetails timeOffsetStressLevelValues, most recent positive reading)
        // Garmin: 1-25 rest, 26-50 low, 51-75 medium, 76-100 high
        if let stress = ctx.currentStressLevel {
            let impact: Double
            let desc: String
            if stress > 75 {
                impact = -0.04
                desc = "High acute stress: 4% more resistant"
            } else if stress > 60 {
                impact = -0.02
                desc = "Moderate stress: 2% more resistant"
            } else {
                impact = 0
                desc = "Low stress"
            }
            if impact != 0 {
                factor += impact
                contributions.append(.init(metric: "Current Stress", value: "\(stress)/100", impact: impact, description: desc))
            }
        }

        // Average stress today (from dailies averageStressLevel)
        // Supplements the current reading — sustained stress matters more than a spike
        if let avgStress = ctx.averageStressLevel, avgStress > 0 { // -1 means insufficient data
            let impact: Double
            let desc: String
            if avgStress > 60 {
                impact = -0.03
                desc = "Sustained high stress today: 3% more resistant"
            } else if avgStress > 45 {
                impact = -0.02
                desc = "Elevated stress today: 2% more resistant"
            } else {
                impact = 0
                desc = "Normal average stress"
            }
            if impact != 0 {
                factor += impact
                contributions.append(.init(
                    metric: "Avg Stress Today",
                    value: "\(avgStress)/100",
                    impact: impact,
                    description: desc
                ))
            }
        }

        // --- Heart Rate / HRV ---

        // Resting HR delta (restingHeartRateInBeatsPerMinute from dailies vs 7-day avg)
        if let hrDelta = ctx.restingHRDelta {
            let impact: Double
            let desc: String
            if hrDelta > 12 {
                impact = -0.06
                desc = "Significantly elevated RHR: 6% more resistant"
            } else if hrDelta > 8 {
                impact = -0.04
                desc = "Mildly elevated RHR: 4% more resistant"
            } else if hrDelta < -5 {
                impact = 0.02
                desc = "Low RHR (well-rested): 2% more sensitive"
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

        // HRV delta (lastNightAvg from hrv collection vs weekly average)
        if let hrvDelta = ctx.hrvDeltaPercent {
            let impact: Double
            let desc: String
            if hrvDelta < -20 {
                impact = -0.04
                desc = "HRV >20% below baseline: 4% more resistant"
            } else if hrvDelta < -10 {
                impact = -0.02
                desc = "HRV >10% below baseline: 2% more resistant"
            } else if hrvDelta > 15 {
                impact = 0.02
                desc = "HRV well above baseline: 2% more sensitive"
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

        // Yesterday's activity (delayed sensitivity effect — most impactful)
        // Uses activeKilocalories from yesterday's daily summary
        if let yesterdayCal = ctx.yesterdayActiveKilocalories {
            let impact: Double
            let desc: String
            if yesterdayCal > 600 {
                impact = 0.08
                desc = "Very active yesterday: 8% more sensitive"
            } else if yesterdayCal > 400 {
                impact = 0.05
                desc = "Active yesterday: 5% more sensitive"
            } else if yesterdayCal > 250 {
                impact = 0.03
                desc = "Moderately active yesterday: 3% more sensitive"
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
        // Uses activeKilocalories from today's daily summary
        if let todayCal = ctx.activeKilocalories {
            let impact: Double
            let desc: String
            if todayCal > 400 {
                impact = 0.04
                desc = "Active today: 4% more sensitive"
            } else if todayCal > 200 {
                impact = 0.02
                desc = "Moderately active today: 2% more sensitive"
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

        // Vigorous intensity yesterday (additional bonus for hard exercise)
        if let vigorousYest = ctx.yesterdayVigorousIntensityDurationInSeconds, vigorousYest > 0 {
            let vigorousMinutes = vigorousYest / 60
            let impact: Double
            let desc: String
            if vigorousMinutes > 45 {
                impact = 0.04
                desc = "Heavy exercise yesterday: 4% more sensitive"
            } else if vigorousMinutes > 20 {
                impact = 0.02
                desc = "Vigorous exercise yesterday: 2% more sensitive"
            } else {
                impact = 0
                desc = "Light exercise yesterday"
            }
            if impact != 0 {
                factor += impact
                contributions.append(.init(
                    metric: "Vigorous Exercise",
                    value: "\(vigorousMinutes) min yesterday",
                    impact: impact,
                    description: desc
                ))
            }
        }

        // --- Convert to insulin demand factor and clamp directly to ±30% ---
        // V3 Change: Clamp the demand factor symmetrically instead of the sensitivity
        // factor. This gives a clean ±30% range (0.70 to 1.30) without the asymmetry
        // that the 1/x inversion previously caused (old range was 0.71 to 1.67).
        let rawDemandFactor = 1.0 / factor
        let demandFactor = max(0.70, min(1.30, rawDemandFactor))

        return SensitivityResult(
            sensitivityFactor: factor,
            insulinDemandFactor: demandFactor,
            contributions: contributions
        )
    }
}
