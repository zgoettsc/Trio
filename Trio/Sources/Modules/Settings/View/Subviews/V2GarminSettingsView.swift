import SwiftUI

/// Garmin Sensitivity settings tab within the V2 Hub.
/// Extracted from V2MacroDosingSettingsView for cleaner organization.
struct V2GarminSettingsView: View {
    @ObservedObject var state: Settings.StateModel

    var body: some View {
        List {
            Section(header: Text("Garmin Sensitivity Integration")) {
                Toggle("Enable Garmin Sensitivity", isOn: $state.garminEnabled)

                if state.garminEnabled {
                    HStack {
                        Text("Firebase Status")
                        Spacer()
                        Text("See Garmin Health Data")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink(value: Screen.garminFirestoreStatus) {
                        Text("Garmin Health Data")
                    }
                }
            }

            if state.garminEnabled {
                Section(header: Text("How It Works")) {
                    VStack(alignment: .leading, spacing: 8) {
                        infoRow(icon: "moon.zzz.fill", color: .indigo,
                                title: "Sleep Quality",
                                desc: "Poor sleep reduces insulin sensitivity (up to 1.67x demand)")

                        infoRow(icon: "figure.run", color: .green,
                                title: "Activity Level",
                                desc: "Recent exercise improves sensitivity (down to 0.60x demand)")

                        infoRow(icon: "heart.fill", color: .red,
                                title: "Resting Heart Rate",
                                desc: "Elevated RHR suggests stress or illness (increased demand)")

                        infoRow(icon: "waveform.path.ecg", color: .orange,
                                title: "HRV",
                                desc: "Low HRV indicates reduced recovery (increased demand)")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func infoRow(icon: String, color: Color, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
