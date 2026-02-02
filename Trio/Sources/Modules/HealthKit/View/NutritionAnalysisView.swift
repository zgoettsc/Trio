import SwiftUI
import Swinject

struct NutritionAnalysisView: View {
    let resolver: Resolver

    @State private var matchedMeals: [MatchedMealAnalysis] = []
    @State private var summary: NutritionAnalysisSummary?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var analysisDays = 14

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Analyzing \(analysisDays) days of meal data...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        Spacer()
                    }
                }
            } else if let error = errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Analysis Error", systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else if let summary = summary {
                summarySection(summary)

                if let icrSection = icrAnalysisSection(summary) {
                    icrSection
                }

                if let bgSection = bgOutcomesSection(summary) {
                    bgSection
                }

                matchedMealsSection
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("This analysis compares your Trio carb entries with actual nutrition data from Apple Health (Cronometer) to understand your carb estimation patterns.")
                            .font(.callout)
                        Text("It will match meals by time, calculate how much you typically under- or over-estimate carbs, and show how BG responds.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Button {
                        runAnalysis()
                    } label: {
                        HStack {
                            Image(systemName: "chart.bar.doc.horizontal")
                            Text("Run Analysis (\(analysisDays) days)")
                        }
                    }
                }
            }
        }
        .listSectionSpacing(sectionSpacing)
        .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Nutrition Analysis")
        .navigationBarTitleDisplayMode(.automatic)
        .toolbar {
            if summary != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        runAnalysis()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    // MARK: - Summary Section

    @ViewBuilder
    private func summarySection(_ summary: NutritionAnalysisSummary) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "chart.bar.fill")
                        .foregroundColor(.blue)
                    Text("Estimation Accuracy")
                        .font(.headline)
                }

                // Key finding
                Text(summary.estimationDescription)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)

                // Stats grid
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 8) {
                    statCard("Matched Meals", value: "\(summary.totalMatchedMeals)")
                    statCard("Avg Ratio", value: "\(Int(summary.averageEstimationRatio * 100))%")
                    statCard("Avg Entered", value: "\(Int(summary.averageTrioCarbs))g")
                    statCard("Avg Actual", value: "\(Int(summary.averageActualCarbs))g")
                    statCard("Avg Missed", value: "\(Int(summary.averageMissedCarbs))g")
                    statCard("Median Ratio", value: "\(Int(summary.medianEstimationRatio * 100))%")
                }

                // Range
                Text("Estimation range: \(Int(summary.minEstimationRatio * 100))% – \(Int(summary.maxEstimationRatio * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Summary — \(summary.analysisPeriodDays) days")
        } footer: {
            if summary.unmatchedTrioEntries > 0 || summary.unmatchedHealthEntries > 0 {
                Text("\(summary.unmatchedTrioEntries) Trio entries and \(summary.unmatchedHealthEntries) Apple Health meals could not be matched by time.")
            }
        }
    }

    // MARK: - ICR Analysis Section

    @ViewBuilder
    private func icrAnalysisSection(_ summary: NutritionAnalysisSummary) -> some View? {
        if let apparent = summary.averageApparentICR, let effective = summary.averageEffectiveICR {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "function")
                            .foregroundColor(.purple)
                        Text("ICR Analysis")
                            .font(.headline)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Current ICR (tuned to estimates):")
                            Spacer()
                            Text("1:\(String(format: "%.1f", apparent))g")
                                .fontWeight(.medium)
                        }
                        HStack {
                            Text("True ICR (against actual carbs):")
                            Spacer()
                            Text("1:\(String(format: "%.1f", effective))g")
                                .fontWeight(.medium)
                                .foregroundColor(.blue)
                        }
                    }
                    .font(.subheadline)

                    if let adj = summary.suggestedICRAdjustment {
                        Text("If switching to actual carbs for dosing, ICR would need to increase by ~\(String(format: "%.1f", adj))x")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .padding(.top, 2)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Insulin to Carb Ratio")
            } footer: {
                Text("Your current ICR works because it compensates for systematic under-counting. The 'true' ICR is what you'd need if using Cronometer carbs directly.")
            }
        }
    }

    // MARK: - BG Outcomes Section

    @ViewBuilder
    private func bgOutcomesSection(_ summary: NutritionAnalysisSummary) -> some View? {
        if let avgRise = summary.averageBgRise, let avg2h = summary.averageBgChange2h {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundColor(.red)
                        Text("Post-Meal BG Response")
                            .font(.headline)
                    }

                    HStack(spacing: 24) {
                        VStack {
                            Text("Avg Peak Rise")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("+\(avgRise)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(avgRise > 60 ? .red : avgRise > 40 ? .orange : .green)
                            Text("mg/dL")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        VStack {
                            Text("Avg 2h Change")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(avg2h > 0 ? "+" : "")\(avg2h)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(abs(avg2h) > 40 ? .orange : .green)
                            Text("mg/dL")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Glucose Outcomes")
            }
        }
    }

    // MARK: - Matched Meals List

    @ViewBuilder
    private var matchedMealsSection: some View {
        Section {
            ForEach(matchedMeals.reversed()) { meal in
                mealAnalysisRow(meal)
            }
        } header: {
            Text("Individual Meals")
        }
    }

    @ViewBuilder
    private func mealAnalysisRow(_ meal: MatchedMealAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Date and time
            HStack {
                Text(meal.date, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(meal.date, style: .time)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(Int(meal.estimationRatio * 100))%")
                    .font(.headline)
                    .foregroundColor(meal.estimationRatio < 0.5 ? .red : meal.estimationRatio < 0.8 ? .orange : .green)
            }

            // Carb comparison
            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Entered")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(Int(meal.trioCarbs))g")
                        .font(.subheadline)
                }
                VStack(alignment: .leading) {
                    Text("Actual")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(Int(meal.actualCarbs))g")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                VStack(alignment: .leading) {
                    Text("Missed")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(Int(meal.missedCarbs))g")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }
                Spacer()
                if meal.bolusInsulin > 0 {
                    VStack(alignment: .trailing) {
                        Text("Bolus")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.1f", meal.bolusInsulin))U")
                            .font(.subheadline)
                    }
                }
            }

            // Macros from Cronometer
            HStack(spacing: 12) {
                Text("C:\(Int(meal.actualCarbPercent))%")
                    .foregroundColor(.orange)
                Text("F:\(Int(meal.actualFatPercent))%")
                    .foregroundColor(.yellow)
                Text("P:\(Int(meal.actualProteinPercent))%")
                    .foregroundColor(.red)
                Spacer()
                if let rise = meal.bgRise {
                    Text("BG +\(rise)")
                        .foregroundColor(rise > 60 ? .red : rise > 40 ? .orange : .green)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statCard(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    private func runAnalysis() {
        let service = resolver.resolve(NutritionAnalysisService.self)!
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let result = try await service.runAnalysis(days: analysisDays)
                await MainActor.run {
                    matchedMeals = result.meals
                    summary = result.summary
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}
