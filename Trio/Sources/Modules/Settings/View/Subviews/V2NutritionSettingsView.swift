import SwiftUI
import Swinject

/// Nutrition settings tab within the V2 Hub.
/// Contains the Apple Health read/write toggles for nutrition data and a daily nutrition preview.
/// Extracted from AppleHealthKitRootView to consolidate all nutrition-related settings here.
struct V2NutritionSettingsView: View {
    let resolver: Resolver

    @StateObject private var healthState = AppleHealthKit.StateModel()

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        List {
            Section(header: Text("Nutrition Data")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Control how Trio reads and writes nutrition data with Apple Health.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("If you use Cronometer, disable 'Write Nutrition' to avoid duplicate entries.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(.vertical, 4)

                Toggle(isOn: $healthState.writeNutritionToHealth) {
                    HStack {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.blue)
                        Text("Write Nutrition to Apple Health")
                    }
                }

                Toggle(isOn: $healthState.readNutritionFromHealth) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.green)
                        Text("Read Nutrition from Apple Health")
                    }
                }
            }

            // Daily nutrition preview (when read is enabled)
            if healthState.readNutritionFromHealth {
                Section(header: HStack {
                    Text("Daily Nutrition")
                    Spacer()
                    Button {
                        healthState.fetchRecentNutrition()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .textCase(nil)
                }) {
                    if healthState.isLoadingNutrition {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else if healthState.recentMeals.isEmpty {
                        Text("No nutrition data available")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(healthState.recentMeals.prefix(7)) { day in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(day.dayDescription)
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text("\(day.entries.count) entries")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: 12) {
                                    macroLabel("C", value: day.totalCarbs, color: .orange)
                                    macroLabel("F", value: day.totalFat, color: .yellow)
                                    macroLabel("P", value: day.totalProtein, color: .red)
                                    Spacer()
                                    Text("\(Int(day.totalCalories)) cal")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            // Cronometer shortcut
            Section {
                Button {
                    if let url = URL(string: "cronometer://") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.forward.app")
                            .foregroundStyle(.green)
                        Text("Open Cronometer")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .onAppear {
            healthState.resolver = resolver
            healthState.fetchRecentNutrition()
        }
    }

    private func macroLabel(_ label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
            Text("\(Int(value))g")
                .font(.caption2)
        }
    }
}
