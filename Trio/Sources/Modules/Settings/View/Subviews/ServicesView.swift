//
//  FeatureSettingsView.swift
//  Trio
//
//  Created by Deniz Cengiz on 26.07.24.
//
import Foundation
import HealthKit
import SwiftUI
import Swinject

struct ServicesView: BaseView {
    let resolver: Resolver

    @ObservedObject var state: Settings.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        Form {
            Section(
                header: Text("Connected Services"),
                content: {
                    Text("Nightscout").navigationLink(to: .nighscoutConfig, from: self)
                    Text("Tidepool").navigationLink(to: .tidepoolConfig, from: self)
                    if HKHealthStore.isHealthDataAvailable() {
                        Text("Apple Health").navigationLink(to: .healthkit, from: self)
                    }
                    HStack {
                        Text("Garmin Health Data")
                        Spacer()
                        ZStack {
                            if GarminFirebaseConstants.isConfigured, GarminFirebaseManager.isSignedIn {
                                Image(systemName: "network")
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green).font(.caption2)
                                    .offset(x: 9, y: 6)
                            } else if GarminFirebaseConstants.isConfigured {
                                Image(systemName: "network")
                                Image(systemName: "questionmark.circle.fill")
                                    .foregroundColor(.orange).font(.caption2)
                                    .offset(x: 9, y: 6)
                            } else {
                                Image(systemName: "network.slash")
                            }
                        }
                    }.navigationLink(to: .garminFirestoreStatus, from: self)
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("AI Analysis"),
                content: {
                    Text("AI Analysis").navigationLink(to: .aiInsightsConfig, from: self)
                }
            )
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Services")
        .navigationBarTitleDisplayMode(.automatic)
    }
}
