import CoreData
import SwiftUI
import Swinject

/// Add or edit a SavedMeal. Pass `meal: nil` for the add path.
struct SavedMealEditView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    let meal: SavedMeal?
    private var isEditing: Bool { meal != nil }

    @State private var name: String = ""
    @State private var icon: String = "🍽️"

    @State private var hasDefaultCarbs: Bool = false
    @State private var defaultCarbs: Double = 50
    @State private var hasDefaultFat: Bool = false
    @State private var defaultFat: Double = 20
    @State private var hasDefaultProtein: Bool = false
    @State private var defaultProtein: Double = 20

    @State private var hasDefaultClassification: Bool = false
    @State private var defaultClassification: MealClassification = .medium

    @State private var overrideExtendedDuration: Bool = false
    @State private var extendedDurationMinutes: Double = 360

    @State private var phantomCOBEnabled: Bool = false
    @State private var phantomCOBGrams: Double = 20

    private let resolver: Resolver = TrioApp.resolver
    private var storage: SavedMealStorage? { resolver.resolve(SavedMealStorage.self) }

    var body: some View {
        Form {
            Section(header: Text("Identity")) {
                TextField("Name (e.g. Indian)", text: $name)
                    .autocorrectionDisabled()
                HStack {
                    Text("Icon")
                    Spacer()
                    TextField("🍽️", text: $icon)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 60)
                }
            }
            .listRowBackground(Color.chart)

            Section(
                header: Text("Default Macros (optional)"),
                footer: Text("If set, these pre-fill when you start this meal. Leave off if you go zero-entry — the classifier still works without macros.")
            ) {
                Toggle("Set default carbs", isOn: $hasDefaultCarbs)
                if hasDefaultCarbs {
                    sliderRow(label: "Carbs", value: $defaultCarbs, range: 0...200, step: 5, suffix: "g")
                }
                Toggle("Set default fat", isOn: $hasDefaultFat)
                if hasDefaultFat {
                    sliderRow(label: "Fat", value: $defaultFat, range: 0...100, step: 5, suffix: "g")
                }
                Toggle("Set default protein", isOn: $hasDefaultProtein)
                if hasDefaultProtein {
                    sliderRow(label: "Protein", value: $defaultProtein, range: 0...100, step: 5, suffix: "g")
                }
            }
            .listRowBackground(Color.chart)

            Section(
                header: Text("Seeded Classification"),
                footer: Text("Sets the live classifier's starting level when you pick this meal. Complex pre-emptively enables phantom COB and the extended window — useful for known fat-heavy meals (Indian, pizza, Chinese) so you don't have to wait for the late-phase detector to upgrade mid-window.")
            ) {
                Toggle("Seed initial classification", isOn: $hasDefaultClassification)
                if hasDefaultClassification {
                    Picker("Classification", selection: $defaultClassification) {
                        ForEach(MealClassification.allCases, id: \.self) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    Text(defaultClassification.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.chart)

            Section(
                header: Text("Per-Meal Overrides"),
                footer: Text("Optional overrides applied to windows started from this meal. Otherwise the global classifier defaults apply.")
            ) {
                Toggle("Custom extended duration", isOn: $overrideExtendedDuration)
                if overrideExtendedDuration {
                    sliderRow(
                        label: "Extended duration",
                        value: $extendedDurationMinutes,
                        range: 120...720, step: 30, suffix: "min"
                    )
                }
                Toggle("Enable phantom COB at start", isOn: $phantomCOBEnabled)
                if phantomCOBEnabled {
                    sliderRow(label: "Phantom COB", value: $phantomCOBGrams, range: 0...40, step: 5, suffix: "g")
                }
            }
            .listRowBackground(Color.chart)

            Section {
                Button(isEditing ? "Save Changes" : "Create Meal") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle(isEditing ? "Edit Meal" : "New Meal")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .onAppear(perform: loadFromMeal)
    }

    private func loadFromMeal() {
        guard let m = meal else { return }
        name = m.name ?? ""
        icon = m.icon ?? "🍽️"
        if let v = m.defaultCarbs {
            hasDefaultCarbs = true
            defaultCarbs = v.doubleValue
        }
        if let v = m.defaultFat {
            hasDefaultFat = true
            defaultFat = v.doubleValue
        }
        if let v = m.defaultProtein {
            hasDefaultProtein = true
            defaultProtein = v.doubleValue
        }
        if let raw = m.defaultClassification, let c = MealClassification(rawValue: raw) {
            hasDefaultClassification = true
            defaultClassification = c
        }
        if m.defaultExtendedDurationMinutes > 0 {
            overrideExtendedDuration = true
            extendedDurationMinutes = Double(m.defaultExtendedDurationMinutes)
        }
        phantomCOBEnabled = m.defaultPhantomCOBEnabled
        if let g = m.defaultPhantomCOBGrams {
            phantomCOBGrams = g.doubleValue
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        if let existing = meal {
            storage?.updateMeal(existing) { m in
                m.name = trimmedName
                m.icon = icon.isEmpty ? "🍽️" : icon
                m.defaultCarbs = hasDefaultCarbs ? NSDecimalNumber(value: defaultCarbs) : nil
                m.defaultFat = hasDefaultFat ? NSDecimalNumber(value: defaultFat) : nil
                m.defaultProtein = hasDefaultProtein ? NSDecimalNumber(value: defaultProtein) : nil
                m.defaultClassification = hasDefaultClassification ? defaultClassification.rawValue : nil
                m.defaultExtendedDurationMinutes = overrideExtendedDuration ? Int32(extendedDurationMinutes) : 0
                m.defaultPhantomCOBEnabled = phantomCOBEnabled
                m.defaultPhantomCOBGrams = phantomCOBEnabled ? NSDecimalNumber(value: phantomCOBGrams) : nil
            }
        } else {
            let created = storage?.createMeal(name: trimmedName, icon: icon.isEmpty ? "🍽️" : icon)
            if let created {
                storage?.updateMeal(created) { m in
                    m.defaultCarbs = hasDefaultCarbs ? NSDecimalNumber(value: defaultCarbs) : nil
                    m.defaultFat = hasDefaultFat ? NSDecimalNumber(value: defaultFat) : nil
                    m.defaultProtein = hasDefaultProtein ? NSDecimalNumber(value: defaultProtein) : nil
                    m.defaultClassification = hasDefaultClassification ? defaultClassification.rawValue : nil
                    m.defaultExtendedDurationMinutes = overrideExtendedDuration ? Int32(extendedDurationMinutes) : 0
                    m.defaultPhantomCOBEnabled = phantomCOBEnabled
                    m.defaultPhantomCOBGrams = phantomCOBEnabled ? NSDecimalNumber(value: phantomCOBGrams) : nil
                }
            }
        }
        dismiss()
    }

    @ViewBuilder
    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value.wrappedValue))\(suffix)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
