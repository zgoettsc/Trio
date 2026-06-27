import SwiftUI
import Swinject

/// Settings screen for tuning the live 3-phase meal classifier. See
/// `docs/MEAL_INTELLIGENCE_DESIGN.md` §4 for the rule. Defaults are seeded
/// from the Round-9 Indian-food case where the classifier-if-it-had-existed
/// would have fired at the right moment.
///
/// Pattern mirrors EatingModeTuningView — each section has trade-off footer
/// text; values persist in TrioSettings via WritableKeyPath one-liner saves.
struct MealClassifierRulesView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    @StateObject private var vm = ViewModel()

    var body: some View {
        Form {
            // MARK: Master switch
            Section(
                header: Text("Live Classifier"),
                footer: Text(
                    "Watches BG during an active meal window for a three-phase pattern (initial rise → stable recovery → late re-rise). When the late re-rise pattern fires it upgrades the window to Complex, extends to the maximum duration, and enables phantom-COB injection. Designed for fat-heavy meals (Indian, pizza, Chinese) whose absorption outlasts the default 4-hour extended window."
                )
            ) {
                Toggle("Enable classifier", isOn: $vm.enabled)
                    .onChange(of: vm.enabled) { _, v in vm.save(\.mealClassifierEnabled, v) }
            }
            .listRowBackground(Color.chart)

            if vm.enabled {
                // MARK: Phase 1
                Section(
                    header: Text("Phase 1 — Initial Carb Climb"),
                    footer: Text(
                        "Detects the meal's first BG rise. Either a sustained Δ above threshold for N consecutive readings, OR a total rise above the absolute mg/dL threshold. Looser values catch more meals; tighter values reduce false positives from noise or activity."
                    )
                ) {
                    decimalSlider(
                        label: "Δ threshold (mg/dL/5min)",
                        value: $vm.phase1Delta,
                        range: 1 ... 4,
                        step: 0.5,
                        format: "%.1f"
                    ) { vm.save(\.mealClassifierPhase1DeltaThreshold, $0) }

                    decimalSlider(
                        label: "Sustained readings",
                        value: $vm.phase1Sustained,
                        range: 2 ... 5,
                        step: 1,
                        format: "%.0f"
                    ) { vm.save(\.mealClassifierPhase1SustainedReadings, $0) }

                    decimalSlider(
                        label: "Absolute rise (mg/dL)",
                        value: $vm.phase1AbsoluteRise,
                        range: 10 ... 30,
                        step: 1,
                        format: "%.0f"
                    ) { vm.save(\.mealClassifierPhase1AbsoluteRiseMgdL, $0) }
                }
                .listRowBackground(Color.chart)

                // MARK: Phase 2
                Section(
                    header: Text("Phase 2 — Recovery"),
                    footer: Text(
                        "Required gateway to Phase 3. BG must return to within ±range of baseline (min of activation BG and the post-Phase-1 trough) and stay there for N minutes. Without this gate, a continuous climb would falsely trigger Complex without ever showing the recovery-then-late-rise signature."
                    )
                ) {
                    decimalSlider(
                        label: "BG range from baseline (±mg/dL)",
                        value: $vm.phase2Range,
                        range: 10 ... 40,
                        step: 1,
                        format: "%.0f"
                    ) { vm.save(\.mealClassifierPhase2RangeMgdL, $0) }

                    decimalSlider(
                        label: "Min stable duration (min)",
                        value: $vm.phase2MinDuration,
                        range: 15 ... 60,
                        step: 5,
                        format: "%.0f"
                    ) { vm.save(\.mealClassifierPhase2MinDurationMinutes, $0) }
                }
                .listRowBackground(Color.chart)

                // MARK: Phase 3
                Section(
                    header: Text("Phase 3 — Late Fat/Protein Onset"),
                    footer: Text(
                        "Triggers Complex upgrade. After Phase 2 has stabilized, BG must climb at Δ above threshold sustained for N minutes, with no carb entry in the exclusion window (otherwise it's a snack, not late fat). Carb exclusion only matters if you log carbs — the zero-entry flow ignores it."
                    )
                ) {
                    decimalSlider(
                        label: "Δ threshold (mg/dL/5min)",
                        value: $vm.phase3Delta,
                        range: 1 ... 4,
                        step: 0.5,
                        format: "%.1f"
                    ) { vm.save(\.mealClassifierPhase3DeltaThreshold, $0) }

                    decimalSlider(
                        label: "Sustained duration (min)",
                        value: $vm.phase3Sustained,
                        range: 10 ... 30,
                        step: 5,
                        format: "%.0f"
                    ) { vm.save(\.mealClassifierPhase3SustainedDurationMinutes, $0) }

                    decimalSlider(
                        label: "Carb entry exclusion (min)",
                        value: $vm.phase3CarbExclusion,
                        range: 15 ... 60,
                        step: 5,
                        format: "%.0f"
                    ) { vm.save(\.mealClassifierPhase3CarbExclusionMinutes, $0) }
                }
                .listRowBackground(Color.chart)

                // MARK: Effects on upgrade
                Section(
                    header: Text("On Complex Upgrade"),
                    footer: Text(
                        "When the rule fires: the window's total duration is extended (from activation) to the max below, and phantom COB is enabled for the rest of the window at the configured dose. Max duration is bounded — you can always Cancel via the eating-mode pill if you want to exit early."
                    )
                ) {
                    decimalSlider(
                        label: "Max total window duration (min)",
                        value: $vm.maxTotalDuration,
                        range: 360 ... 720,
                        step: 30,
                        format: "%.0f"
                    ) { vm.save(\.mealClassifierMaxTotalDurationMinutes, $0) }

                    decimalSlider(
                        label: "Phantom COB on upgrade (g)",
                        value: $vm.phantomCOBGramsOnUpgrade,
                        range: 0 ... 40,
                        step: 5,
                        format: "%.0f"
                    ) { vm.save(\.mealClassifierPhantomCOBGramsOnUpgrade, $0) }
                }
                .listRowBackground(Color.chart)
            }

            // MARK: Reset to defaults
            Section(footer: Text("Resets every classifier knob to the shipped defaults seeded from Round-9 telemetry analysis. Doesn't touch other Trio preferences.")) {
                Button(role: .destructive) { vm.resetToDefaults() } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset to Defaults")
                    }
                }
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Classification Rules")
        .onAppear { vm.reload() }
    }

    @ViewBuilder
    private func decimalSlider(
        label: String,
        value: Binding<Decimal>,
        range: ClosedRange<Double>,
        step: Double,
        format: String,
        onCommit: @escaping (Decimal) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, NSDecimalNumber(decimal: value.wrappedValue).doubleValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { NSDecimalNumber(decimal: value.wrappedValue).doubleValue },
                    set: { value.wrappedValue = Decimal($0); onCommit(value.wrappedValue) }
                ),
                in: range,
                step: step
            )
        }
    }
}

@MainActor
private final class ViewModel: ObservableObject {
    @Published var enabled: Bool = true
    @Published var phase1Delta: Decimal = 2
    @Published var phase1Sustained: Decimal = 3
    @Published var phase1AbsoluteRise: Decimal = 15
    @Published var phase2Range: Decimal = 20
    @Published var phase2MinDuration: Decimal = 30
    @Published var phase3Delta: Decimal = 2
    @Published var phase3Sustained: Decimal = 15
    @Published var phase3CarbExclusion: Decimal = 30
    @Published var maxTotalDuration: Decimal = 600
    @Published var phantomCOBGramsOnUpgrade: Decimal = 20

    private let resolver: Resolver = TrioApp.resolver
    private lazy var settingsManager: SettingsManager? = resolver.resolve(SettingsManager.self)

    func reload() {
        guard let s = settingsManager?.settings else { return }
        enabled = s.mealClassifierEnabled
        phase1Delta = s.mealClassifierPhase1DeltaThreshold
        phase1Sustained = s.mealClassifierPhase1SustainedReadings
        phase1AbsoluteRise = s.mealClassifierPhase1AbsoluteRiseMgdL
        phase2Range = s.mealClassifierPhase2RangeMgdL
        phase2MinDuration = s.mealClassifierPhase2MinDurationMinutes
        phase3Delta = s.mealClassifierPhase3DeltaThreshold
        phase3Sustained = s.mealClassifierPhase3SustainedDurationMinutes
        phase3CarbExclusion = s.mealClassifierPhase3CarbExclusionMinutes
        maxTotalDuration = s.mealClassifierMaxTotalDurationMinutes
        phantomCOBGramsOnUpgrade = s.mealClassifierPhantomCOBGramsOnUpgrade
    }

    func save<Value>(_ keyPath: WritableKeyPath<TrioSettings, Value>, _ newValue: Value) {
        guard var s = settingsManager?.settings else { return }
        s[keyPath: keyPath] = newValue
        settingsManager?.settings = s
    }

    func resetToDefaults() {
        guard var s = settingsManager?.settings else { return }
        s.mealClassifierEnabled = true
        s.mealClassifierPhase1DeltaThreshold = 2
        s.mealClassifierPhase1SustainedReadings = 3
        s.mealClassifierPhase1AbsoluteRiseMgdL = 15
        s.mealClassifierPhase2RangeMgdL = 20
        s.mealClassifierPhase2MinDurationMinutes = 30
        s.mealClassifierPhase3DeltaThreshold = 2
        s.mealClassifierPhase3SustainedDurationMinutes = 15
        s.mealClassifierPhase3CarbExclusionMinutes = 30
        s.mealClassifierMaxTotalDurationMinutes = 600
        s.mealClassifierPhantomCOBGramsOnUpgrade = 20
        settingsManager?.settings = s
        reload()
    }
}
