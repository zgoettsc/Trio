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

    @State private var selectedTagIDs: Set<UUID> = []
    @State private var showTagPicker = false

    private let resolver: Resolver = TrioApp.resolver
    private var storage: SavedMealStorage? { resolver.resolve(SavedMealStorage.self) }
    private var settingsManager: SettingsManager? { resolver.resolve(SettingsManager.self) }

    private var allTags: [MealTag] { settingsManager?.settings.mealTags ?? [] }
    private var allCategories: [TagCategory] { settingsManager?.settings.tagCategories ?? [] }
    private var selectedTags: [MealTag] {
        allTags
            .filter { selectedTagIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

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
                header: Text("Tags"),
                footer: Text("Optional. Tags surface this meal in analytics (\"how do high-fat meals behave?\"). Manage the tag library in AI Insights → Tags & Categories.")
            ) {
                if selectedTags.isEmpty {
                    Text("No tags").font(.caption).foregroundStyle(.secondary)
                } else {
                    tagChipFlow(selectedTags)
                }
                Button {
                    showTagPicker = true
                } label: {
                    Label(selectedTags.isEmpty ? "Add tags" : "Edit tags", systemImage: "tag")
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
        .sheet(isPresented: $showTagPicker) {
            SavedMealTagPickerSheet(
                allTags: allTags,
                allCategories: allCategories,
                selectedIDs: selectedTagIDs
            ) { newSelection in
                selectedTagIDs = newSelection
            }
        }
    }

    @ViewBuilder
    private func tagChipFlow(_ tags: [MealTag]) -> some View {
        // Wrapping flow of compact chips. SwiftUI's FlowLayout is iOS 16+.
        FlowLayoutWrap(spacing: 6) {
            ForEach(tags) { tag in
                Text(tag.name)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.blue.opacity(0.15)))
                    .foregroundStyle(.primary)
            }
        }
    }

    private func loadFromMeal() {
        guard let m = meal else { return }
        selectedTagIDs = Set(m.tagIDs)
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
                m.tagIDs = Array(selectedTagIDs)
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
                    m.tagIDs = Array(selectedTagIDs)
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

/// Multi-select tag picker. Tags are grouped by category, with a
/// "Manage tag library" link routing to the full editor when the
/// user wants to rename / add categories / etc. Inline "+ New tag"
/// at the top lets the user add a tag on the fly with no categories
/// — they can categorize it later from the management screen.
struct SavedMealTagPickerSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    let allTags: [MealTag]
    let allCategories: [TagCategory]
    let initialSelection: Set<UUID>
    let onSave: (Set<UUID>) -> Void

    @State private var selection: Set<UUID>
    @State private var search: String = ""
    @State private var newTagDraft: String = ""

    private let resolver: Resolver = TrioApp.resolver
    private var settingsManager: SettingsManager? { resolver.resolve(SettingsManager.self) }

    init(
        allTags: [MealTag],
        allCategories: [TagCategory],
        selectedIDs: Set<UUID>,
        onSave: @escaping (Set<UUID>) -> Void
    ) {
        self.allTags = allTags
        self.allCategories = allCategories
        initialSelection = selectedIDs
        self.onSave = onSave
        _selection = State(initialValue: selectedIDs)
    }

    private var filteredTags: [MealTag] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return allTags }
        let q = search.lowercased()
        return allTags.filter { $0.name.lowercased().contains(q) }
    }

    private func tags(in category: TagCategory) -> [MealTag] {
        filteredTags
            .filter { $0.categoryIds.contains(category.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var uncategorizedTags: [MealTag] {
        filteredTags
            .filter { $0.categoryIds.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search tags", text: $search)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                .listRowBackground(Color.chart)

                // Inline "create new tag" — adds to library uncategorized, selects it.
                Section(
                    header: Text("Add new"),
                    footer: Text("Adds the tag uncategorized. Go to Tags & Categories to assign categories.")
                ) {
                    HStack {
                        TextField("e.g. chicken", text: $newTagDraft)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button {
                            addNewTag()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newTagDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .listRowBackground(Color.chart)

                ForEach(allCategories) { category in
                    let inCat = tags(in: category)
                    if !inCat.isEmpty {
                        Section(header: categoryHeader(category)) {
                            ForEach(inCat) { tag in
                                tagRow(tag)
                            }
                        }
                        .listRowBackground(Color.chart)
                    }
                }

                if !uncategorizedTags.isEmpty {
                    Section(header: Text("Uncategorized")) {
                        ForEach(uncategorizedTags) { tag in
                            tagRow(tag)
                        }
                    }
                    .listRowBackground(Color.chart)
                }

                if allTags.isEmpty {
                    Section {
                        Text("No tags yet. Add one above, or open Tags & Categories to seed the library.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        NavigationLink(destination: TagsAndCategoriesConfigView()) {
                            Label("Tags & Categories", systemImage: "tag")
                        }
                    }
                    .listRowBackground(Color.chart)
                } else {
                    Section {
                        NavigationLink(destination: TagsAndCategoriesConfigView()) {
                            Label("Manage tag library", systemImage: "tag")
                        }
                    }
                    .listRowBackground(Color.chart)
                }
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onSave(selection)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func tagRow(_ tag: MealTag) -> some View {
        Button {
            if selection.contains(tag.id) {
                selection.remove(tag.id)
            } else {
                selection.insert(tag.id)
            }
        } label: {
            HStack {
                Image(systemName: selection.contains(tag.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selection.contains(tag.id) ? .blue : .secondary)
                Text(tag.name).foregroundStyle(.primary)
                if tag.categoryIds.count > 1 {
                    Text("· in \(tag.categoryIds.count) categories")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    private func categoryHeader(_ c: TagCategory) -> some View {
        HStack(spacing: 6) {
            if let s = c.iconSymbol {
                Image(systemName: s)
            }
            Text(c.name)
        }
    }

    private func addNewTag() {
        let trimmed = newTagDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Reuse existing tag if name (case-insensitive) already exists.
        if let existing = allTags.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            selection.insert(existing.id)
            newTagDraft = ""
            return
        }
        guard var s = settingsManager?.settings else { return }
        let tag = MealTag(name: trimmed)
        s.mealTags.append(tag)
        settingsManager?.settings = s
        selection.insert(tag.id)
        newTagDraft = ""
    }
}

/// Minimal wrap-flow layout for chips. Uses the iOS 16+ Layout protocol.
struct FlowLayoutWrap: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width + spacing
                rowHeight = size.height
            } else {
                rowWidth += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
