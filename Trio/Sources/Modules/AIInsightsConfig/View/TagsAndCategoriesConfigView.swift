import Foundation
import SwiftUI
import Swinject

/// Settings screen for managing the user's tag library and categories.
/// Tags belong to one or more categories (beans → Protein + Carbs).
/// Browse / add / rename / delete on both axes.
///
/// Stable-UUID model: renames cascade through all tagged meals
/// automatically (meals store tag UUIDs, not names). Deleting a tag
/// shows a confirmation listing affected saved meals; deleting a
/// category orphans its tags rather than deleting them — those tags
/// simply lose that category membership.
struct TagsAndCategoriesConfigView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    @StateObject private var vm = ViewModel()
    @State private var addingTagInCategory: TagCategory?
    @State private var editingTag: MealTag?
    @State private var editingCategory: TagCategory?
    @State private var showAddCategory = false
    @State private var pendingTagDeletion: MealTag?
    @State private var pendingCategoryDeletion: TagCategory?

    var body: some View {
        formContent
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Tags & Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            .modifier(SheetsModifier(
                vm: vm,
                addingTagInCategory: $addingTagInCategory,
                editingTag: $editingTag,
                editingCategory: $editingCategory,
                showAddCategory: $showAddCategory
            ))
            .modifier(ConfirmDialogsModifier(
                vm: vm,
                pendingTagDeletion: $pendingTagDeletion,
                pendingCategoryDeletion: $pendingCategoryDeletion
            ))
            .onAppear { vm.reload() }
    }

    @ViewBuilder
    private var formContent: some View {
        Form {
            categoriesSection
            uncategorizedSection
        }
    }

    @ViewBuilder
    private var categoriesSection: some View {
        Section(
            header: Text("Categories"),
            footer: Text("Tags belong to one or more categories. Renaming cascades through every tagged meal. Deleting a category doesn't delete its tags — they just lose that membership.")
        ) {
            ForEach(vm.categories) { category in
                categoryRow(category)
            }
            .onDelete { offsets in
                for off in offsets {
                    pendingCategoryDeletion = vm.categories[off]
                }
            }

            Button {
                showAddCategory = true
            } label: {
                Label("Add Category", systemImage: "plus.circle.fill")
            }
        }
        .listRowBackground(Color.chart)
    }

    @ViewBuilder
    private func categoryRow(_ category: TagCategory) -> some View {
        DisclosureGroup {
            categoryContent(category)
        } label: {
            categoryLabel(category)
        }
    }

    @ViewBuilder
    private func categoryContent(_ category: TagCategory) -> some View {
        let tagsInCategory = vm.tags(in: category)
        if tagsInCategory.isEmpty {
            Text("No tags yet").font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(tagsInCategory) { tag in
                tagRowButton(tag)
            }
            .onDelete { offsets in
                for off in offsets {
                    pendingTagDeletion = tagsInCategory[off]
                }
            }
        }

        Button {
            addingTagInCategory = category
        } label: {
            Label("Add tag to \(category.name)", systemImage: "plus")
                .font(.caption)
        }
    }

    @ViewBuilder
    private func categoryLabel(_ category: TagCategory) -> some View {
        HStack {
            if let symbol = category.iconSymbol {
                Image(systemName: symbol)
                    .foregroundStyle(categoryColor(category))
            }
            Text(category.name).fontWeight(.medium)
            Spacer()
            Text("\(vm.tags(in: category).count)").foregroundStyle(.secondary).font(.caption)
            Button {
                editingCategory = category
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.blue)
                    .padding(.leading, 8)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func tagRowButton(_ tag: MealTag) -> some View {
        Button {
            editingTag = tag
        } label: {
            HStack {
                Text(tag.name).foregroundStyle(.primary)
                if tag.categoryIds.count > 1 {
                    Text("· in \(tag.categoryIds.count) categories")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
            }
        }
    }

    @ViewBuilder
    private var uncategorizedSection: some View {
        let uncategorized = vm.uncategorizedTags
        if !uncategorized.isEmpty {
            Section(
                header: Text("Uncategorized (\(uncategorized.count))"),
                footer: Text("Tags with no category membership. Tap to add categories or delete.")
            ) {
                ForEach(uncategorized) { tag in
                    Button {
                        editingTag = tag
                    } label: {
                        HStack {
                            Text(tag.name).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                        }
                    }
                }
                .onDelete { offsets in
                    for off in offsets {
                        pendingTagDeletion = uncategorized[off]
                    }
                }
            }
            .listRowBackground(Color.chart)
        }
    }

    private func categoryColor(_ c: TagCategory) -> Color {
        guard let hex = c.colorHex else { return .secondary }
        return Color(hex: hex) ?? .secondary
    }
}

/// Bundles the four sheet modifiers so the parent body stays small
/// enough for the type-checker to handle quickly.
private struct SheetsModifier: ViewModifier {
    @ObservedObject var vm: ViewModel
    @Binding var addingTagInCategory: TagCategory?
    @Binding var editingTag: MealTag?
    @Binding var editingCategory: TagCategory?
    @Binding var showAddCategory: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: $addingTagInCategory) { category in
                TagEditSheet(
                    tag: nil,
                    presetCategoryId: category.id,
                    allCategories: vm.categories
                ) { newTag in
                    vm.addTag(newTag)
                }
            }
            .sheet(item: $editingTag) { tag in
                TagEditSheet(
                    tag: tag,
                    presetCategoryId: nil,
                    allCategories: vm.categories
                ) { updated in
                    vm.updateTag(updated)
                }
            }
            .sheet(item: $editingCategory) { category in
                CategoryEditSheet(category: category) { updated in
                    vm.updateCategory(updated)
                }
            }
            .sheet(isPresented: $showAddCategory) {
                CategoryEditSheet(category: nil) { newCategory in
                    vm.addCategory(newCategory)
                }
            }
    }
}

/// Bundles the two confirmation-dialog modifiers off the main body.
private struct ConfirmDialogsModifier: ViewModifier {
    @ObservedObject var vm: ViewModel
    @Binding var pendingTagDeletion: MealTag?
    @Binding var pendingCategoryDeletion: TagCategory?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                pendingTagDeletion.map { "Delete tag \"\($0.name)\"?" } ?? "",
                isPresented: Binding(
                    get: { pendingTagDeletion != nil },
                    set: { if !$0 { pendingTagDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingTagDeletion
            ) { tag in
                let usage = vm.mealsUsingTag(tag.id)
                Button(
                    usage > 0
                        ? "Delete and remove from \(usage) meal\(usage == 1 ? "" : "s")"
                        : "Delete",
                    role: .destructive
                ) {
                    vm.deleteTag(tag)
                    pendingTagDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingTagDeletion = nil
                }
            } message: { tag in
                let usage = vm.mealsUsingTag(tag.id)
                Text(
                    usage > 0
                        ? "This tag is on \(usage) saved meal\(usage == 1 ? "" : "s"). Deleting it removes the tag from those meals."
                        : "This tag is not currently assigned to any meal."
                )
            }
            .confirmationDialog(
                pendingCategoryDeletion.map { "Delete category \"\($0.name)\"?" } ?? "",
                isPresented: Binding(
                    get: { pendingCategoryDeletion != nil },
                    set: { if !$0 { pendingCategoryDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingCategoryDeletion
            ) { category in
                Button("Delete category", role: .destructive) {
                    vm.deleteCategory(category)
                    pendingCategoryDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingCategoryDeletion = nil
                }
            } message: { category in
                let count = vm.tags(in: category).count
                Text(
                    count > 0
                        ? "\(count) tag\(count == 1 ? "" : "s") currently in this category will lose this membership. They are NOT deleted — they remain in any other categories they belong to, or become Uncategorized."
                        : "This category has no tags."
                )
            }
    }
}

/// Add or edit a single tag — including which categories it belongs to.
private struct TagEditSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    let tag: MealTag?
    let presetCategoryId: UUID?
    let allCategories: [TagCategory]
    let onSave: (MealTag) -> Void

    @State private var name: String
    @State private var notes: String
    @State private var selectedCategoryIds: Set<UUID>

    init(
        tag: MealTag?,
        presetCategoryId: UUID?,
        allCategories: [TagCategory],
        onSave: @escaping (MealTag) -> Void
    ) {
        self.tag = tag
        self.presetCategoryId = presetCategoryId
        self.allCategories = allCategories
        self.onSave = onSave
        _name = State(initialValue: tag?.name ?? "")
        _notes = State(initialValue: tag?.notes ?? "")
        if let tag {
            _selectedCategoryIds = State(initialValue: tag.categoryIds)
        } else if let presetCategoryId {
            _selectedCategoryIds = State(initialValue: [presetCategoryId])
        } else {
            _selectedCategoryIds = State(initialValue: [])
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Tag name")) {
                    TextField("e.g. chicken", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .listRowBackground(Color.chart)

                Section(
                    header: Text("Categories"),
                    footer: Text("Multi-select. A tag like \"beans\" can be in both Protein and Carbs. Leave empty for Uncategorized.")
                ) {
                    ForEach(allCategories) { category in
                        Button {
                            if selectedCategoryIds.contains(category.id) {
                                selectedCategoryIds.remove(category.id)
                            } else {
                                selectedCategoryIds.insert(category.id)
                            }
                        } label: {
                            HStack {
                                Image(systemName: selectedCategoryIds.contains(category.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedCategoryIds.contains(category.id) ? .blue : .secondary)
                                Text(category.name).foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                    }
                }
                .listRowBackground(Color.chart)

                Section(header: Text("Notes (optional)")) {
                    TextField("", text: $notes, axis: .vertical)
                        .lineLimit(2 ... 4)
                }
                .listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(tag == nil ? "Add Tag" : "Edit Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        let result = MealTag(
                            id: tag?.id ?? UUID(),
                            name: trimmed,
                            categoryIds: selectedCategoryIds,
                            notes: notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes
                        )
                        onSave(result)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// Add or edit a single category.
private struct CategoryEditSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    let category: TagCategory?
    let onSave: (TagCategory) -> Void

    @State private var name: String

    init(category: TagCategory?, onSave: @escaping (TagCategory) -> Void) {
        self.category = category
        self.onSave = onSave
        _name = State(initialValue: category?.name ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Category name")) {
                    TextField("e.g. Protein", text: $name)
                        .autocorrectionDisabled()
                }
                .listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle(category == nil ? "Add Category" : "Edit Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        let result = TagCategory(
                            id: category?.id ?? UUID(),
                            name: trimmed,
                            colorHex: category?.colorHex,
                            iconSymbol: category?.iconSymbol
                        )
                        onSave(result)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

@MainActor
private final class ViewModel: ObservableObject {
    @Published var categories: [TagCategory] = []
    @Published var tags: [MealTag] = []

    private let resolver: Resolver = TrioApp.resolver
    private lazy var settingsManager: SettingsManager? = resolver.resolve(SettingsManager.self)

    var uncategorizedTags: [MealTag] {
        tags.filter { $0.categoryIds.isEmpty }
    }

    func tags(in category: TagCategory) -> [MealTag] {
        tags
            .filter { $0.categoryIds.contains(category.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func reload() {
        guard let s = settingsManager?.settings else { return }
        categories = s.tagCategories
        tags = s.mealTags
    }

    func addCategory(_ c: TagCategory) {
        guard var s = settingsManager?.settings else { return }
        s.tagCategories.append(c)
        settingsManager?.settings = s
        categories = s.tagCategories
    }

    func updateCategory(_ c: TagCategory) {
        guard var s = settingsManager?.settings else { return }
        if let idx = s.tagCategories.firstIndex(where: { $0.id == c.id }) {
            s.tagCategories[idx] = c
            settingsManager?.settings = s
            categories = s.tagCategories
        }
    }

    func deleteCategory(_ c: TagCategory) {
        guard var s = settingsManager?.settings else { return }
        s.tagCategories.removeAll { $0.id == c.id }
        // Strip this category from every tag (orphan, don't delete).
        for i in s.mealTags.indices {
            s.mealTags[i].categoryIds.remove(c.id)
        }
        settingsManager?.settings = s
        categories = s.tagCategories
        tags = s.mealTags
    }

    func addTag(_ tag: MealTag) {
        guard var s = settingsManager?.settings else { return }
        s.mealTags.append(tag)
        settingsManager?.settings = s
        tags = s.mealTags
    }

    func updateTag(_ tag: MealTag) {
        guard var s = settingsManager?.settings else { return }
        if let idx = s.mealTags.firstIndex(where: { $0.id == tag.id }) {
            s.mealTags[idx] = tag
            settingsManager?.settings = s
            tags = s.mealTags
        }
    }

    func deleteTag(_ tag: MealTag) {
        guard var s = settingsManager?.settings else { return }
        s.mealTags.removeAll { $0.id == tag.id }
        settingsManager?.settings = s
        tags = s.mealTags
        // Also remove the UUID from any SavedMeal that referenced it.
        removeTagFromAllMeals(id: tag.id)
    }

    func mealsUsingTag(_ id: UUID) -> Int {
        let ctx = CoreDataStack.shared.persistentContainer.viewContext
        var count = 0
        ctx.performAndWait {
            let req = SavedMeal.fetchRequest()
            let meals = (try? ctx.fetch(req)) ?? []
            for m in meals where m.tagIDs.contains(id) {
                count += 1
            }
        }
        return count
    }

    private func removeTagFromAllMeals(id: UUID) {
        let ctx = CoreDataStack.shared.newTaskContext()
        ctx.perform {
            let req = SavedMeal.fetchRequest()
            let meals = (try? ctx.fetch(req)) ?? []
            var changed = false
            for m in meals where m.tagIDs.contains(id) {
                m.tagIDs = m.tagIDs.filter { $0 != id }
                changed = true
            }
            if changed { try? ctx.save() }
        }
    }
}

// MARK: - Color hex helper

private extension Color {
    init?(hex: String) {
        var hex = hex
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
