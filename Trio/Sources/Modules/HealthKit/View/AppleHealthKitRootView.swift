import SwiftUI
import Swinject

extension AppleHealthKit {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @State private var shouldDisplayHint: Bool = false
        @State var hintDetent = PresentationDetent.large
        @State var selectedVerboseHint: AnyView?
        @State var hintLabel: String?
        @State private var decimalPlaceholder: Decimal = 0.0
        @State private var booleanPlaceholder: Bool = false

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.useAppleHealth,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Connect to Apple Health")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Connect to Apple Health"),
                    miniHint: String(localized: "Allow Trio to read from and write to Apple Health."),
                    verboseHint:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Default: OFF").bold()
                        Text("This allows Trio to read from and write to Apple Health.")
                        Text("Warning: You must also give permissions in iOS System Settings for the Health app.").bold()
                    },
                    headerText: String(localized: "Apple Health Integration")
                )

                if !state.needShowInformationTextForSetPermissions {
                    Section {
                        VStack {
                            HStack {
                                Image(systemName: "exclamationmark.circle.fill")
                                Text("Give Apple Health Write Permissions")
                            }.padding(.bottom)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("1. Open the Settings app on your iOS device.")
                                Text(
                                    "2. Scroll down or type \"Health\" in the settings search bar and select the \"Health\" app."
                                )
                                Text("3. Tap on \"Data Access & Devices\".")
                                Text("4. Find and select \"Trio\" from the list of apps.")
                                Text("5. Ensure that the \"Write Data\" option is enabled for the desired health metrics.")
                            }.font(.footnote)
                        }
                        .padding(.vertical)
                        .foregroundColor(Color.secondary)
                    }.listRowBackground(Color.chart)
                }

                // Nutrition Data Section
                nutritionDataSection

                // Nutrition Preview (when read is enabled)
                if state.readNutritionFromHealth {
                    nutritionPreviewSection

                    // Analysis link
                    Section {
                        NavigationLink(destination: NutritionAnalysisView(resolver: resolver)) {
                            HStack {
                                Image(systemName: "chart.bar.doc.horizontal")
                                    .foregroundColor(.purple)
                                    .frame(width: 24)
                                VStack(alignment: .leading) {
                                    Text("Nutrition Analysis")
                                    Text("Compare your carb estimates vs actual, see BG impact")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Insights")
                    }
                }

                // Health Metrics for AI Analysis Section
                healthMetricsSection
            }
            .listSectionSpacing(sectionSpacing)
            .sheet(isPresented: $shouldDisplayHint) {
                SettingInputHintView(
                    hintDetent: $hintDetent,
                    shouldDisplayHint: $shouldDisplayHint,
                    hintLabel: hintLabel ?? "",
                    hintText: selectedVerboseHint ?? AnyView(EmptyView()),
                    sheetTitle: String(localized: "Help", comment: "Help sheet title")
                )
            }
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationTitle("Apple Health")
            .navigationBarTitleDisplayMode(.automatic)
        }

        // MARK: - Nutrition Data Section

        @ViewBuilder
        private var nutritionDataSection: some View {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "fork.knife")
                            .foregroundColor(.orange)
                        Text("Nutrition Data")
                            .font(.headline)
                    }
                    Text("Control how Trio interacts with nutrition data (carbs, fat, protein) in Apple Health. Disable writing if another app like Cronometer is your nutrition source.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle(isOn: $state.writeNutritionToHealth) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(.blue)
                            .frame(width: 24)
                        VStack(alignment: .leading) {
                            Text("Write Nutrition to Apple Health")
                            Text("Send carb/fat/protein entries from Trio to Apple Health")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Toggle(isOn: $state.readNutritionFromHealth) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundColor(.green)
                            .frame(width: 24)
                        VStack(alignment: .leading) {
                            Text("Read Nutrition from Apple Health")
                            Text("Display nutrition data from external apps (e.g., Cronometer)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("Nutrition Sync")
            } footer: {
                Text("If you use Cronometer or another app to log food, disable writing to avoid duplicate entries and enable reading to see that data in Trio.")
            }
        }

        // MARK: - Nutrition Preview Section

        @ViewBuilder
        private var nutritionPreviewSection: some View {
            Section {
                if state.isLoadingNutrition {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding()
                        Spacer()
                    }
                } else if state.recentMeals.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "tray")
                                .foregroundColor(.secondary)
                            Text("No Nutrition Data")
                                .foregroundColor(.secondary)
                        }
                        Text("No nutrition data found in Apple Health for the last 7 days. Make sure your nutrition app is syncing to Apple Health and that read permissions are granted in iOS Settings > Health > Trio.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(state.recentMeals) { day in
                        dailyNutritionRow(day)
                    }
                }
            } header: {
                HStack {
                    Text("Daily Nutrition")
                    Spacer()
                    if !state.isLoadingNutrition {
                        Button {
                            state.fetchRecentNutrition()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                    }
                }
            } footer: {
                Text("Nutrition data from Apple Health (e.g., Cronometer). Shown as daily totals.")
            }
        }

        @ViewBuilder
        private func dailyNutritionRow(_ day: HealthNutritionDay) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                // Header: day and source
                HStack {
                    Text(day.dayDescription)
                        .font(.headline)
                    Spacer()
                    Text("\(day.entryCount) items")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(day.source)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }

                // Macro totals
                HStack(spacing: 16) {
                    macroLabel("C", grams: day.totalCarbs, color: .orange)
                    macroLabel("F", grams: day.totalFat, color: .yellow)
                    macroLabel("P", grams: day.totalProtein, color: .red)
                    Spacer()
                    Text("\(Int(day.totalCalories)) kcal")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Macro percentage bar
                macroPercentageBar(day: day)
            }
            .padding(.vertical, 4)
        }

        @ViewBuilder
        private func macroLabel(_ label: String, grams: Double, color: Color) -> some View {
            HStack(spacing: 2) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text("\(Int(grams))g \(label)")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
        }

        @ViewBuilder
        private func macroPercentageBar(day: HealthNutritionDay) -> some View {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    let carbWidth = geometry.size.width * day.carbPercentage / 100
                    let fatWidth = geometry.size.width * day.fatPercentage / 100
                    let proteinWidth = geometry.size.width * day.proteinPercentage / 100

                    if day.carbPercentage > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.orange)
                            .frame(width: max(carbWidth, 2))
                            .overlay(
                                Text("\(Int(day.carbPercentage))%")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white)
                                    .opacity(carbWidth > 30 ? 1 : 0)
                            )
                    }
                    if day.fatPercentage > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.yellow)
                            .frame(width: max(fatWidth, 2))
                            .overlay(
                                Text("\(Int(day.fatPercentage))%")
                                    .font(.system(size: 9))
                                    .foregroundColor(.black)
                                    .opacity(fatWidth > 30 ? 1 : 0)
                            )
                    }
                    if day.proteinPercentage > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.red)
                            .frame(width: max(proteinWidth, 2))
                            .overlay(
                                Text("\(Int(day.proteinPercentage))%")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white)
                                    .opacity(proteinWidth > 30 ? 1 : 0)
                            )
                    }
                }
            }
            .frame(height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }

        // MARK: - Health Metrics Section

        @ViewBuilder
        private var healthMetricsSection: some View {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundColor(.blue)
                        Text("Health Metrics for AI Analysis")
                            .font(.headline)
                    }
                    Text("Enable these options to include health data from your wearables (Apple Watch, Garmin, etc.) in Claude AI analysis. This helps identify patterns between lifestyle factors and glucose control.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle(isOn: $state.enableActivityData) {
                    HStack {
                        Image(systemName: "figure.walk")
                            .foregroundColor(.green)
                            .frame(width: 24)
                        VStack(alignment: .leading) {
                            Text("Activity Data")
                            Text("Steps, active calories, exercise minutes")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Toggle(isOn: $state.enableSleepData) {
                    HStack {
                        Image(systemName: "bed.double.fill")
                            .foregroundColor(.indigo)
                            .frame(width: 24)
                        VStack(alignment: .leading) {
                            Text("Sleep Data")
                            Text("Sleep duration, stages, efficiency")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Toggle(isOn: $state.enableHeartRateData) {
                    HStack {
                        Image(systemName: "heart.fill")
                            .foregroundColor(.red)
                            .frame(width: 24)
                        VStack(alignment: .leading) {
                            Text("Heart Rate & HRV")
                            Text("Resting HR, heart rate variability")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Toggle(isOn: $state.enableWorkoutData) {
                    HStack {
                        Image(systemName: "flame.fill")
                            .foregroundColor(.orange)
                            .frame(width: 24)
                        VStack(alignment: .leading) {
                            Text("Workout Data")
                            Text("Exercise sessions, duration, calories")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("AI Analysis Data Sources")
            } footer: {
                Text("When enabled, this data will be included in Claude-o-Tune, Quick Analysis, and Doctor Visit reports to help identify correlations between lifestyle and glucose patterns.")
            }
        }
    }
}
