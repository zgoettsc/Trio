import SwiftUI
import Swinject

/// Settings screen for tuning how aggressively the loop treats a rise while a
/// meal window is active (PLAN.md items 1-6 + configurable tough-meal cap).
///
/// Each toggle has an inline trade-off note. The 9 settings persist in TrioSettings
/// and flow through TrioCustomOrefVariables to determine-basal.js.
struct EatingModeTuningView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    @StateObject private var vm = ViewModel()
    @State private var showAutoPhantomConfirm = false
    @State private var autoPhantomConfirmText = ""

    var body: some View {
        Form {
            // MARK: Item 1 — SMB ratio boost
            Section(
                header: Text("SMB Delivery Ratio"),
                footer: Text(
                    "Default oref delivers each SMB at 50% of the calculated insulinReq. Boosting to 80% inside a meal window roughly doubles per-pass coverage. Trade-off: faster coverage of real meals; more aggressive correction if window pressed without actually eating."
                )
            ) {
                Toggle("Boost SMB ratio in meal window", isOn: $vm.boostSMBRatio)
                    .onChange(of: vm.boostSMBRatio) { _, v in vm.save(\.mealWindowBoostSMBRatio, v) }
                if vm.boostSMBRatio {
                    HStack {
                        Text("Ratio")
                        Spacer()
                        Text(String(format: "%.2f", NSDecimalNumber(decimal: vm.smbRatioValue).doubleValue))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { NSDecimalNumber(decimal: vm.smbRatioValue).doubleValue },
                            set: { vm.smbRatioValue = Decimal($0); vm.save(\.mealWindowSMBRatioValue, vm.smbRatioValue) }
                        ),
                        in: 0.5 ... 1.0,
                        step: 0.05
                    )
                }
            }
            .listRowBackground(Color.chart)

            // MARK: Item 2 — Rising guard
            Section(
                header: Text("Rising Guard"),
                footer: Text(
                    "Floor normally requires BG actually rising (delta > 0). Relaxing allows brief flat or slight-drop moments (delta > -2) during meal absorption when insulin and carbs are racing. Trade-off: catches more real meal-rise scenarios; small hypo risk if pressed without eating."
                )
            ) {
                Toggle("Relax rising guard", isOn: $vm.relaxRisingGuard)
                    .onChange(of: vm.relaxRisingGuard) { _, v in vm.save(\.mealWindowRelaxRisingGuard, v) }
            }
            .listRowBackground(Color.chart)

            // MARK: Item 3 — Additive floor
            Section(
                header: Text("Additive Floor (Aggressive)"),
                footer: Text(
                    "Default floor only replaces insulinReq when it would otherwise collapse to 0. Additive mode ADDS the floor to whatever insulinReq oref already computed. Significantly more aggressive — only enable after watching outcomes with items above tuned in. Bounded by IOB headroom + tough-meal cap."
                )
            ) {
                Toggle("Additive floor", isOn: $vm.additiveFloor)
                    .onChange(of: vm.additiveFloor) { _, v in vm.save(\.mealWindowAdditiveFloor, v) }
            }
            .listRowBackground(Color.chart)

            // MARK: Item 4 — Force UAM
            Section(
                header: Text("Force UAM"),
                footer: Text(
                    "Forces oref's un-announced-meal detection on during the window, even if your profile has it off. Your button-press IS the announced meal — UAM is the right regime."
                )
            ) {
                Toggle("Force enableUAM in window", isOn: $vm.forceUAM)
                    .onChange(of: vm.forceUAM) { _, v in vm.save(\.mealWindowForceUAM, v) }
            }
            .listRowBackground(Color.chart)

            // MARK: Item 5 — Phantom COB
            Section(
                header: Text("Phantom COB (High Risk)"),
                footer: Text(
                    "When the window is active and you haven't entered carbs (or oref hasn't picked them up yet), inject a virtual COB so eventualBG doesn't mis-predict a drop. Doesn't write a real carb entry. RISK: if BG was actually about to crash, this masks the falling signal. Leave off until items above are validated."
                )
            ) {
                Toggle("Inject phantom COB", isOn: $vm.phantomCOB)
                    .onChange(of: vm.phantomCOB) { _, v in vm.save(\.mealWindowPhantomCOB, v) }
                if vm.phantomCOB {
                    HStack {
                        Text("Phantom amount (g)")
                        Spacer()
                        Text("\(NSDecimalNumber(decimal: vm.phantomCOBGrams).intValue)")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { NSDecimalNumber(decimal: vm.phantomCOBGrams).doubleValue },
                            set: { vm.phantomCOBGrams = Decimal($0); vm.save(\.mealWindowPhantomCOBGrams, vm.phantomCOBGrams) }
                        ),
                        in: 5 ... 60,
                        step: 5
                    )
                }
            }
            .listRowBackground(Color.chart)

            // MARK: Item 6 — Max SMB minutes multiplier
            Section(
                header: Text("Max SMB Minutes Multiplier"),
                footer: Text(
                    "Multiplies your maxSMBBasalMinutes setting inside the meal window so individual SMBs can be larger. 2.0 = double (e.g. 45 → 90 min worth of basal per SMB). 1.0 disables this entirely."
                )
            ) {
                HStack {
                    Text("Multiplier")
                    Spacer()
                    Text(String(format: "%.1f×", NSDecimalNumber(decimal: vm.smbMinutesMultiplier).doubleValue))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { NSDecimalNumber(decimal: vm.smbMinutesMultiplier).doubleValue },
                        set: { vm.smbMinutesMultiplier = Decimal($0); vm.save(\.mealWindowSMBMinutesMultiplier, vm.smbMinutesMultiplier) }
                    ),
                    in: 1.0 ... 3.0,
                    step: 0.5
                )
            }
            .listRowBackground(Color.chart)

            // MARK: Configurable Tough Meal Cap
            Section(
                header: Text("Tough-Meal Cap"),
                footer: Text(
                    "Even with the SMB ratio boost on, no single SMB exceeds this percentage of the calculated insulinReq. Default 75% is the original safety cap. Raising to e.g. 90% lets the SMB-ratio boost have full effect. Range 50–100%."
                )
            ) {
                HStack {
                    Text("Cap")
                    Spacer()
                    Text("\(NSDecimalNumber(decimal: vm.toughMealCapPercent).intValue)%")
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { NSDecimalNumber(decimal: vm.toughMealCapPercent).doubleValue },
                        set: { vm.toughMealCapPercent = Decimal($0); vm.save(\.mealWindowToughMealCapPercent, vm.toughMealCapPercent) }
                    ),
                    in: 50 ... 100,
                    step: 5
                )
            }
            .listRowBackground(Color.chart)

            // MARK: COB Decay Multiplier
            Section(
                header: Text("COB Decay Multiplier"),
                footer: Text(
                    "Slows oref's COB consumption during a meal window. 1.0 = normal. 0.5 = drain at half speed. Fat-heavy meals (Indian, pizza, coconut) routinely outlast the model — this stretches what's already there so the floor keeps dosing past the natural absorption window. Different from phantom COB — doesn't lie about quantity."
                )
            ) {
                HStack {
                    Text("Multiplier")
                    Spacer()
                    Text(String(format: "%.2f×", NSDecimalNumber(decimal: vm.cobDecayMultiplier).doubleValue))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { NSDecimalNumber(decimal: vm.cobDecayMultiplier).doubleValue },
                        set: { vm.cobDecayMultiplier = Decimal($0); vm.save(\.mealWindowCOBDecayMultiplier, vm.cobDecayMultiplier) }
                    ),
                    in: 0.25 ... 1.0,
                    step: 0.05
                )
            }
            .listRowBackground(Color.chart)

            // MARK: Live carbs estimator
            Section(
                header: Text("Mid-meal carbs estimator"),
                footer: Text("During an active meal window, watches BG vs entered carbs and surfaces a suggestion when the meal looks bigger than logged. Always shows as an in-app banner; notifications are optional so it doesn't wake you up.")
            ) {
                Toggle("Enable estimator", isOn: Binding(
                    get: { vm.liveCarbsEnabled },
                    set: { vm.liveCarbsEnabled = $0; vm.save(\.liveCarbsEstimatorEnabled, $0) }
                ))
                if vm.liveCarbsEnabled {
                    Toggle("Notification", isOn: Binding(
                        get: { vm.liveCarbsNotifications },
                        set: { vm.liveCarbsNotifications = $0; vm.save(\.liveCarbsEstimatorNotificationsEnabled, $0) }
                    ))
                    if vm.liveCarbsNotifications {
                        Toggle("Notification sound", isOn: Binding(
                            get: { vm.liveCarbsSound },
                            set: { vm.liveCarbsSound = $0; vm.save(\.liveCarbsEstimatorNotificationSound, $0) }
                        ))
                    }
                    Toggle(isOn: Binding(
                        get: { vm.liveCarbsFPGuard },
                        set: { vm.liveCarbsFPGuard = $0; vm.save(\.liveCarbsEstimatorFPGuardEnabled, $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Suppress on fat-protein meals (first hour)")
                            Text("Skips the suggestion when fat+protein ≥ 25g and the window is < 60 min old — the early 'BG too high' signal on FP meals is the absorption curve, not missing carbs.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listRowBackground(Color.chart)

            // MARK: Behavior-based meal window exit
            Section(
                header: Text("Meal window — exit"),
                footer: Text("When ON: window closes when BG actually returns toward baseline (peak passed + dropping, OR loop quiet for 30 min with BG in range), instead of expiring at a fixed timer. A hard safety cap still applies (default 10 h) so a sensor outage or stuck plateau can't keep the window open forever. Solves the 'window expired while BG was still climbing' case.")
            ) {
                Toggle(isOn: Binding(
                    get: { vm.behaviorBasedExit },
                    set: { vm.behaviorBasedExit = $0; vm.save(\.mealWindowBehaviorBasedExitEnabled, $0) }
                )) {
                    Text("Behavior-based window exit")
                }
            }
            .listRowBackground(Color.chart)

            // MARK: Real-time phantom COB auto-injector (EXPERIMENTAL)
            Section(
                header: Text("Auto phantom COB (experimental)"),
                footer: Text("EXPERIMENTAL. When ON, each loop pass infers carb arrival from BG response and silently injects phantom COB so oref doses for what's actually happening — even when no carbs were entered. Designed for the 'tap quick-action, walk away' workflow. Default OFF; flipping ON requires typing ENABLE to confirm. Real insulin will be dosed based on inferred carbs nobody told the loop about — collect data first, then opt in.")
            ) {
                Toggle(isOn: Binding(
                    get: { vm.autoPhantomCOB },
                    set: { newValue in
                        if newValue {
                            // Don't actually flip the setting yet —
                            // require the typed confirmation first.
                            autoPhantomConfirmText = ""
                            showAutoPhantomConfirm = true
                        } else {
                            vm.autoPhantomCOB = false
                            vm.save(\.mealWindowAutoPhantomCOBEnabled, false)
                            vm.logAutoPhantomToggle(false)
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Real-time phantom COB injector")
                        if vm.autoPhantomCOB {
                            Text("Active — oref will see inferred COB each loop").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .listRowBackground(Color.chart)

            // MARK: Reset to defaults
            Section(footer: Text("Resets all eating-mode tuning toggles and sliders to the shipped defaults. Doesn't affect telemetry settings or other Trio preferences.")) {
                Button(role: .destructive) {
                    vm.resetToDefaults()
                } label: {
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
        .navigationTitle("Eating Mode Tuning")
        .onAppear { vm.reload() }
        .sheet(isPresented: $showAutoPhantomConfirm, onDismiss: {
            // If user dismissed without confirming, ensure toggle is OFF.
            if !vm.autoPhantomCOB {
                // no-op — already off
            }
        }) {
            AutoPhantomCOBConfirmSheet(
                confirmText: $autoPhantomConfirmText,
                onCancel: {
                    showAutoPhantomConfirm = false
                },
                onConfirm: {
                    vm.autoPhantomCOB = true
                    vm.save(\.mealWindowAutoPhantomCOBEnabled, true)
                    vm.logAutoPhantomToggle(true)
                    showAutoPhantomConfirm = false
                }
            )
        }
    }
}

/// ALL-CAPS confirmation sheet to enable the auto-phantom-COB injector.
/// The user must type "ENABLE" (case-sensitive) to confirm. Single
/// accidental tap on the toggle should never flip a setting that lets
/// the loop dose real insulin based on inferred carbs.
private struct AutoPhantomCOBConfirmSheet: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState
    @Binding var confirmText: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @FocusState private var fieldFocused: Bool

    private let requiredWord = "ENABLE"

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Label("Real insulin will be dosed based on inferred carbs", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.headline)
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("Read before enabling"),
                    footer: Text("Each loop pass, the injector reads the BG response and silently adds phantom COB to the loop's model. oref then doses for those carbs. If the inference is wrong (sensor noise, unexpected activity, miscalibrated profile) the loop will dose insulin you didn't account for, which can cause delayed lows.\n\nSafety gates (always on): rising-trend only, classifier ≥ Medium, per-loop cap, per-window cap. Recommended: leave OFF for at least two weeks of meals with this build so we can analyze your data and tune before flipping ON.")
                ) {
                    EmptyView()
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("Type \(requiredWord) (all caps) to confirm"),
                    footer: Text("Case-sensitive. Mistypes do nothing.")
                ) {
                    TextField(requiredWord, text: $confirmText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.title3.monospaced())
                        .focused($fieldFocused)
                }
                .listRowBackground(Color.chart)

                Section {
                    Button(role: .destructive) {
                        onConfirm()
                    } label: {
                        Label("Enable auto phantom COB", systemImage: "checkmark.seal")
                    }
                    .disabled(confirmText != requiredWord)

                    Button("Cancel") {
                        onCancel()
                    }
                }
                .listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Confirm enable")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { fieldFocused = true }
        }
    }
}

@MainActor
private final class ViewModel: ObservableObject {
    @Published var boostSMBRatio: Bool = true
    @Published var smbRatioValue: Decimal = 0.8
    @Published var relaxRisingGuard: Bool = true
    @Published var additiveFloor: Bool = false
    @Published var forceUAM: Bool = true
    @Published var phantomCOB: Bool = false
    @Published var phantomCOBGrams: Decimal = 20
    @Published var smbMinutesMultiplier: Decimal = 2.0
    @Published var toughMealCapPercent: Decimal = 75
    @Published var cobDecayMultiplier: Decimal = 1.0
    @Published var liveCarbsEnabled: Bool = true
    @Published var liveCarbsNotifications: Bool = true
    @Published var liveCarbsSound: Bool = true
    @Published var liveCarbsFPGuard: Bool = true
    @Published var behaviorBasedExit: Bool = true
    @Published var autoPhantomCOB: Bool = false

    private let resolver: Resolver = TrioApp.resolver
    private lazy var settingsManager: SettingsManager? = resolver.resolve(SettingsManager.self)

    func reload() {
        guard let s = settingsManager?.settings else { return }
        boostSMBRatio = s.mealWindowBoostSMBRatio
        smbRatioValue = s.mealWindowSMBRatioValue
        relaxRisingGuard = s.mealWindowRelaxRisingGuard
        additiveFloor = s.mealWindowAdditiveFloor
        forceUAM = s.mealWindowForceUAM
        phantomCOB = s.mealWindowPhantomCOB
        phantomCOBGrams = s.mealWindowPhantomCOBGrams
        smbMinutesMultiplier = s.mealWindowSMBMinutesMultiplier
        toughMealCapPercent = s.mealWindowToughMealCapPercent
        cobDecayMultiplier = s.mealWindowCOBDecayMultiplier
        liveCarbsEnabled = s.liveCarbsEstimatorEnabled
        liveCarbsNotifications = s.liveCarbsEstimatorNotificationsEnabled
        liveCarbsSound = s.liveCarbsEstimatorNotificationSound
        liveCarbsFPGuard = s.liveCarbsEstimatorFPGuardEnabled
        behaviorBasedExit = s.mealWindowBehaviorBasedExitEnabled
        autoPhantomCOB = s.mealWindowAutoPhantomCOBEnabled
    }

    /// Generic setter that writes a single TrioSettings field through SettingsManager.
    /// Using a WritableKeyPath keeps each caller a one-liner.
    func save<Value>(_ keyPath: WritableKeyPath<TrioSettings, Value>, _ newValue: Value) {
        guard var s = settingsManager?.settings else { return }
        s[keyPath: keyPath] = newValue
        settingsManager?.settings = s
    }

    /// Emit a paired telemetry event when the user enables or disables
    /// the auto-phantom-COB injector. Visible in events.jsonl so we can
    /// correlate post-enable behavior with pre-enable baseline.
    func logAutoPhantomToggle(_ enabled: Bool) {
        let telemetry = resolver.resolve(AlgorithmTelemetryManager.self)
        telemetry?.logEvent(AlgorithmTelemetryEvent(
            kind: .mealWindowAutoPhantomCOBToggled,
            timestamp: Date(),
            windowId: settingsManager?.settings.mealWindowId,
            payload: [
                "enabled": .bool(enabled)
            ]
        ))
    }

    func resetToDefaults() {
        guard var s = settingsManager?.settings else { return }
        s.mealWindowBoostSMBRatio = true
        s.mealWindowSMBRatioValue = 0.8
        s.mealWindowRelaxRisingGuard = true
        s.mealWindowAdditiveFloor = false
        s.mealWindowForceUAM = true
        s.mealWindowPhantomCOB = false
        s.mealWindowPhantomCOBGrams = 20
        s.mealWindowSMBMinutesMultiplier = 2.0
        s.mealWindowToughMealCapPercent = 75
        s.mealWindowCOBDecayMultiplier = 1.0
        s.liveCarbsEstimatorEnabled = true
        s.liveCarbsEstimatorNotificationsEnabled = true
        s.liveCarbsEstimatorNotificationSound = true
        s.liveCarbsEstimatorFPGuardEnabled = true
        s.mealWindowBehaviorBasedExitEnabled = true
        // Auto-phantom-COB is intentionally NOT reset to its default by
        // this button. It requires the ALL-CAPS confirmation to flip on;
        // resetting "to defaults" without the confirmation would be a
        // back-door past the safety gate. Leave the user's choice alone.
        settingsManager?.settings = s
        reload()
    }
}
