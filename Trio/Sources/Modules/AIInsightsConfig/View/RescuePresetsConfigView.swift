import Foundation
import SwiftUI
import Swinject

/// Settings screen for managing the user's rescue-preset library.
/// User-owned: starts empty, the user adds their own items. Each entry
/// becomes a tap-target in the Treatments → Rescue picker. Macros
/// stored on each preset feed downstream per-preset BG-recovery
/// analytics (Analysis 11), so accurate values matter — encourage
/// label-reading.
struct RescuePresetsConfigView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    @StateObject private var vm = ViewModel()
    @State private var editingPreset: RescuePreset?
    @State private var showAdd = false

    var body: some View {
        Form {
            Section(
                header: Text("Your rescue presets"),
                footer: Text("Add the items you actually keep on hand for lows — juice box, glucose tabs, granola bar, whatever you reach for. Per-preset BG-recovery curves accumulate in telemetry once you've used each a few times, so accurate carb counts matter.")
            ) {
                if vm.presets.isEmpty {
                    HStack {
                        Image(systemName: "tray").foregroundStyle(.secondary)
                        Text("No presets yet — tap Add Preset to start").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(vm.presets) { preset in
                        Button {
                            editingPreset = preset
                        } label: {
                            HStack(spacing: 12) {
                                Text(preset.emoji ?? "🍬").font(.title2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name).foregroundStyle(.primary)
                                    HStack(spacing: 6) {
                                        Text("\(format(preset.carbs))g carbs").font(.caption)
                                        if let f = preset.fat, f > 0 { Text("· \(format(f))f").font(.caption) }
                                        if let p = preset.protein, p > 0 { Text("· \(format(p))p").font(.caption) }
                                    }
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .onDelete { offsets in vm.delete(at: offsets) }
                    .onMove { from, to in vm.move(from: from, to: to) }
                }
            }
            .listRowBackground(Color.chart)

            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("Add Preset", systemImage: "plus.circle.fill")
                }
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Rescue Presets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !vm.presets.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .sheet(isPresented: $showAdd) {
            RescuePresetEditSheet(preset: nil) { newPreset in
                vm.add(newPreset)
            }
        }
        .sheet(item: $editingPreset) { p in
            RescuePresetEditSheet(preset: p) { updated in
                vm.update(updated)
            }
        }
        .onAppear { vm.reload() }
    }

    private func format(_ d: Decimal) -> String {
        let dn = NSDecimalNumber(decimal: d).doubleValue
        return dn.rounded() == dn ? "\(Int(dn))" : String(format: "%.1f", dn)
    }
}

/// Sheet for adding or editing a single preset.
private struct RescuePresetEditSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    let preset: RescuePreset?
    let onSave: (RescuePreset) -> Void

    @State private var name: String
    @State private var emoji: String
    @State private var carbsText: String
    @State private var fatText: String
    @State private var proteinText: String
    @State private var notes: String

    init(preset: RescuePreset?, onSave: @escaping (RescuePreset) -> Void) {
        self.preset = preset
        self.onSave = onSave
        _name = State(initialValue: preset?.name ?? "")
        _emoji = State(initialValue: preset?.emoji ?? "")
        // Disambiguate from the instance method of the same name —
        // calling `format(...)` here would resolve to self.format(...)
        // which the compiler rejects because stored properties aren't
        // initialized yet.
        _carbsText = State(initialValue: preset.map { Self.format($0.carbs) } ?? "")
        _fatText = State(initialValue: preset?.fat.map(Self.format) ?? "")
        _proteinText = State(initialValue: preset?.protein.map(Self.format) ?? "")
        _notes = State(initialValue: preset?.notes ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Identity")) {
                    HStack {
                        Text("Emoji")
                        Spacer()
                        TextField("🍬", text: $emoji)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                    }
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("e.g. Juice box", text: $name)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                }
                .listRowBackground(Color.chart)

                Section(header: Text("Macros")) {
                    HStack {
                        Text("Carbs")
                        Spacer()
                        TextField("0", text: $carbsText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                        Text("g").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Fat (optional)")
                        Spacer()
                        TextField("", text: $fatText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                        Text("g").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Protein (optional)")
                        Spacer()
                        TextField("", text: $proteinText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                        Text("g").foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("Notes (optional)"),
                    footer: Text("Free-text. Appears in the picker — useful for absorption hints like 'fast onset, ~20 min'.")
                ) {
                    TextField("", text: $notes, axis: .vertical)
                        .lineLimit(2 ... 4)
                }
                .listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(preset == nil ? "Add Preset" : "Edit Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || parsedCarbs <= 0)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var parsedCarbs: Decimal {
        Decimal(string: carbsText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var parsedFat: Decimal? {
        let t = fatText.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : Decimal(string: t.replacingOccurrences(of: ",", with: "."))
    }

    private var parsedProtein: Decimal? {
        let t = proteinText.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : Decimal(string: t.replacingOccurrences(of: ",", with: "."))
    }

    private func save() {
        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespaces)
        let result = RescuePreset(
            id: preset?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            carbs: parsedCarbs,
            fat: parsedFat,
            protein: parsedProtein,
            emoji: trimmedEmoji.isEmpty ? nil : trimmedEmoji,
            notes: notes.isEmpty ? nil : notes
        )
        onSave(result)
        dismiss()
    }

    private static func format(_ d: Decimal) -> String {
        let dn = NSDecimalNumber(decimal: d).doubleValue
        return dn.rounded() == dn ? "\(Int(dn))" : String(format: "%.1f", dn)
    }

    /// Local non-static accessor for use inside instance initializer.
    private func format(_ d: Decimal) -> String { Self.format(d) }
}

@MainActor
private final class ViewModel: ObservableObject {
    @Published var presets: [RescuePreset] = []

    private let resolver: Resolver = TrioApp.resolver
    private lazy var settingsManager: SettingsManager? = resolver.resolve(SettingsManager.self)

    func reload() {
        guard let s = settingsManager?.settings else { return }
        presets = s.rescuePresets
    }

    func add(_ preset: RescuePreset) {
        guard var s = settingsManager?.settings else { return }
        s.rescuePresets.append(preset)
        settingsManager?.settings = s
        presets = s.rescuePresets
    }

    func update(_ preset: RescuePreset) {
        guard var s = settingsManager?.settings else { return }
        if let idx = s.rescuePresets.firstIndex(where: { $0.id == preset.id }) {
            s.rescuePresets[idx] = preset
            settingsManager?.settings = s
            presets = s.rescuePresets
        }
    }

    func delete(at offsets: IndexSet) {
        guard var s = settingsManager?.settings else { return }
        s.rescuePresets.remove(atOffsets: offsets)
        settingsManager?.settings = s
        presets = s.rescuePresets
    }

    func move(from source: IndexSet, to destination: Int) {
        guard var s = settingsManager?.settings else { return }
        s.rescuePresets.move(fromOffsets: source, toOffset: destination)
        settingsManager?.settings = s
        presets = s.rescuePresets
    }
}
