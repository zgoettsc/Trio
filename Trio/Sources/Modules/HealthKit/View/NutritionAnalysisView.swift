import SwiftUI
import Swinject

struct NutritionAnalysisView: View {
    let resolver: Resolver

    @State private var matchedDays: [MatchedMealAnalysis] = []
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
                            Text("Analyzing \(analysisDays) days of nutrition data...")
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

                icrAnalysisSection(summary)

                bgOutcomesSection(summary)

                matchedDaysSection
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("This analysis compares your daily Trio carb entries with actual nutrition data from Apple Health (Cronometer) to understand your carb estimation patterns.")
                            .font(.callout)
                        Text("It matches days where both Trio and Cronometer have data, calculates how much you typically under- or over-estimate daily carbs, and shows daily BG averages.")
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
                    statCard("Matched Days", value: "\(summary.totalMatchedDays)")
                    statCard("Avg Ratio", value: "\(Int(summary.averageEstimationRatio * 100))%")
                    statCard("Avg Entered", value: "\(Int(summary.averageTrioCarbs))g/day")
                    statCard("Avg Actual", value: "\(Int(summary.averageActualCarbs))g/day")
                    statCard("Avg Missed", value: "\(Int(summary.averageMissedCarbs))g/day")
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
            if summary.unmatchedTrioDays > 0 || summary.unmatchedHealthDays > 0 {
                Text("\(summary.unmatchedTrioDays) Trio-only days and \(summary.unmatchedHealthDays) Cronometer-only days could not be matched.")
            }
        }
    }

    // MARK: - ICR Analysis Section

    @ViewBuilder
    private func icrAnalysisSection(_ summary: NutritionAnalysisSummary) -> some View {
        Group {
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
    }

    // MARK: - BG Outcomes Section

    @ViewBuilder
    private func bgOutcomesSection(_ summary: NutritionAnalysisSummary) -> some View {
        Group {
            if let avgBG = summary.averageDailyBG {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "waveform.path.ecg")
                                .foregroundColor(.red)
                            Text("Daily BG Summary")
                                .font(.headline)
                        }

                        HStack(spacing: 24) {
                            VStack {
                                Text("Avg Daily BG")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(avgBG)")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(avgBG > 180 ? .red : avgBG > 140 ? .orange : .green)
                                Text("mg/dL")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            if let avgMax = summary.averageDailyMaxBG {
                                VStack {
                                    Text("Avg Daily Max")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("\(avgMax)")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                        .foregroundColor(avgMax > 250 ? .red : avgMax > 180 ? .orange : .green)
                                    Text("mg/dL")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Glucose Outcomes")
                } footer: {
                    Text("Average BG and daily peak across matched days.")
                }
            }
        }
    }

    // MARK: - Matched Days List

    @ViewBuilder
    private var matchedDaysSection: some View {
        Section {
            ForEach(matchedDays) { day in
                dayAnalysisRow(day)
            }
        } header: {
            Text("Daily Comparison")
        }
    }

    @ViewBuilder
    private func dayAnalysisRow(_ day: MatchedMealAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Day header
            HStack {
                Text(day.dayDescription)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(Int(day.estimationRatio * 100))%")
                    .font(.headline)
                    .foregroundColor(day.estimationRatio < 0.5 ? .red : day.estimationRatio < 0.8 ? .orange : .green)
            }

            // Carb comparison
            HStack(spacing: 16) {
                VStack(alignment: .leading) {
                    Text("Entered")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(Int(day.trioCarbs))g")
                        .font(.subheadline)
                }
                VStack(alignment: .leading) {
                    Text("Actual")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(Int(day.actualCarbs))g")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                VStack(alignment: .leading) {
                    Text("Missed")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(Int(day.missedCarbs))g")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }
                Spacer()
                if day.bolusInsulin > 0 {
                    VStack(alignment: .trailing) {
                        Text("Bolus")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(String(format: "%.1f", day.bolusInsulin))U")
                            .font(.subheadline)
                    }
                }
            }

            // Macros from Cronometer + daily BG
            HStack(spacing: 12) {
                Text("C:\(Int(day.actualCarbPercent))%")
                    .foregroundColor(.orange)
                Text("F:\(Int(day.actualFatPercent))%")
                    .foregroundColor(.yellow)
                Text("P:\(Int(day.actualProteinPercent))%")
                    .foregroundColor(.red)
                Spacer()
                if let avg = day.averageBG {
                    Text("Avg \(avg)")
                        .foregroundColor(avg > 180 ? .red : avg > 140 ? .orange : .green)
                }
                if let peak = day.maxBG {
                    Text("Max \(peak)")
                        .foregroundColor(peak > 250 ? .red : peak > 180 ? .orange : .green)
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
                    matchedDays = result.days
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
