import SwiftUI

/// V2 Dose Preview — Step 2 of the V2 treatment flow.
/// Shows a two-line BG forecast, treatment plan summary, adjustable sliders, and confirm button.
struct V2DosePreviewView: View {
    @Bindable var state: Treatments.StateModel
    let combinedCarbs: Double
    let combinedFat: Double
    let combinedProtein: Double
    let combinedFiber: Double
    let selectedMeals: [V2DetectedMeal]
    let onBack: () -> Void
    let onSwitchToV1: () -> Void

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    @State private var showAdjustments = false
    @State private var upfrontPercent: Double = 0.20
    @State private var demandOverride: Double = 1.0
    @State private var approach: DosingApproach = .normal
    @State private var showConfirmDialog = false

    enum DosingApproach: String, CaseIterable {
        case conservative = "Conservative"
        case normal = "Normal"
        case aggressive = "Aggressive"
    }

    /// Computed upfront bolus from carbs and current carb ratio
    private var upfrontGrams: Double {
        combinedCarbs * upfrontPercent
    }

    private var upfrontUnits: Double {
        let cr = Double(truncating: state.carbRatio as NSDecimalNumber)
        guard cr > 0 else { return 0 }
        return upfrontGrams / cr
    }

    /// Remaining carbs that will be delivered via SMBs
    private var smbGrams: Double {
        combinedCarbs * (1.0 - upfrontPercent)
    }

    /// Estimated protein glucose-equivalent using engine defaults
    private var proteinEquiv: Double {
        MacroAbsorptionEngine.proteinGlucoFactor(proteinGrams: combinedProtein) * combinedProtein
    }

    /// Estimated fat carb-equivalent
    private var fatEquiv: Double {
        MacroAbsorptionEngine.fatCarbEquivalent(fatGrams: combinedFat)
    }

    /// Total effective carb coverage
    private var totalCoverage: Double {
        combinedCarbs + proteinEquiv + fatEquiv
    }

    /// Whether any selected meal is late (>1h old)
    private var lateMeal: V2DetectedMeal? {
        selectedMeals.first(where: { $0.isLate })
    }

    /// The meal label for display
    private var mealLabel: String {
        if selectedMeals.isEmpty { return "Correction" }
        if selectedMeals.count == 1 { return selectedMeals[0].label }
        return selectedMeals.map(\.label).joined(separator: " + ")
    }

    private var formatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        return f
    }

    var body: some View {
        List {
            // Late meal warning
            if let late = lateMeal {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Late meal: \(late.label)")
                                .font(.subheadline.weight(.medium))
                            Text(
                                String(
                                    format: "%.0f min ago. The engine has adjusted the treatment plan for already-absorbed carbs.",
                                    late.minutesAgo
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.orange.opacity(0.1))
            }

            // Meal summary
            Section(header: Text(mealLabel)) {
                HStack(spacing: 16) {
                    macroBlock("Carbs", value: combinedCarbs, unit: "g", color: .orange)
                    macroBlock("Fat", value: combinedFat, unit: "g", color: .yellow)
                    macroBlock("Protein", value: combinedProtein, unit: "g", color: .red)
                    if combinedFiber > 0 {
                        macroBlock("Fiber", value: combinedFiber, unit: "g", color: .green)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.chart)

            // BG Forecast Chart — two-line design
            Section {
                V2ForecastChart(state: state)
                    .frame(height: 200)
                    .padding(.vertical, 4)
            }
            .listRowBackground(Color.chart)

            // Treatment plan
            Section(header: Text("Treatment Plan")) {
                HStack {
                    Text("Bolus now")
                    Spacer()
                    Text(String(format: "%.1f U (%.0fg)", upfrontUnits, upfrontGrams))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Via SMBs")
                    Spacer()
                    Text(String(format: "%.0fg over ~%.0fh", smbGrams, estimatedSMBDuration))
                        .foregroundStyle(.secondary)
                }

                if proteinEquiv > 1 {
                    HStack {
                        Text("Protein")
                        Spacer()
                        Text(String(format: "+%.1fg equiv / 1.5-8h", proteinEquiv))
                            .foregroundStyle(.secondary)
                    }
                }

                if fatEquiv > 1 {
                    HStack {
                        Text("Fat")
                        Spacer()
                        Text(String(format: "+%.1fg equiv / 2-9h", fatEquiv))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Total coverage")
                        .fontWeight(.medium)
                    Spacer()
                    Text(String(format: "%.0fg equiv", totalCoverage))
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.chart)

            // Garmin demand factor (if active)
            if state.v2DemandFactor != 1.0 {
                Section {
                    HStack {
                        Image(systemName: "applewatch")
                            .foregroundStyle(.teal)
                        Text(String(format: "Garmin: %.1fx demand", state.v2DemandFactor))
                        Spacer()
                        if let topContrib = state.v2DemandContributions.first {
                            Text(topContrib.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.chart)
            }

            // Adjustments (collapsed by default)
            Section(header: HStack {
                Text("Adjustments")
                Spacer()
                Button(showAdjustments ? "Hide" : "Show") {
                    withAnimation { showAdjustments.toggle() }
                }
                .font(.caption)
                .textCase(nil)
            }) {
                if showAdjustments {
                    // Upfront bolus slider
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Upfront bolus")
                            Spacer()
                            Text(String(format: "%.0f%%", upfrontPercent * 100))
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)

                        Slider(value: $upfrontPercent, in: 0.0 ... 1.0, step: 0.05)
                            .onChange(of: upfrontPercent) { _, _ in
                                recalculate()
                            }

                        HStack {
                            Text("Bolus: \(String(format: "%.1fU", upfrontUnits))")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                            Spacer()
                            Text("SMBs: \(String(format: "%.0fg", smbGrams))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Demand override
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Demand override")
                            Spacer()
                            Text(String(format: "%.1fx", demandOverride))
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)

                        Slider(value: $demandOverride, in: 0.6 ... 1.7, step: 0.1)
                            .onChange(of: demandOverride) { _, _ in
                                recalculate()
                            }
                    }

                    // Approach picker
                    Picker("Approach", selection: $approach) {
                        ForEach(DosingApproach.allCases, id: \.self) { a in
                            Text(a.rawValue).tag(a)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: approach) { _, newApproach in
                        applyApproach(newApproach)
                    }
                }
            }
            .listRowBackground(Color.chart)

            // Bolus entry
            Section {
                HStack {
                    Text("Bolus")
                    Spacer()
                    Text(String(format: "%.1f U", Double(truncating: state.amount as NSDecimalNumber)))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(colorScheme == .dark ? .white : .blue)

                    Button("Use Rec.") {
                        state.amount = state.insulinCalculated
                    }
                    .font(.caption)
                    .disabled(state.amount == state.insulinCalculated || state.insulinCalculated == 0)
                    .buttonStyle(.bordered)
                }

                HStack {
                    Text("External Insulin")
                    Spacer()
                    Toggle("", isOn: $state.externalInsulin).toggleStyle(CheckboxToggleStyle())
                }
            }
            .listRowBackground(Color.chart)

            // Confirm button
            Section {
                Button {
                    if shouldConfirm {
                        showConfirmDialog = true
                    } else {
                        state.invokeTreatmentsTask()
                    }
                } label: {
                    Text("Confirm & Deliver")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 35)
                }
                .disabled(disableConfirm)
                .listRowBackground(disableConfirm ? Color.gray : Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .confirmationDialog(
                    lowBGWarning,
                    isPresented: $showConfirmDialog,
                    titleVisibility: .visible
                ) {
                    Button("Cancel", role: .cancel) {}
                    Button("Deliver Anyway", role: .destructive) {
                        state.invokeTreatmentsTask()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Dose Preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back") { onBack() }
            }
        }
        .onAppear {
            initializeDefaults()
        }
    }

    // MARK: - Helpers

    private var estimatedSMBDuration: Double {
        // Rough estimate based on tau
        let tau = state.v2TauCarb ?? 35
        return min(8, tau * 4.74 / 60) // 95% absorption duration in hours
    }

    private var shouldConfirm: Bool {
        state.confirmBolus && (state.currentBG < 54 || state.minPredBG < 54) && state.amount > 0 && !state.externalInsulin
    }

    private var lowBGWarning: String {
        state.currentBG < 54 ? "Glucose is very low. Deliver \(state.amount) U?" :
            state.minPredBG < 54 ? "Glucose forecast is very low. Deliver \(state.amount) U?" : ""
    }

    private var disableConfirm: Bool {
        state.amount <= 0 && state.carbs <= 0 && state.fat <= 0 && state.protein <= 0
    }

    private func initializeDefaults() {
        // Set upfront percent from V2 engine suggestion
        upfrontPercent = state.v2CurveSuggestedPercent ?? 0.20
        demandOverride = state.v2DemandFactor
        state.amount = state.insulinCalculated
    }

    private func recalculate() {
        // Apply upfront percent change back to state
        state.v2UpfrontPercentOverride = upfrontPercent
        let newUpfrontCarbs = combinedCarbs * upfrontPercent
        state.carbs = Decimal(newUpfrontCarbs)

        Task {
            await state.updateForecasts()
            state.insulinCalculated = await state.calculateInsulin()
            state.amount = state.insulinCalculated
        }
    }

    private func applyApproach(_ approach: DosingApproach) {
        switch approach {
        case .conservative:
            upfrontPercent = max(0.05, (state.v2CurveSuggestedPercent ?? 0.20) - 0.10)
            demandOverride = min(demandOverride, 1.0)
        case .normal:
            upfrontPercent = state.v2CurveSuggestedPercent ?? 0.20
            demandOverride = state.v2DemandFactor
        case .aggressive:
            upfrontPercent = min(1.0, (state.v2CurveSuggestedPercent ?? 0.20) + 0.10)
            demandOverride = state.v2DemandFactor
        }
        recalculate()
    }

    private func macroBlock(_ label: String, value: Double, unit: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(Int(value))\(unit)")
                .font(.subheadline.weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(color)
        }
    }
}
