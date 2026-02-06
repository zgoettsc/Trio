import Charts
import SwiftUI

/// View presented when user taps the Cronometer button on the treatment page.
/// Shows the detected meal, recommended entry (scaled by personal factor), BG prediction, and past outcomes.
struct CronometerMealRecommendationView: View {
    let meal: InferredMealEvent
    let recommendedCarbs: Double
    let recommendedFat: Double
    let recommendedProtein: Double
    let adjustmentFactor: Double
    let fpuCarbEquivalents: Double
    let fpuDurationHours: Double
    let predictedEventualBG: Int?
    let predictedMinBG: Int?
    let currentBG: Int
    let units: String // "mg/dL" or "mmol/L"
    let glucoseHistory: [GlucosePoint] // Recent readings for chart
    let predictionCurve: [Int]? // Predicted BG values at 5-min intervals
    let outcomeStats: CronometerOutcomeStats

    let onApply: (Double, Double, Double) -> Void // (carbs, fat, protein) to populate
    let onAdjustFactor: (Double) -> Void
    let onDismiss: () -> Void

    @State private var editedFactor: Double
    @State private var showFactorEditor = false

    struct GlucosePoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Int
    }

    init(
        meal: InferredMealEvent,
        recommendedCarbs: Double,
        recommendedFat: Double,
        recommendedProtein: Double,
        adjustmentFactor: Double,
        fpuCarbEquivalents: Double,
        fpuDurationHours: Double,
        predictedEventualBG: Int?,
        predictedMinBG: Int?,
        currentBG: Int,
        units: String,
        glucoseHistory: [GlucosePoint],
        predictionCurve: [Int]?,
        outcomeStats: CronometerOutcomeStats,
        onApply: @escaping (Double, Double, Double) -> Void,
        onAdjustFactor: @escaping (Double) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.meal = meal
        self.recommendedCarbs = recommendedCarbs
        self.recommendedFat = recommendedFat
        self.recommendedProtein = recommendedProtein
        self.adjustmentFactor = adjustmentFactor
        self.fpuCarbEquivalents = fpuCarbEquivalents
        self.fpuDurationHours = fpuDurationHours
        self.predictedEventualBG = predictedEventualBG
        self.predictedMinBG = predictedMinBG
        self.currentBG = currentBG
        self.units = units
        self.glucoseHistory = glucoseHistory
        self.predictionCurve = predictionCurve
        self.outcomeStats = outcomeStats
        self.onApply = onApply
        self.onAdjustFactor = onAdjustFactor
        self.onDismiss = onDismiss
        self._editedFactor = State(initialValue: adjustmentFactor)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // BG Prediction Chart
                    predictionChartSection

                    // Cronometer meal details
                    cronometerMealSection

                    // Recommended entry
                    recommendedEntrySection

                    // FPU info
                    if fpuCarbEquivalents > 1 {
                        fpuSection
                    }

                    // Past performance
                    if outcomeStats.totalApplied > 0 {
                        pastPerformanceSection
                    }

                    // Action buttons
                    actionButtons
                }
                .padding()
            }
            .navigationTitle("Cronometer Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
        }
    }

    // MARK: - Chart Section

    private var predictionChartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("BG Prediction", systemImage: "chart.xyaxis.line")
                .font(.headline)

            Chart {
                // Target range band
                RectangleMark(
                    xStart: .value("Start", chartStartDate),
                    xEnd: .value("End", chartEndDate),
                    yStart: .value("Low", 70),
                    yEnd: .value("High", 180)
                )
                .foregroundStyle(Color.green.opacity(0.08))

                // Historical glucose points
                ForEach(glucoseHistory) { point in
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("BG", point.value)
                    )
                    .foregroundStyle(glucoseColor(for: point.value))
                    .symbolSize(20)
                }

                // Prediction curve
                if let predictions = predictionCurve {
                    ForEach(Array(predictions.enumerated()), id: \.offset) { index, value in
                        let predDate = Date().addingTimeInterval(TimeInterval(index * 5 * 60))
                        LineMark(
                            x: .value("Time", predDate),
                            y: .value("BG", value)
                        )
                        .foregroundStyle(Color.blue.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }
                }

                // Current BG marker
                PointMark(
                    x: .value("Time", Date()),
                    y: .value("BG", currentBG)
                )
                .foregroundStyle(.primary)
                .symbolSize(40)
                .annotation(position: .top) {
                    Text("\(currentBG)")
                        .font(.caption2.bold())
                }

                // Eventual BG marker
                if let eventualBG = predictedEventualBG {
                    PointMark(
                        x: .value("Time", Date().addingTimeInterval(2 * 3600)),
                        y: .value("BG", eventualBG)
                    )
                    .foregroundStyle(glucoseColor(for: eventualBG))
                    .symbolSize(50)
                    .symbol(.diamond)
                    .annotation(position: .top) {
                        Text("Eventual: \(eventualBG)")
                            .font(.caption2.bold())
                            .foregroundStyle(glucoseColor(for: eventualBG))
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour)) { value in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                }
            }
            .chartYScale(domain: chartYDomain)
            .frame(height: 200)

            // Prediction summary
            HStack {
                if let eventualBG = predictedEventualBG {
                    Label("Eventual: \(eventualBG) \(units)", systemImage: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(glucoseColor(for: eventualBG))
                }
                Spacer()
                if let minBG = predictedMinBG {
                    Label("Min: \(minBG) \(units)", systemImage: "arrow.down")
                        .font(.caption)
                        .foregroundStyle(minBG < 70 ? .red : .secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 4)
    }

    // MARK: - Cronometer Meal

    private var cronometerMealSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Actual Nutrition (Cronometer)", systemImage: "fork.knife.circle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            let timeStr = meal.detectedAt.formatted(date: .omitted, time: .shortened)
            Text("Detected at ~\(timeStr)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                macroCard("Carbs", value: Int(meal.carbsDelta), unit: "g", color: .blue)
                macroCard("Fat", value: Int(meal.fatDelta), unit: "g", color: .yellow)
                macroCard("Protein", value: Int(meal.proteinDelta), unit: "g", color: .red)
                macroCard("Cal", value: Int(meal.totalCalories), unit: "kcal", color: .orange)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Recommended Entry

    private var recommendedEntrySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Recommended Entry", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Spacer()
                Button(action: { showFactorEditor.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Factor: \(String(format: "%.2f", adjustmentFactor))")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)
                }
            }

            Text("Scaled from Cronometer using your personal factor")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                macroCard("Carbs", value: Int(recommendedCarbs), unit: "g", color: .blue)
                macroCard("Fat", value: Int(recommendedFat), unit: "g", color: .yellow)
                macroCard("Protein", value: Int(recommendedProtein), unit: "g", color: .red)
            }

            if showFactorEditor {
                factorEditorView
            }
        }
        .padding()
        .background(Color.green.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Factor Editor

    private var factorEditorView: some View {
        VStack(spacing: 8) {
            Divider()

            Text("Adjustment Factor")
                .font(.subheadline.bold())

            Text("Controls how much of the Cronometer carbs to enter. Lower = less insulin. Your settings are tuned around your current carb-counting habits.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("\(String(format: "%.2f", editedFactor))")
                    .font(.title3.monospacedDigit().bold())
                    .frame(width: 60)

                Slider(value: $editedFactor, in: 0.2 ... 1.5, step: 0.05)
                    .tint(.blue)
            }

            HStack {
                Text("Less insulin")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("More insulin")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if abs(editedFactor - adjustmentFactor) > 0.01 {
                Button("Apply New Factor") {
                    onAdjustFactor(editedFactor)
                }
                .font(.caption.bold())
                .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - FPU Section

    private var fpuSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Fat/Protein Units", systemImage: "clock.arrow.circlepath")
                .font(.headline)
                .foregroundStyle(.purple)

            Text(
                "The app's FPU system will convert fat+protein into \(Int(fpuCarbEquivalents))g of delayed carb-equivalents, absorbed over \(String(format: "%.1f", fpuDurationHours)) hours starting 1h after the meal."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Image(systemName: "arrow.right")
                    .foregroundStyle(.purple)
                Text("\(Int(meal.fatDelta))g fat + \(Int(meal.proteinDelta))g protein")
                Image(systemName: "equal")
                Text("\(Int(fpuCarbEquivalents))g carb-equiv over \(String(format: "%.0f", fpuDurationHours))h")
                    .bold()
            }
            .font(.caption)
        }
        .padding()
        .background(Color.purple.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Past Performance

    private var pastPerformanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Learning History", systemImage: "brain.head.profile")
                .font(.headline)
                .foregroundStyle(.indigo)

            HStack(spacing: 20) {
                statBadge(
                    "\(outcomeStats.completedCount)",
                    label: "Tracked",
                    icon: "list.bullet.clipboard"
                )
                if outcomeStats.completedCount > 0 {
                    statBadge(
                        "\(outcomeStats.inRangeCount)/\(outcomeStats.completedCount)",
                        label: "In Range",
                        icon: "checkmark.circle"
                    )
                }
                if outcomeStats.cleanWindowCount > 0 {
                    statBadge(
                        "\(outcomeStats.cleanWindowCount)",
                        label: "Clean",
                        icon: "sparkles"
                    )
                }
                if let avgPeak = outcomeStats.averagePeakBG {
                    statBadge(
                        "\(avgPeak)",
                        label: "Avg Peak",
                        icon: "arrow.up"
                    )
                }
            }

            Text("Factor adjusts automatically based on BG outcomes at +2h, +4h, +6h, +8h, +10h after each recommendation. Meals eaten in the observation window are detected and excluded from learning.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.indigo.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: {
                // Use the current factor's recommended values
                let scaledCarbs = meal.carbsDelta * editedFactor
                onApply(scaledCarbs, recommendedFat, recommendedProtein)
            }) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Apply to Bolus Calculator")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green)
                .foregroundColor(.white)
                .cornerRadius(12)
            }

            Text("This will fill in carbs, fat, and protein. Review the bolus recommendation before confirming.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Helper Views

    private func macroCard(_ title: String, value: Int, unit: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(color)
            Text("\(unit) \(title.lowercased())")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func statBadge(_ value: String, label: String, icon: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption)
            Text(value)
                .font(.subheadline.bold().monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func glucoseColor(for value: Int) -> Color {
        if value < 70 { return .red }
        if value > 180 { return .orange }
        return .green
    }

    // MARK: - Chart Helpers

    private var chartStartDate: Date {
        Date().addingTimeInterval(-2 * 3600) // 2 hours ago
    }

    private var chartEndDate: Date {
        Date().addingTimeInterval(3 * 3600) // 3 hours ahead
    }

    private var chartYDomain: ClosedRange<Int> {
        var minVal = 50
        var maxVal = 250

        let allValues = glucoseHistory.map(\.value) + [currentBG] + (predictionCurve ?? [])
        if let predEventual = predictedEventualBG { _ = allValues + [predEventual] }

        if let lowest = allValues.min() { minVal = min(minVal, lowest - 10) }
        if let highest = allValues.max() { maxVal = max(maxVal, highest + 10) }

        return max(0, minVal) ... maxVal
    }
}
