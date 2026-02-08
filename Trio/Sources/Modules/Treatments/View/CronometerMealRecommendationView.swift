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
    let mealPrediction: MealOutcomePrediction?

    // Late dosing context (nil/false if this is a fresh meal)
    let isLateMeal: Bool
    let minutesSinceMeal: Double
    let decayAdjustedCarbs: Double? // nil if fresh meal

    let isFactorLocked: Bool
    let onApply: (Double, Double, Double) -> Void // (carbs, fat, protein) to populate
    let onAdjustFactor: (Double) -> Void
    let onToggleFactorLock: () -> Void
    let onDismiss: () -> Void

    // V2 split dosing (nil = V1 mode, no slider shown)
    let v2UpfrontCarbs: Double?
    let v2UpfrontPercent: Double?
    let v2CurveSuggestedPercent: Double?
    let v2TauCarb: Double?
    let v2FatTotalEquiv: Double?
    let v2SafeWindowMinutes: Int?
    let v2DemandFactor: Double?
    let v2CarbRatio: Double?
    let onAdjustV2Upfront: ((Double) -> Void)?

    @State private var editedFactor: Double
    @State private var showFactorEditor = false
    @State private var editedUpfrontPercent: Double?

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
        mealPrediction: MealOutcomePrediction?,
        isLateMeal: Bool = false,
        minutesSinceMeal: Double = 0,
        decayAdjustedCarbs: Double? = nil,
        isFactorLocked: Bool = false,
        v2UpfrontCarbs: Double? = nil,
        v2UpfrontPercent: Double? = nil,
        v2CurveSuggestedPercent: Double? = nil,
        v2TauCarb: Double? = nil,
        v2FatTotalEquiv: Double? = nil,
        v2SafeWindowMinutes: Int? = nil,
        v2DemandFactor: Double? = nil,
        v2CarbRatio: Double? = nil,
        onApply: @escaping (Double, Double, Double) -> Void,
        onAdjustFactor: @escaping (Double) -> Void,
        onToggleFactorLock: @escaping () -> Void = {},
        onAdjustV2Upfront: ((Double) -> Void)? = nil,
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
        self.mealPrediction = mealPrediction
        self.isLateMeal = isLateMeal
        self.minutesSinceMeal = minutesSinceMeal
        self.decayAdjustedCarbs = decayAdjustedCarbs
        self.isFactorLocked = isFactorLocked
        self.v2UpfrontCarbs = v2UpfrontCarbs
        self.v2UpfrontPercent = v2UpfrontPercent
        self.v2CurveSuggestedPercent = v2CurveSuggestedPercent
        self.v2TauCarb = v2TauCarb
        self.v2FatTotalEquiv = v2FatTotalEquiv
        self.v2SafeWindowMinutes = v2SafeWindowMinutes
        self.v2DemandFactor = v2DemandFactor
        self.v2CarbRatio = v2CarbRatio
        self.onApply = onApply
        self.onAdjustFactor = onAdjustFactor
        self.onToggleFactorLock = onToggleFactorLock
        self.onAdjustV2Upfront = onAdjustV2Upfront
        self.onDismiss = onDismiss
        self._editedFactor = State(initialValue: adjustmentFactor)
        self._editedUpfrontPercent = State(initialValue: v2UpfrontPercent)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // Late meal warning banner
                    if isLateMeal {
                        lateMealBanner
                    }

                    // BG Prediction Chart
                    predictionChartSection

                    // Cronometer meal details
                    cronometerMealSection

                    // Recommended entry
                    recommendedEntrySection

                    // V2 Split Dosing slider (shows when V2 is active)
                    if v2UpfrontPercent != nil {
                        v2SplitDosingSection
                    }

                    // FPU info
                    if fpuCarbEquivalents > 1 {
                        fpuSection
                    }

                    // Similar meal prediction
                    if let prediction = mealPrediction, prediction.similarMealCount > 0 {
                        mealPredictionSection(prediction)
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

    // MARK: - Late Meal Banner

    private var lateMealBanner: some View {
        let warning = CarbDecayModel.warningLevel(minutesSinceMeal: minutesSinceMeal)
        let carbFraction = CarbDecayModel.carbsRemainingFraction(minutesSinceMeal: minutesSinceMeal)
        let absorbedPercent = Int((1.0 - carbFraction) * 100)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: warning == .severe ? "exclamationmark.triangle.fill" : "clock.badge")
                    .font(.headline)
                Text("Late Dose — \(meal.timeAgoString)")
                    .font(.headline)
                Spacer()
            }
            .foregroundStyle(warningBannerColor(warning))

            Text(warning.message)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                VStack(spacing: 2) {
                    Text("\(absorbedPercent)%")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(.orange)
                    Text("absorbed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 2) {
                    Text("\(Int(recommendedCarbs))g")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(.blue)
                    Text("carbs remaining")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if minutesSinceMeal < 60 {
                    VStack(spacing: 2) {
                        Text("100%")
                            .font(.title3.bold().monospacedDigit())
                            .foregroundStyle(.purple)
                        Text("fat/protein")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .background(warningBannerColor(warning).opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(warningBannerColor(warning).opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private func warningBannerColor(_ warning: CarbDecayModel.LateDoseWarning) -> Color {
        switch warning {
        case .none: return .green
        case .mild: return .yellow
        case .moderate: return .orange
        case .severe: return .red
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
                        Image(systemName: isFactorLocked ? "lock.fill" : "slider.horizontal.3")
                        Text("Factor: \(String(format: "%.2f", adjustmentFactor))")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isFactorLocked ? Color.orange.opacity(0.1) : Color.blue.opacity(0.1))
                    .cornerRadius(6)
                }
            }

            Text(isFactorLocked
                ? "Carbs, fat, and protein scaled using locked factor (\(String(format: "%.2f", adjustmentFactor)))"
                : "Carbs, fat, and protein scaled from Cronometer using learned factors")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                macroCardWithDelta("Carbs", value: Int(recommendedCarbs), original: Int(meal.carbsDelta), unit: "g", color: .blue)
                macroCardWithDelta("Fat", value: Int(recommendedFat), original: Int(meal.fatDelta), unit: "g", color: .yellow)
                macroCardWithDelta("Protein", value: Int(recommendedProtein), original: Int(meal.proteinDelta), unit: "g", color: .red)
            }

            if recommendedFat < meal.fatDelta || recommendedProtein < meal.proteinDelta {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                    Text("Fat/protein reduced based on past meal outcomes. The loop handles the rest via FPU-driven SMBs over \(String(format: "%.0f", fpuDurationHours))h.")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
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

            HStack {
                Text("Adjustment Factor")
                    .font(.subheadline.bold())
                Spacer()
                Button(action: { onToggleFactorLock() }) {
                    HStack(spacing: 4) {
                        Image(systemName: isFactorLocked ? "lock.fill" : "lock.open")
                        Text(isFactorLocked ? "Locked" : "Auto-learning")
                    }
                    .font(.caption)
                    .foregroundStyle(isFactorLocked ? .orange : .green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isFactorLocked ? Color.orange.opacity(0.1) : Color.green.opacity(0.1))
                    .cornerRadius(6)
                }
            }

            if isFactorLocked {
                Text("Factor is locked. Slider changes will stick. Auto-learning from meal outcomes is paused.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Controls how much of the Cronometer carbs to enter. Lower = less insulin. Factor auto-adjusts from meal outcomes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("\(String(format: "%.2f", editedFactor))")
                    .font(.title3.monospacedDigit().bold())
                    .frame(width: 60)

                Slider(value: $editedFactor, in: 0.2 ... 1.5, step: 0.05)
                    .tint(isFactorLocked ? .orange : .blue)
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
            Label("Fat/Protein Units (Delayed Insulin)", systemImage: "clock.arrow.circlepath")
                .font(.headline)
                .foregroundStyle(.purple)

            Text(
                "The entered fat+protein will generate \(Int(fpuCarbEquivalents))g of delayed carb-equivalents. The loop will deliver extra insulin via SMBs over \(String(format: "%.0f", fpuDurationHours)) hours (starting 1h after the meal). This reduces the need for a large upfront carb bolus."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Image(systemName: "arrow.right")
                    .foregroundStyle(.purple)
                Text("\(Int(recommendedFat))g fat + \(Int(recommendedProtein))g protein")
                Image(systemName: "equal")
                Text("\(Int(fpuCarbEquivalents))g carb-equiv over \(String(format: "%.0f", fpuDurationHours))h")
                    .bold()
            }
            .font(.caption)

            // Show the total insulin picture
            let totalCarbEquiv = recommendedCarbs + fpuCarbEquivalents
            HStack(spacing: 4) {
                Image(systemName: "sum")
                    .foregroundStyle(.purple)
                Text("Total coverage: \(Int(recommendedCarbs))g upfront + \(Int(fpuCarbEquivalents))g delayed = \(Int(totalCarbEquiv))g equivalent")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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

    // MARK: - Meal Prediction Section

    private func mealPredictionSection(_ prediction: MealOutcomePrediction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Similar Meal Insights", systemImage: "brain")
                    .font(.headline)
                    .foregroundStyle(.teal)
                Spacer()
                confidenceBadge(prediction.confidence)
            }

            Text("Based on \(prediction.similarMealCount) similar past meal\(prediction.similarMealCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Predicted BG trajectory
            if prediction.predictedBGAt1h != nil || prediction.predictedBGAt2h != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Expected BG Response")
                        .font(.subheadline.bold())

                    HStack(spacing: 12) {
                        if let bg1h = prediction.predictedBGAt1h {
                            trajectoryPoint("1h", value: bg1h)
                        }
                        if let bg2h = prediction.predictedBGAt2h {
                            trajectoryPoint("2h", value: bg2h)
                        }
                        if let bg3h = prediction.predictedBGAt3h {
                            trajectoryPoint("3h", value: bg3h)
                        }
                        if let bg4h = prediction.predictedBGAt4h {
                            trajectoryPoint("4h", value: bg4h)
                        }
                        if let bg6h = prediction.predictedBGAt6h {
                            trajectoryPoint("6h", value: bg6h)
                        }
                    }
                }
            }

            // Peak and rise
            HStack(spacing: 16) {
                if let peak = prediction.predictedPeakBG {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                            .foregroundStyle(glucoseColor(for: peak))
                        Text("Peak: \(peak) \(units)")
                            .font(.caption)
                            .foregroundStyle(glucoseColor(for: peak))
                    }
                }
                if let rise = prediction.predictedBGRise {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(.secondary)
                        Text("Rise: +\(rise) \(units)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Suggested dosing
            if prediction.suggestedEffectiveICR != nil || prediction.suggestedCarbFactor != nil {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    if let suggestedICR = prediction.suggestedEffectiveICR {
                        HStack {
                            Image(systemName: "syringe")
                                .foregroundStyle(.teal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Effective ICR from similar meals: 1:\(String(format: "%.1f", suggestedICR))")
                                    .font(.caption.bold())
                                if let suggestedBolus = prediction.suggestedBolus {
                                    Text("Suggested bolus: \(String(format: "%.1f", suggestedBolus)) U")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // Show learned macro entry factors
                    if let carbF = prediction.suggestedCarbFactor,
                       let fatF = prediction.suggestedFatFactor,
                       let protF = prediction.suggestedProteinFactor
                    {
                        HStack {
                            Image(systemName: "tuningfork")
                                .foregroundStyle(.teal)
                            Text("Learned factors: carb \(String(format: "%.0f", carbF * 100))%, fat \(String(format: "%.0f", fatF * 100))%, protein \(String(format: "%.0f", protF * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let fpuEquiv = prediction.estimatedFPUCarbEquivalents, fpuEquiv > 1 {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.teal)
                            Text("FPU from suggested entry: ~\(Int(fpuEquiv))g delayed carb-equiv via SMBs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Top similar meals summary
            if !prediction.topSimilarMeals.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top Matches")
                        .font(.caption.bold())
                    ForEach(prediction.topSimilarMeals.prefix(3), id: \.meal.id) { match in
                        HStack {
                            Text(match.meal.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                            Spacer()
                            Text("\(Int(match.meal.carbs))g carb")
                                .font(.caption2)
                            if let peak = match.meal.peakBG {
                                Text("peak \(peak)")
                                    .font(.caption2)
                                    .foregroundStyle(glucoseColor(for: peak))
                            }
                            Text("\(Int(match.similarity * 100))%")
                                .font(.caption2.bold())
                                .foregroundStyle(.teal)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.teal.opacity(0.05))
        .cornerRadius(12)
    }

    private func trajectoryPoint(_ label: String, value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(glucoseColor(for: value))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func confidenceBadge(_ confidence: MealOutcomePrediction.PredictionConfidence) -> some View {
        let (text, color): (String, Color) = {
            switch confidence {
            case .high: return ("High", .green)
            case .medium: return ("Medium", .yellow)
            case .low: return ("Low", .orange)
            case .none: return ("None", .gray)
            }
        }()
        return Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .cornerRadius(4)
    }

    // MARK: - V2 Split Dosing

    private var v2SplitDosingSection: some View {
        let percent = editedUpfrontPercent ?? v2UpfrontPercent ?? 0.5
        let curvePercent = v2CurveSuggestedPercent ?? percent
        let tau = v2TauCarb ?? 35
        let fullCarbs = recommendedCarbs
        let upfrontGrams = fullCarbs * percent
        let remainingGrams = fullCarbs * (1.0 - percent)
        let cr = v2CarbRatio ?? 10.0
        let upfrontUnits = upfrontGrams / cr
        let safeWindow = v2SafeWindowMinutes ?? 45
        let isHighFat = (v2FatTotalEquiv ?? 0) > 5

        return VStack(alignment: .leading, spacing: 10) {
            Label("V2 Split Dosing", systemImage: "chart.bar.doc.horizontal")
                .font(.headline)
                .foregroundStyle(.cyan)

            // Explanation
            VStack(alignment: .leading, spacing: 4) {
                if isHighFat {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("High-fat meal: carb absorption slowed (tau: \(Int(tau)) min)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("Gamma curve suggests \(Int(curvePercent * 100))% upfront within \(safeWindow)-min safe window. Remaining carbs delivered via enhanced SMBs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Upfront % slider
            VStack(spacing: 6) {
                HStack {
                    Text("Upfront:")
                        .font(.subheadline.bold())
                    Spacer()
                    Text("\(Int(percent * 100))%")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(.cyan)
                    Text("(\(String(format: "%.0f", upfrontGrams))g = \(String(format: "%.1f", upfrontUnits))U)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ZStack(alignment: .leading) {
                    Slider(
                        value: Binding(
                            get: { percent },
                            set: { newVal in
                                editedUpfrontPercent = newVal
                                onAdjustV2Upfront?(newVal)
                            }
                        ),
                        in: 0 ... 1.0,
                        step: 0.05
                    )
                    .tint(.cyan)

                    // Curve suggestion reference mark
                    GeometryReader { geo in
                        let xPos = geo.size.width * curvePercent
                        Rectangle()
                            .fill(Color.white.opacity(0.5))
                            .frame(width: 2, height: 20)
                            .offset(x: xPos - 1)
                    }
                    .frame(height: 20)
                    .allowsHitTesting(false)
                }

                HStack {
                    Text("Less upfront")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("|")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.3))
                    Spacer()
                    Text("More upfront")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // High-fat warning
                if isHighFat && percent > curvePercent * 1.5 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Text("Exceeds 1.5x curve suggestion. High fat delays carb absorption — bolusing more upfront risks going low before carbs absorb.")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }

            // Split summary
            HStack(spacing: 16) {
                VStack(spacing: 2) {
                    Text("\(String(format: "%.0f", upfrontGrams))g")
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(.green)
                    Text("Bolus now")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)

                VStack(spacing: 2) {
                    Text("\(String(format: "%.0f", remainingGrams))g")
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(.blue)
                    Text("Via SMBs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 4)
        }
        .padding()
        .background(Color.cyan.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.cyan.opacity(0.2), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: {
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

            // V2: show split dosing summary, V1: show FPU summary
            if let percent = editedUpfrontPercent ?? v2UpfrontPercent {
                let upfrontG = Int(recommendedCarbs * percent)
                let remainingG = Int(recommendedCarbs * (1.0 - percent))
                Text("Upfront bolus: \(upfrontG)g carbs (\(Int(percent * 100))%). Remaining: \(remainingG)g carbs + \(Int(recommendedFat))g fat + \(Int(recommendedProtein))g protein via enhanced SMBs.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Carbs: \(Int(meal.carbsDelta * editedFactor))g (bolus), Fat: \(Int(recommendedFat))g + Protein: \(Int(recommendedProtein))g (FPU -> loop SMBs over \(String(format: "%.0f", fpuDurationHours))h)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
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

    private func macroCardWithDelta(_ title: String, value: Int, original: Int, unit: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(color)
            if value != original {
                Text("of \(original)\(unit)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
