import SwiftUI
import Swinject

/// V2 Hub — consolidates all V2-related settings, nutrition data, and analysis
/// into a single tabbed page. Replaces the standalone V2MacroDosingSettingsView
/// as the primary navigation destination.
struct V2MacroHubView: BaseView {
    let resolver: Resolver

    @ObservedObject var state: Settings.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    @State private var selectedTab: V2HubTab = .engine

    enum V2HubTab: String, CaseIterable {
        case nutrition = "Nutrition"
        case engine = "Engine"
        case garmin = "Garmin"
        case analysis = "Analysis"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $selectedTab) {
                ForEach(V2HubTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            switch selectedTab {
            case .nutrition:
                V2NutritionSettingsView(resolver: resolver)
            case .engine:
                V2MacroDosingSettingsView(resolver: resolver, state: state)
            case .garmin:
                V2GarminSettingsView(state: state)
            case .analysis:
                V2AnalysisHubView(resolver: resolver)
            }
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("V2 Macro Engine")
        .navigationBarTitleDisplayMode(.inline)
    }
}
