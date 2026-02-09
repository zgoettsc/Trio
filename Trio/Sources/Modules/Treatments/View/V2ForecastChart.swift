import Charts
import SwiftUI

/// Two-line BG forecast chart for the V2 treatment flow.
///
/// Shows:
/// - Gray dashed line: current trajectory (no intervention)
/// - Blue solid line: projected trajectory with the proposed treatment
/// - Green band: target range (70-180 mg/dL or user configured)
/// - 2h of history as colored dots + 6h of forecast
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

    /// Build the "with treatment" forecast line from the state's prediction data.
    /// Uses the COB prediction (or UAM if available) as the primary forecast.
    private var withTreatmentForecast: [(date: Date, value: Double)] {
        guard let predictions = state.simulatedDetermination?.predictions else { return [] }
        let values = predictions.cob ?? predictions.uam ?? predictions.iob ?? []
        let now = Date()
        return values.enumerated().map { index, value in
            (now.addingTimeInterval(TimeInterval(index * 5 * 60)), Double(value))
        }
    }

    /// Build the "no treatment" forecast from the IOB-only prediction (baseline without new carbs/bolus).
    /// Falls back to a flat line at current BG if no predictions available.
    private var noTreatmentForecast: [(date: Date, value: Double)] {
        // Use stored no-treatment prediction if available
        if !state.v2NoTreatmentPrediction.isEmpty {
            let now = Date()
            return state.v2NoTreatmentPrediction.enumerated().map { index, value in
                (now.addingTimeInterval(TimeInterval(index * 5 * 60)), Double(value))
            }
        }
        // Fallback: flat line at current BG
        let currentBG = Double(truncating: state.currentBG as NSDecimalNumber)
        if currentBG > 0 {
            let now = Date()
            return stride(from: 0, through: 6 * 60, by: 5).map { min in
                (now.addingTimeInterval(TimeInterval(min * 60)), currentBG)
            }
        }
        return []
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
