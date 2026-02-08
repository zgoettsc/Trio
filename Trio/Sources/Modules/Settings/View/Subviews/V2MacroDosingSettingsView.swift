import SwiftUI
import Swinject

/// Settings page for V2 Macro Absorption Engine, Garmin sensitivity, and outcome learning.
struct V2MacroDosingSettingsView: BaseView {
    let resolver: Resolver

    @ObservedObject var state: Settings.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

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

                // MARK: - Learned Parameters
                Section(header: Text("Learned Parameters")) {
                    let params = V2OutcomeLearningStore.shared.loadParameters()
                    paramRow("Carb Tau", value: params.carbTau, defaultVal: 35, unit: "min")
                    paramRow("Protein Factor", value: params.proteinFactor, defaultVal: 0.35, unit: "")
                    paramRow("Fat Coefficient", value: params.fatTotalCoeff, defaultVal: 0.69, unit: "")
                    paramRow("Protein Threshold", value: params.proteinThreshold, defaultVal: 15, unit: "g")
                    paramRow("Protein Plateau", value: params.proteinPlateau, defaultVal: 40, unit: "g")

                    Button("Reset to Defaults") {
                        V2OutcomeLearningStore.shared.saveParameters(V2PersonalCurveParameters())
                    }
                    .foregroundStyle(.red)
                }
                .listRowBackground(Color.chart)
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("V2 Macro Dosing")
        .navigationBarTitleDisplayMode(.automatic)
    }

    // MARK: - Helpers

    private var safeWindowText: String {
        if let override = state.v2SafeWindowOverride {
            return "\(override) min (custom)"
        }
        return state.insulinType == "ultraRapid" ? "30 min (ultra rapid)" : "45 min (rapid acting)"
    }

    private func paramRow(_ label: String, value: Double?, defaultVal: Double, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            if let v = value {
                Text(String(format: "%.2f%@", v, unit.isEmpty ? "" : " \(unit)"))
                    .foregroundStyle(.primary)
                Text("(learned)")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else {
                Text(String(format: "%.2f%@", defaultVal, unit.isEmpty ? "" : " \(unit)"))
                    .foregroundStyle(.secondary)
                Text("(default)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
