import Charts
import SwiftUI

/// Two-line BG forecast chart for the V2 treatment flow.
///
/// Both lines use the SAME lightweight prediction model to eliminate model divergence:
/// - Gray dashed: existing IOB decay only (no new treatment)
/// - Blue solid: existing IOB + new bolus + distributed carb entries from selected meals
///
/// The gap between lines is purely the treatment effect, not model mismatch.
struct V2ForecastChart: View {
    var state: Treatments.StateModel

    @Environment(\.colorScheme) var colorScheme

    private var historyStart: Date { Date(timeIntervalSinceNow: -2 * 3600) }
    private var forecastEnd: Date { Date(timeIntervalSinceNow: 6 * 3600) }

    /// BG target range bounds
    private var lowTarget: Double { Double(truncating: state.lowGlucose as NSDecimalNumber) }
    private var highTarget: Double { Double(truncating: state.highGlucose as NSDecimalNumber) }

    /// Historical glucose points from the last 2 hours
    private var historyPoints: [(date: Date, value: Double)] {
        state.glucoseFromPersistence.compactMap { g in
            guard let date = g.date, date >= historyStart else { return nil }
            return (date, Double(g.glucose))
        }.sorted { $0.date < $1.date }
    }

    // MARK: - Shared Prediction Model

    /// Common model parameters extracted once for both forecast lines.
    private var modelParams: (currentBG: Double, isf: Double, cr: Double, iob: Double, valid: Bool) {
        let bg = Double(truncating: state.currentBG as NSDecimalNumber)
        let isf = Double(truncating: state.isf as NSDecimalNumber)
        let cr = Double(truncating: state.carbRatio as NSDecimalNumber)
        let iob = Double(truncating: state.iob as NSDecimalNumber)
        return (bg, isf, cr, iob, bg > 0 && isf > 0 && cr > 0)
    }

    /// Predict BG over 6 hours using a lightweight ISF/CR model.
    ///
    /// Both forecast lines call this with different parameters:
    /// - "No treatment": bolusUnits=0, meals=[]
    /// - "With treatment": bolusUnits=proposed, meals=selectedMeals
    ///
    /// Using the same model for both ensures the gap is purely treatment effect.
    private func predict(
        bolusUnits: Double,
        meals: [V2DetectedMeal],
        demandFactor: Double,
        tau: Double
    ) -> [(date: Date, value: Double)] {
        let params = modelParams
        guard params.valid else { return [] }

        let now = Date()
        let steps = 73 // 6h * 12 steps/h + 1
        var forecast: [(date: Date, value: Double)] = []

        for step in 0 ..< steps {
            let minutesAhead = Double(step * 5)
            let date = now.addingTimeInterval(minutesAhead * 60)

            // Carb impact: sum gamma CDF contributions from each meal at its own timestamp
            var carbBGDelta = 0.0
            for meal in meals {
                let mealMinutesAgo = now.timeIntervalSince(meal.date) / 60.0
                let totalMinutes = mealMinutesAgo + minutesAhead
                let absorbed = MacroAbsorptionEngine.gammaCDFValue(tau: tau, atMinutes: totalMinutes)
                let totalCarbs = meal.carbs * demandFactor
                carbBGDelta += (totalCarbs * absorbed / params.cr) * params.isf
            }

            // Insulin impact: new bolus absorption + existing IOB decay
            // Both use the same simplified model so there's no systematic divergence
            let bolusAbsorbed = min(1.0, minutesAhead / (4.0 * 60.0))
            let iobDecay = max(0, 1.0 - minutesAhead / (6.0 * 60.0))
            let insulinBGDelta = (bolusUnits * bolusAbsorbed + params.iob * (1.0 - iobDecay)) * params.isf

            let predictedBG = max(40, params.currentBG + carbBGDelta - insulinBGDelta)
            forecast.append((date, predictedBG))
        }

        return forecast
    }

    /// "With treatment" forecast: carb absorption from selected meals + proposed bolus + existing IOB
    private var withTreatmentForecast: [(date: Date, value: Double)] {
        let selectedMeals = state.v2SelectedMealsForChart ?? []
        let demandFactor = state.v2DemandFactor
        let tau = state.v2TauCarb ?? 35.0
        let bolusUnits = Double(truncating: state.amount as NSDecimalNumber)

        return predict(
            bolusUnits: bolusUnits,
            meals: selectedMeals,
            demandFactor: demandFactor,
            tau: tau
        )
    }

    /// "No treatment" forecast: only existing IOB decaying, no new carbs or bolus.
    /// Uses the same model as withTreatmentForecast so the gap is purely the treatment effect.
    private var noTreatmentForecast: [(date: Date, value: Double)] {
        let tau = state.v2TauCarb ?? 35.0
        return predict(
            bolusUnits: 0,
            meals: [],
            demandFactor: 1.0,
            tau: tau
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header labels
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle().fill(.gray).frame(width: 6, height: 6)
                    Text("No treatment").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Circle().fill(.blue).frame(width: 6, height: 6)
                    Text("With treatment").font(.caption2).foregroundStyle(.secondary)
                }
            }

            // Chart
            Chart {
                // Target range band
                RectangleMark(
                    xStart: .value("Start", historyStart),
                    xEnd: .value("End", forecastEnd),
                    yStart: .value("Low", lowTarget),
                    yEnd: .value("High", highTarget)
                )
                .foregroundStyle(.green.opacity(0.1))

                // Historical glucose points
                ForEach(historyPoints, id: \.date) { point in
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("BG", point.value)
                    )
                    .foregroundStyle(glucoseColor(point.value))
                    .symbolSize(20)
                }

                // No-treatment forecast (gray dashed)
                ForEach(noTreatmentForecast, id: \.date) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("BG", point.value),
                        series: .value("Series", "no-treatment")
                    )
                    .foregroundStyle(.gray.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }

                // With-treatment forecast (blue solid)
                ForEach(withTreatmentForecast, id: \.date) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("BG", point.value),
                        series: .value("Series", "with-treatment")
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                }

                // Current BG marker
                if let lastHistory = historyPoints.last {
                    PointMark(
                        x: .value("Time", lastHistory.date),
                        y: .value("BG", lastHistory.value)
                    )
                    .foregroundStyle(.primary)
                    .symbolSize(60)
                }

                // Eventual BG diamond (with treatment)
                if let lastForecast = withTreatmentForecast.last {
                    PointMark(
                        x: .value("Time", lastForecast.date),
                        y: .value("BG", lastForecast.value)
                    )
                    .foregroundStyle(.blue)
                    .symbol(.diamond)
                    .symbolSize(40)
                }

                // Now line
                RuleMark(x: .value("Now", Date()))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 1)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                        .font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text("\(Int(v))")
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartYScale(domain: yAxisDomain)
        }
    }

    // MARK: - Helpers

    private var yAxisDomain: ClosedRange<Double> {
        let allValues = historyPoints.map(\.value) + withTreatmentForecast.map(\.value) + noTreatmentForecast.map(\.value)
        let minVal = max(40, (allValues.min() ?? 40) - 20)
        let maxVal = min(400, (allValues.max() ?? 250) + 20)
        return minVal ... maxVal
    }

    private func glucoseColor(_ value: Double) -> Color {
        if value < lowTarget { return .red }
        if value > highTarget { return .orange }
        return .green
    }
}
