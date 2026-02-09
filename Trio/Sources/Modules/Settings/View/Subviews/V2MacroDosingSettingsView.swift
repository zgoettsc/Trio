import SwiftUI
import Swinject

/// Settings page for V2 Macro Absorption Engine, Garmin sensitivity, and outcome learning.
struct V2MacroDosingSettingsView: BaseView {
    let resolver: Resolver

    @ObservedObject var state: Settings.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    // Curve parameter state — loaded from V2OutcomeLearningStore on appear
    @State private var fatCoefficient: Double = 0.69
    @State private var proteinFactor: Double = 0.35
    @State private var proteinThreshold: Double = 15
    @State private var proteinPlateau: Double = 40
    @State private var carbTau: Double = 35
    @State private var fiberCoefficient: Double = 0.30

    // Track whether parameters have been customized (vs. defaults)
    @State private var paramsLoaded = false
    // Re-entrancy guard: prevents ping-pong between threshold/plateau onChange handlers
    @State private var isAdjustingProteinConstraints = false

    var body: some View {
        Form {
            // MARK: - Engine Toggle
            Section(header: Text("V2 Macro Engine")) {
                Toggle("Enable V2 Macro Absorption", isOn: $state.useV2MacroAbsorption)

                if state.useV2MacroAbsorption {
                    HStack {
                        Text("Insulin Type")
                        Spacer()
                        Picker("", selection: $state.insulinType) {
                            Text("Rapid Acting").tag("rapidActing")
                            Text("Ultra Rapid").tag("ultraRapid")
                        }
                        .pickerStyle(.menu)
                    }

                    HStack {
                        Text("Safe Window")
                        Spacer()
                        Text(safeWindowText)
                            .foregroundStyle(.secondary)
                    }

                    if state.v2SafeWindowOverride != nil {
                        Stepper(
                            "Override: \(state.v2SafeWindowOverride ?? 45) min",
                            value: Binding(
                                get: { state.v2SafeWindowOverride ?? 45 },
                                set: { state.v2SafeWindowOverride = $0 }
                            ),
                            in: 15 ... 90,
                            step: 5
                        )
                    }

                    Toggle("Custom Safe Window", isOn: Binding(
                        get: { state.v2SafeWindowOverride != nil },
                        set: { state.v2SafeWindowOverride = $0 ? 45 : nil }
                    ))

                    // MARK: Minimum Upfront Floor
                    HStack {
                        Text("Min Upfront Covered")
                        Spacer()
                        Text(String(format: "%.0f%%", NSDecimalNumber(decimal: state.v2MinUpfrontFloor).doubleValue * 100))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { NSDecimalNumber(decimal: state.v2MinUpfrontFloor).doubleValue },
                            set: { state.v2MinUpfrontFloor = Decimal($0) }
                        ),
                        in: 0.15 ... 0.70,
                        step: 0.05
                    )
                    insulinInfoBox(
                        increase: "More insulin upfront — use if you spike early after simple carb meals",
                        decrease: "Less insulin upfront — more aggressive splitting for all meals"
                    )

                    Text("Minimum upfront bolus percentage. Low-fat meals get up to 80%; this sets the floor for high-fat meals (≥50g fat). Default 25%.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.chart)

            // MARK: - Meal-Mode SMB
            if state.useV2MacroAbsorption {
                Section(header: Text("Meal-Mode SMB Enhancement")) {
                    HStack {
                        Text("SMB Multiplier")
                        Spacer()
                        Text(String(format: "%.1fx", NSDecimalNumber(decimal: state.mealModeSMBMultiplier).doubleValue))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { NSDecimalNumber(decimal: state.mealModeSMBMultiplier).doubleValue },
                            set: { state.mealModeSMBMultiplier = Decimal($0) }
                        ),
                        in: 1.0 ... 3.0,
                        step: 0.1
                    )
                    insulinInfoBox(
                        increase: "Larger SMBs after meals — more insulin delivered faster",
                        decrease: "Smaller SMBs after meals — less insulin delivered"
                    )

                    HStack {
                        Text("BG Floor for Activation")
                        Spacer()
                        Text("\(NSDecimalNumber(decimal: state.mealModeBGFloor).intValue) mg/dL")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { NSDecimalNumber(decimal: state.mealModeBGFloor).doubleValue },
                            set: { state.mealModeBGFloor = Decimal($0) }
                        ),
                        in: 70 ... 130,
                        step: 5
                    )
                    insulinInfoBox(
                        increase: "SMB enhancement activates at higher BG — less aggressive overall",
                        decrease: "SMB enhancement activates at lower BG — more aggressive overall"
                    )
                }
                .listRowBackground(Color.chart)

                // MARK: - Curve Parameters (Interactive Sliders)
                Section(header: Text("Fat Absorption")) {
                    HStack {
                        Text("Fat Coefficient")
                        Spacer()
                        Text(String(format: "%.2f g-equiv/g", fatCoefficient))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $fatCoefficient, in: 0.30 ... 1.20, step: 0.01)
                        .onChange(of: fatCoefficient) { _, newValue in
                            saveCurveParameter { $0.fatTotalCoeff = newValue }
                        }

                    insulinInfoBox(
                        increase: "More delayed insulin for fat — use if you spike 4-8h after fatty meals",
                        decrease: "Less delayed insulin for fat — use if you go low hours after fatty meals"
                    )
                }
                .listRowBackground(Color.chart)

                Section(header: Text("Protein Absorption")) {
                    HStack {
                        Text("Protein Factor")
                        Spacer()
                        Text(String(format: "%.2f", proteinFactor))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $proteinFactor, in: 0.10 ... 0.80, step: 0.01)
                        .onChange(of: proteinFactor) { _, newValue in
                            saveCurveParameter { $0.proteinFactor = newValue }
                        }

                    insulinInfoBox(
                        increase: "More delayed insulin for protein — use if high-protein meals raise your BG at 3-5h",
                        decrease: "Less delayed insulin for protein — use if you go low after high-protein meals"
                    )

                    HStack {
                        Text("Protein Threshold")
                        Spacer()
                        Text(String(format: "%.0fg", proteinThreshold))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $proteinThreshold, in: 5 ... 30, step: 1)
                        .onChange(of: proteinThreshold) { _, newValue in
                            guard !isAdjustingProteinConstraints else { return }
                            isAdjustingProteinConstraints = true
                            defer { isAdjustingProteinConstraints = false }
                            // S4: Ensure plateau stays above threshold
                            if newValue >= proteinPlateau {
                                proteinPlateau = min(newValue + 5, 80)
                                saveCurveParameter { $0.proteinPlateau = proteinPlateau }
                            }
                            saveCurveParameter { $0.proteinThreshold = newValue }
                        }

                    insulinInfoBox(
                        increase: "Less insulin — protein ignored until a higher amount (fewer meals trigger protein dosing)",
                        decrease: "More insulin — smaller protein amounts trigger extra dosing"
                    )

                    HStack {
                        Text("Protein Plateau")
                        Spacer()
                        Text(String(format: "%.0fg", proteinPlateau))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $proteinPlateau, in: 20 ... 80, step: 1)
                        .onChange(of: proteinPlateau) { _, newValue in
                            guard !isAdjustingProteinConstraints else { return }
                            isAdjustingProteinConstraints = true
                            defer { isAdjustingProteinConstraints = false }
                            // S4: Ensure threshold stays below plateau
                            if newValue <= proteinThreshold {
                                proteinThreshold = max(newValue - 5, 5)
                                saveCurveParameter { $0.proteinThreshold = proteinThreshold }
                            }
                            saveCurveParameter { $0.proteinPlateau = newValue }
                        }

                    insulinInfoBox(
                        increase: "Less insulin — conversion ramps up more slowly, needs more protein to reach full effect",
                        decrease: "More insulin — conversion hits maximum at a lower protein amount"
                    )
                }
                .listRowBackground(Color.chart)

                Section(header: Text("Carb Absorption")) {
                    HStack {
                        Text("Base Carb Tau")
                        Spacer()
                        Text(String(format: "%.0f min", carbTau))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $carbTau, in: 20 ... 60, step: 1)
                        .onChange(of: carbTau) { _, newValue in
                            saveCurveParameter { $0.carbTau = newValue }
                        }

                    insulinInfoBox(
                        increase: "Slower absorption — less insulin upfront, more via SMBs later. Use if you go low soon after eating",
                        decrease: "Faster absorption — more insulin upfront, less via SMBs. Use if you spike right after eating"
                    )
                }
                .listRowBackground(Color.chart)

                Section(header: Text("Fiber Effect")) {
                    HStack {
                        Text("Fiber Delay Coefficient")
                        Spacer()
                        Text(String(format: "%.2f min/g", fiberCoefficient))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $fiberCoefficient, in: 0.00 ... 1.00, step: 0.05)
                        .onChange(of: fiberCoefficient) { _, newValue in
                            saveCurveParameter { $0.fiberCoefficient = newValue }
                        }

                    insulinInfoBox(
                        increase: "More delay per gram of fiber — use if high-fiber meals absorb much slower for you",
                        decrease: "Less delay per gram of fiber — use if fiber doesn't noticeably slow your absorption"
                    )

                    Text("Fiber above 5g slows carb absorption by this many minutes per gram. At 0, fiber has no effect on tau.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.chart)

                // MARK: - Example Calculation
                Section(header: Text("Example: 65g Carbs, 28g Fat, 35g Protein, 12g Fiber")) {
                    let exProteinFactor = MacroAbsorptionEngine.proteinGlucoFactor(
                        proteinGrams: 35,
                        threshold: proteinThreshold,
                        plateau: proteinPlateau,
                        maxFactor: proteinFactor
                    )
                    let exProteinEquiv = 35 * exProteinFactor
                    let exFatEquiv = MacroAbsorptionEngine.fatCarbEquivalent(fatGrams: 28, maxCoeff: fatCoefficient)
                    let exTau = MacroAbsorptionEngine.carbTau(baseTau: carbTau, fatGrams: 28, fiberGrams: 12, fiberCoefficient: fiberCoefficient)
                    let exSafeWindow = Double(state.v2SafeWindowOverride ?? (state.insulinType == "ultraRapid" ? 30 : 45))
                    let exCDF = MacroAbsorptionEngine.gammaCDFValue(tau: exTau, atMinutes: exSafeWindow)
                    let exFloorVal = NSDecimalNumber(decimal: state.v2MinUpfrontFloor).doubleValue
                    let exFatMin = MacroAbsorptionEngine.fatScaledMinUpfront(fatGrams: 28, floor: exFloorVal)
                    let exUpfrontPct = max(exCDF, exFatMin)

                    HStack {
                        Text("Upfront bolus")
                        Spacer()
                        Text(String(format: "%.1fg of 65g (%.0f%%)", 65 * exUpfrontPct, exUpfrontPct * 100))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("  CDF at safe window")
                        Spacer()
                        Text(String(format: "%.1f%%", exCDF * 100))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)

                    HStack {
                        Text("  Fat-scaled floor")
                        Spacer()
                        Text(String(format: "%.1f%% (28g fat)", exFatMin * 100))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)

                    HStack {
                        Text("Protein glucose-equiv")
                        Spacer()
                        Text(String(format: "%.1fg (%.0f%% of 35g)", exProteinEquiv, exProteinFactor * 100))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Fat carb-equiv")
                        Spacer()
                        Text(String(format: "%.1fg", exFatEquiv))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Total delayed impact")
                        Spacer()
                        Text(String(format: "%.1fg over 8h", exProteinEquiv + exFatEquiv))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Fat+fiber-modified tau")
                        Spacer()
                        Text(String(format: "%.0f min", exTau))
                            .foregroundStyle(.secondary)
                    }

                    let exFiberDelay = max(0, 12.0 - 5.0) * fiberCoefficient
                    HStack {
                        Text("Fiber delay contribution")
                        Spacer()
                        Text(String(format: "+%.1f min (from 12g fiber)", exFiberDelay))
                            .foregroundStyle(.secondary)
                    }

                    Text("This shows how your current settings would calculate a meal with 65g carbs, 28g fat, 35g protein, and 12g fiber.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.chart)

                // MARK: - Reset & History (critique item #9)
                Section(header: Text("Parameter Management")) {
                    Button("Reset Curve Parameters to Defaults") {
                        V2OutcomeLearningStore.shared.saveParametersWithHistory(
                            V2PersonalCurveParameters(), source: "reset"
                        )
                        loadCurveParameters()
                    }
                    .foregroundStyle(.red)

                    let history = V2OutcomeLearningStore.shared.loadParameterHistory()
                    if !history.isEmpty {
                        DisclosureGroup("Parameter History (\(history.count))") {
                            ForEach(Array(history.enumerated()), id: \.offset) { _, snapshot in
                                Button {
                                    V2OutcomeLearningStore.shared.rollbackToSnapshot(snapshot)
                                    loadCurveParameters()
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(snapshot.date, style: .date)
                                            Text(snapshot.date, style: .time)
                                            Spacer()
                                            Text(snapshot.source)
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(.quaternary)
                                                .clipShape(Capsule())
                                        }
                                        .font(.caption)
                                        HStack(spacing: 12) {
                                            Text("tau:\(String(format: "%.0f", snapshot.parameters.effectiveCarbTau))")
                                            Text("prot:\(String(format: "%.2f", snapshot.parameters.effectiveProteinFactor))")
                                            Text("fat:\(String(format: "%.2f", snapshot.parameters.effectiveFatTotalCoeff))")
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .listRowBackground(Color.chart)

                // MARK: - Garmin Sensitivity
                Section(header: Text("Garmin Sensitivity")) {
                    Toggle("Enable Garmin Adjustment", isOn: $state.garminEnabled)

                    if state.garminEnabled {
                        if GarminFirebaseConstants.isConfigured {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Firebase configured")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                Text("Firebase secrets not injected")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }

                        Text("Garmin Health Data").navigationLink(to: .garminFirestoreStatus, from: self)
                    }
                }
                .listRowBackground(Color.chart)

                // MARK: - Outcome Learning
                Section(header: Text("Outcome Learning")) {
                    Toggle("Record Meal Outcomes", isOn: $state.v2OutcomeLearningEnabled)

                    if state.v2OutcomeLearningEnabled {
                        let outcomes = V2OutcomeLearningStore.shared.loadAll()
                        HStack {
                            Text("Recorded Meals")
                            Spacer()
                            Text("\(outcomes.count)")
                                .foregroundStyle(.secondary)
                        }

                        let withCheckpoints = outcomes.filter { $0.checkpoints.contains(where: { $0.bgValue != nil }) }
                        HStack {
                            Text("With BG Data")
                            Spacer()
                            Text("\(withCheckpoints.count)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Claude AI Recalibration", isOn: $state.claudeRecalibrationEnabled)

                    if state.claudeRecalibrationEnabled {
                        HStack {
                            Text("Analysis Window")
                            Spacer()
                            Picker("", selection: $state.recalibrationWindowDays) {
                                Text("7 days").tag(7)
                                Text("14 days").tag(14)
                                Text("21 days").tag(21)
                                Text("30 days").tag(30)
                            }
                            .pickerStyle(.menu)
                        }

                        Text("Longer windows give Claude more data points for pattern detection but may include stale context after setting changes. Default 14 days.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.chart)

                // MARK: - Accuracy Analysis
                Section(header: Text("Analysis")) {
                    Text("Meal Outcome Accuracy").navigationLink(to: .v2OutcomeAnalysis, from: self)
                }
                .listRowBackground(Color.chart)
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("V2 Macro Dosing")
        .navigationBarTitleDisplayMode(.automatic)
        .onAppear {
            configureView()
            loadCurveParameters()
        }
    }

    // MARK: - Helpers

    private var safeWindowText: String {
        if let override = state.v2SafeWindowOverride {
            return "\(override) min (custom)"
        }
        return state.insulinType == "ultraRapid" ? "30 min (ultra rapid)" : "45 min (rapid acting)"
    }

    private func loadCurveParameters() {
        let params = V2OutcomeLearningStore.shared.loadParameters()
        fatCoefficient = params.effectiveFatTotalCoeff
        proteinFactor = params.effectiveProteinFactor
        proteinThreshold = params.effectiveProteinThreshold
        proteinPlateau = params.effectiveProteinPlateau
        carbTau = params.effectiveCarbTau
        fiberCoefficient = params.effectiveFiberCoefficient
        paramsLoaded = true
    }

    private func saveCurveParameter(_ update: (inout V2PersonalCurveParameters) -> Void) {
        guard paramsLoaded else { return }
        var params = V2OutcomeLearningStore.shared.loadParameters()
        update(&params)
        V2OutcomeLearningStore.shared.saveParameters(params)
    }

    private func insulinInfoBox(increase: String, decrease: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(increase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.cyan)
                    .font(.caption)
                Text(decrease)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
