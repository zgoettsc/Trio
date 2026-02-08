import Charts
import SwiftUI

/// Chart showing the decay of carbs, protein, and fat on board over time.
/// Displays three stacked area curves representing remaining macro absorption.
struct MacroDecayChartView: View {
    let decayPoints: [MacroOnBoardCalculator.DecayPoint]
    let breakdown: MacroOnBoardCalculator.MacroBreakdown

    var body: some View {
        if !breakdown.hasV2Entries {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // Header with current values
                HStack(spacing: 12) {
                    macroLabel("COB", value: breakdown.carbsOnBoard, color: .loopYellow)
                    macroLabel("POB", value: breakdown.proteinOnBoard, color: .purple)
                    macroLabel("FOB", value: breakdown.fatOnBoard, color: .orange)
                }
                .font(.caption)
                .padding(.horizontal, 4)

                // Decay chart
                Chart {
                    ForEach(decayPoints) { point in
                        // Fat (bottom layer — longest duration)
                        if breakdown.fatOnBoard > 0 {
                            AreaMark(
                                x: .value("Time", point.date),
                                y: .value("Fat", point.fat)
                            )
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [.orange.opacity(0.4), .orange.opacity(0.1)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Fat", point.fat)
                            )
                            .foregroundStyle(.orange)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                        }

                        // Protein (middle layer)
                        if breakdown.proteinOnBoard > 0 {
                            AreaMark(
                                x: .value("Time", point.date),
                                y: .value("Protein", point.protein)
                            )
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [.purple.opacity(0.4), .purple.opacity(0.1)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Protein", point.protein)
                            )
                            .foregroundStyle(.purple)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                        }

                        // Carbs (top layer — fastest decay)
                        if breakdown.carbsOnBoard > 0 {
                            AreaMark(
                                x: .value("Time", point.date),
                                y: .value("Carbs", point.carbs)
                            )
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [Color.loopYellow.opacity(0.4), Color.loopYellow.opacity(0.1)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Carbs", point.carbs)
                            )
                            .foregroundStyle(.loopYellow)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text("\(Int(v))g")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 120)

                // Legend
                HStack(spacing: 16) {
                    legendItem("Carbs", color: .loopYellow)
                    legendItem("Protein", color: .purple)
                    legendItem("Fat", color: .orange)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
        }
    }

    private func macroLabel(_ label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(label): \(String(format: "%.0f", value))g")
                .fontWeight(.medium)
        }
    }

    private func legendItem(_ label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 12, height: 3)
            Text(label)
        }
    }
}
