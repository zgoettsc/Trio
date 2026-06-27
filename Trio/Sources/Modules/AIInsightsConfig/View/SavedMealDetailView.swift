import CoreData
import SwiftUI
import Swinject

/// Per-meal detail view. Phase B ships with basic stats + edit/duplicate/delete
/// + a list of instances. Phase C adds composite curves, checkpoint tables,
/// and size-stratified analytics.
struct SavedMealDetailView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    @ObservedObject var meal: SavedMeal

    @State private var showEdit = false
    @State private var showDeleteConfirm = false
    @State private var startResult: String?

    private let resolver: Resolver = TrioApp.resolver
    private var storage: SavedMealStorage? { resolver.resolve(SavedMealStorage.self) }

    private var instancesArray: [SavedMealInstance] {
        let all = (meal.instances?.allObjects as? [SavedMealInstance]) ?? []
        return all
            .filter { $0.closedAt != nil }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(meal.icon ?? "🍽️").font(.largeTitle)
                    VStack(alignment: .leading) {
                        Text(meal.name ?? "(unnamed)").font(.title2.bold())
                        Text("\(meal.cachedInstanceCount) instance\(meal.cachedInstanceCount == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task { await startMeal() }
                } label: {
                    Label("Start eating mode with this meal", systemImage: "play.circle.fill")
                }
            }
            .listRowBackground(Color.chart)

            Section(header: Text("Seeded behavior")) {
                statRow("Carbs default", value: meal.defaultCarbs.map { "\($0.intValue)g" } ?? "—")
                statRow("Fat default", value: meal.defaultFat.map { "\($0.intValue)g" } ?? "—")
                statRow("Protein default", value: meal.defaultProtein.map { "\($0.intValue)g" } ?? "—")
                statRow("Classification", value: (meal.defaultClassification ?? "auto").capitalized)
                if meal.defaultExtendedDurationMinutes > 0 {
                    statRow(
                        "Extended duration",
                        value: String(format: "%.1f h", Double(meal.defaultExtendedDurationMinutes) / 60)
                    )
                }
                if meal.defaultPhantomCOBEnabled {
                    statRow("Phantom COB", value: meal.defaultPhantomCOBGrams.map { "\($0.intValue)g" } ?? "default")
                }
            }
            .listRowBackground(Color.chart)

            if !instancesArray.isEmpty {
                Section(header: Text("History (last \(instancesArray.count))")) {
                    ForEach(instancesArray, id: \.objectID) { instance in
                        InstanceRow(instance: instance)
                    }
                }
                .listRowBackground(Color.chart)
            } else {
                Section(
                    footer: Text("No closed instances yet. Start this meal a few times to build up the BG-response history for analytics.")
                ) {
                    Text("No history yet").foregroundStyle(.secondary)
                }
                .listRowBackground(Color.chart)
            }

            if let result = startResult {
                Section { Text(result).foregroundColor(.secondary) }
                    .listRowBackground(Color.chart)
            }

            Section {
                Button("Duplicate") {
                    storage?.duplicateMeal(meal)
                    dismiss()
                }
                Button("Delete", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle(meal.name ?? "Meal")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEdit = true }
            }
        }
        .sheet(isPresented: $showEdit) {
            NavigationView { SavedMealEditView(meal: meal) }
        }
        .confirmationDialog(
            "Delete \(meal.name ?? "this meal") and all its history?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                storage?.deleteMeal(meal)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @MainActor
    private func startMeal() async {
        guard #available(iOS 16.0, *), let mealId = meal.id else { return }
        let req = AnnounceMealIntentRequest()
        do {
            let carbs = meal.defaultCarbs.map { $0 as Decimal }
            startResult = try await req.announce(estimatedCarbs: carbs, savedMealId: mealId)
        } catch {
            startResult = "Failed to start: \(error.localizedDescription)"
        }
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

private struct InstanceRow: View {
    @ObservedObject var instance: SavedMealInstance

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let started = instance.startedAt {
                    Text(started, style: .date).font(.subheadline)
                }
                Spacer()
                if let cls = instance.finalClassification {
                    Text(cls.capitalized).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                if let c = instance.carbsAtActivation {
                    Text("\(c.intValue)c").font(.caption)
                }
                if let f = instance.fatAtActivation {
                    Text("\(f.intValue)f").font(.caption)
                }
                if let p = instance.proteinAtActivation {
                    Text("\(p.intValue)p").font(.caption)
                }
                if instance.peakBG > 0 {
                    Text("peak \(Int(instance.peakBG))").font(.caption)
                }
                if instance.outcomeScore > 0 {
                    Text("score \(instance.outcomeScore)/100").font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
