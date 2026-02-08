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

    // Track whether parameters have been customized (vs. defaults)
    @State private var paramsLoaded = false

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
                    Slider(value: $fatCoefficient, in: 0.30 ... 2.00, step: 0.01)
                        .onChange(of: fatCoefficient) { _, newValue in
                            saveCurveParameter { $0.fatTotalCoeff = newValue }
                        }

                    Text("How much extra insulin fat requires. Higher values increase delayed insulin for fatty meals. Based on Wolpert 2013 (default 0.69).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                    Text("Peak fraction of protein converted to glucose via gluconeogenesis. Research range: 0.20-0.60 for most people.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Protein Threshold")
                        Spacer()
                        Text(String(format: "%.0fg", proteinThreshold))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $proteinThreshold, in: 5 ... 30, step: 1)
                        .onChange(of: proteinThreshold) { _, newValue in
                            saveCurveParameter { $0.proteinThreshold = newValue }
                        }

                    Text("Minimum protein grams before gluconeogenesis kicks in. Below this, protein has no BG effect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Protein Plateau")
                        Spacer()
                        Text(String(format: "%.0fg", proteinPlateau))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $proteinPlateau, in: 20 ... 80, step: 1)
                        .onChange(of: proteinPlateau) { _, newValue in
                            saveCurveParameter { $0.proteinPlateau = newValue }
                        }

                    Text("Protein grams at which conversion plateaus at max factor. Above this, more protein doesn't increase the conversion rate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                    Text("Base time constant for carb absorption. Higher = slower absorption. Fat adds 0.8 min per gram on top of this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.chart)

                // MARK: - Example Calculation
                Section(header: Text("Example: 65g Carbs, 28g Fat, 35g Protein")) {
                    let exProteinFactor = MacroAbsorptionEngine.proteinGlucoFactor(
                        proteinGrams: 35,
                        threshold: proteinThreshold,
                        plateau: proteinPlateau,
                        maxFactor: proteinFactor
                    )
                    let exProteinEquiv = 35 * exProteinFactor
                    let exFatEquiv = 28 * fatCoefficient
                    let exTau = MacroAbsorptionEngine.carbTau(baseTau: carbTau, fatGrams: 28)

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
                        Text("Fat-modified tau")
                        Spacer()
                        Text(String(format: "%.0f min", exTau))
                            .foregroundStyle(.secondary)
                    }

                    Text("This shows how your current settings would calculate a meal with 65g carbs, 28g fat, and 35g protein.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.chart)

                // MARK: - Reset
                Section {
                    Button("Reset Curve Parameters to Defaults") {
                        let defaults = V2PersonalCurveParameters()
                        V2OutcomeLearningStore.shared.saveParameters(defaults)
                        loadCurveParameters()
                    }
                    .foregroundStyle(.red)
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
        paramsLoaded = true
    }

    private func saveCurveParameter(_ update: (inout V2PersonalCurveParameters) -> Void) {
        guard paramsLoaded else { return }
        var params = V2OutcomeLearningStore.shared.loadParameters()
        update(&params)
        V2OutcomeLearningStore.shared.saveParameters(params)
    }
}
