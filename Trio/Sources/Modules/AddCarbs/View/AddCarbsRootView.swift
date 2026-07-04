import CoreData
import SwiftUI
import Swinject

extension AddCarbs {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()
        @State var dish: String = ""
        @State var isPromtPresented = false
        @State var noteSaved = false
        @State var mealSaved = false
        @State private var showAlert = false
        @FocusState private var isFocused: Bool

        @FetchRequest(
            entity: Presets.entity(),
            sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)]
        ) var carbPresets: FetchedResults<Presets>

        @Environment(\.managedObjectContext) var moc

        private var formatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1
            return formatter
        }

        var body: some View {
            Form {
                if let carbsReq = state.carbsRequired {
                    Section {
                        HStack {
                            Text("Carbs required")
                            Spacer()
                            Text(formatter.string(from: carbsReq as NSNumber)! + " g")
                        }
                    }
                }
                Section {
                    HStack {
                        Text("Carbs").fontWeight(.semibold)
                        Spacer()
                        TextFieldWithToolBar(
                            text: $state.carbs,
                            placeholder: "0",
                            shouldBecomeFirstResponder: true,
                            numberFormatter: formatter
                        )
                        Text(state.carbs > state.maxCarbs ? "⚠️" : "g").foregroundColor(.secondary)
                    }.padding(.vertical)

                    // Quick-add carb buttons
                    HStack(spacing: 12) {
                        Text("Quick Add:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button(action: {
                            state.carbs += 5
                        }) {
                            Text("+5g")
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.blue.opacity(0.15))
                                .foregroundColor(.blue)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            state.carbs += 10
                        }) {
                            Text("+10g")
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.blue.opacity(0.15))
                                .foregroundColor(.blue)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        // Clear button
                        if state.carbs > 0 {
                            Button(action: {
                                state.carbs = 0
                            }) {
                                Text("Clear")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if state.useFPUconversion {
                        proteinAndFat()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Note").foregroundColor(.secondary)
                            Spacer()
                            if isFocused {
                                Button { isFocused = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                                    .controlSize(.mini)
                            }
                        }
                        TextEditor(text: Binding(
                            get: { state.note },
                            set: { newValue in
                                // Hard cap at 500 chars — schema is unlimited but
                                // keep the UI from becoming a dumping ground.
                                state.note = String(newValue.prefix(500))
                            }
                        ))
                        .frame(minHeight: 72, maxHeight: 160)
                        .focused($isFocused)
                        .scrollContentBackground(.hidden)

                        if state.note.count > 375 {
                            // Counter only appears in the last 25% — otherwise it's
                            // visual noise on typical short notes.
                            HStack {
                                Spacer()
                                Text("\(state.note.count) / 500")
                                    .font(.caption)
                                    .foregroundStyle(state.note.count >= 500 ? .red : .secondary)
                            }
                        }
                    }

                    tagsSection()
                    HStack {
                        Button {
                            state.useFPUconversion.toggle()
                        }
                        label: {
                            Text(
                                state
                                    .useFPUconversion ? NSLocalizedString("Hide Fat & Protein", comment: "") :
                                    NSLocalizedString("Fat & Protein", comment: "")
                            ) }
                            .controlSize(.mini)
                            .buttonStyle(BorderlessButtonStyle())
                        Button {
                            isPromtPresented = true
                        }
                        label: { Text("Save as Preset") }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .controlSize(.mini)
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(
                                (state.carbs <= 0 && state.fat <= 0 && state.protein <= 0) ||
                                    (
                                        (((state.selection?.carbs ?? 0) as NSDecimalNumber) as Decimal) == state
                                            .carbs && (((state.selection?.fat ?? 0) as NSDecimalNumber) as Decimal) == state
                                            .fat && (((state.selection?.protein ?? 0) as NSDecimalNumber) as Decimal) ==
                                            state
                                            .protein
                                    ) ? .secondary : .orange
                            )
                            .disabled(
                                (state.carbs <= 0 && state.fat <= 0 && state.protein <= 0) ||
                                    (
                                        (((state.selection?.carbs ?? 0) as NSDecimalNumber) as Decimal) == state
                                            .carbs && (((state.selection?.fat ?? 0) as NSDecimalNumber) as Decimal) == state
                                            .fat && (((state.selection?.protein ?? 0) as NSDecimalNumber) as Decimal) == state
                                            .protein
                                    )
                            )
                    }
                    .popover(isPresented: $isPromtPresented) {
                        presetPopover
                    }
                }

                if state.useFPUconversion {
                    Section {
                        mealPresets
                    }
                }

                Section {
                    DatePicker("Date", selection: $state.date)
                }

                Section {
                    Button {
                        mealSaved = true
                        state.add()
                    }
                    label: { Text(state.saveButtonText()).font(.title3) }
                        .disabled(
                            mealSaved
                                || state.carbs > state.maxCarbs
                                || state.fat > state.maxFat
                                || state.protein > state.maxProtein
                                || (state.carbs <= 0 && state.fat <= 0 && state.protein <= 0)
                        )
                        .foregroundStyle(
                            mealSaved || (state.carbs <= 0 && state.fat <= 0 && state.protein <= 0) ? .gray :
                                state.carbs > state.maxCarbs || state.fat > state.maxFat || state.protein > state
                                .maxProtein ? .red : .blue
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                } footer: { Text(state.waitersNotepad().description) }

                if !state.useFPUconversion {
                    Section {
                        mealPresets
                    }
                }
            }
            .onAppear(perform: configureView)
            .navigationBarItems(leading: Button("Close", action: state.hideModal))
        }

        var presetPopover: some View {
            Form {
                Section {
                    TextField("Name Of Dish", text: $dish)
                    Button {
                        noteSaved = true
                        if dish != "", noteSaved {
                            let preset = Presets(context: moc)
                            preset.dish = dish
                            preset.fat = state.fat as NSDecimalNumber
                            preset.protein = state.protein as NSDecimalNumber
                            preset.carbs = state.carbs as NSDecimalNumber
                            try? moc.save()
                            state.addNewPresetToWaitersNotepad(dish)
                            noteSaved = false
                            isPromtPresented = false
                        }
                    }
                    label: { Text("Save") }
                    Button {
                        dish = ""
                        noteSaved = false
                        isPromtPresented = false }
                    label: { Text("Cancel") }
                } header: { Text("Enter Meal Preset Name") }
            }
        }

        var mealPresets: some View {
            Section {
                VStack {
                    Picker("Meal Presets", selection: $state.selection) {
                        Text("Empty").tag(nil as Presets?)
                        ForEach(carbPresets, id: \.self) { (preset: Presets) in
                            Text(preset.dish ?? "").tag(preset as Presets?)
                        }
                    }
                    .pickerStyle(.automatic)
                    ._onBindingChange($state.selection) { _ in
                        state.carbs += ((state.selection?.carbs ?? 0) as NSDecimalNumber) as Decimal
                        state.fat += ((state.selection?.fat ?? 0) as NSDecimalNumber) as Decimal
                        state.protein += ((state.selection?.protein ?? 0) as NSDecimalNumber) as Decimal
                        state.addToSummation()
                    }
                }
                HStack {
                    Button("Delete Preset") {
                        showAlert.toggle()
                    }
                    .disabled(state.selection == nil)
                    .accentColor(.orange)
                    .buttonStyle(BorderlessButtonStyle())
                    .alert(
                        "Delete preset '\(state.selection?.dish ?? "")'?",
                        isPresented: $showAlert,
                        actions: {
                            Button("No", role: .cancel) {}
                            Button("Yes", role: .destructive) {
                                state.deletePreset()

                                state.carbs += ((state.selection?.carbs ?? 0) as NSDecimalNumber) as Decimal
                                state.fat += ((state.selection?.fat ?? 0) as NSDecimalNumber) as Decimal
                                state.protein += ((state.selection?.protein ?? 0) as NSDecimalNumber) as Decimal

                                state.addPresetToNewMeal()
                            }
                        }
                    )
                    Button {
                        if state.carbs != 0,
                           (state.carbs - (((state.selection?.carbs ?? 0) as NSDecimalNumber) as Decimal) as Decimal) >= 0
                        {
                            state.carbs -= (((state.selection?.carbs ?? 0) as NSDecimalNumber) as Decimal)
                        } else { state.carbs = 0 }

                        if state.fat != 0,
                           (state.fat - (((state.selection?.fat ?? 0) as NSDecimalNumber) as Decimal) as Decimal) >= 0
                        {
                            state.fat -= (((state.selection?.fat ?? 0) as NSDecimalNumber) as Decimal)
                        } else { state.fat = 0 }

                        if state.protein != 0,
                           (state.protein - (((state.selection?.protein ?? 0) as NSDecimalNumber) as Decimal) as Decimal) >= 0
                        {
                            state.protein -= (((state.selection?.protein ?? 0) as NSDecimalNumber) as Decimal)
                        } else { state.protein = 0 }

                        state.removePresetFromNewMeal()
                        if state.carbs == 0, state.fat == 0, state.protein == 0 { state.summation = [] }
                    }
                    label: { Text("[ -1 ]") }
                        .disabled(
                            state
                                .selection == nil ||
                                (
                                    !state.summation.contains(state.selection?.dish ?? "") && (state.selection?.dish ?? "") != ""
                                )
                        )
                        .buttonStyle(BorderlessButtonStyle())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accentColor(.minus)
                    Button {
                        state.carbs += ((state.selection?.carbs ?? 0) as NSDecimalNumber) as Decimal
                        state.fat += ((state.selection?.fat ?? 0) as NSDecimalNumber) as Decimal
                        state.protein += ((state.selection?.protein ?? 0) as NSDecimalNumber) as Decimal

                        state.addPresetToNewMeal()
                    }
                    label: { Text("[ +1 ]") }
                        .disabled(state.selection == nil)
                        .buttonStyle(BorderlessButtonStyle())
                        .accentColor(.blue)
                }
            }
        }

        @ViewBuilder private func proteinAndFat() -> some View {
            HStack {
                Text("Fat").foregroundColor(.orange) // .fontWeight(.thin)
                Spacer()
                TextFieldWithToolBar(text: $state.fat, placeholder: "0", numberFormatter: formatter)
                Text(state.fat > state.maxFat ? "⚠️" : "g").foregroundColor(.secondary)
            }
            HStack {
                Text("Protein").foregroundColor(.red) // .fontWeight(.thin)
                Spacer()
                TextFieldWithToolBar(text: $state.protein, placeholder: "0", numberFormatter: formatter)
                Text(state.protein > state.maxProtein ? "⚠️" : "g").foregroundColor(.secondary)
            }
        }

        @State private var showTagPickerSheet = false

        @ViewBuilder private func tagsSection() -> some View {
            let library = TrioApp.resolver.resolve(SettingsManager.self)?.settings.mealTags ?? []
            let categories = TrioApp.resolver.resolve(SettingsManager.self)?.settings.tagCategories ?? []
            let picked = library
                .filter { state.tagIDs.contains($0.id) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Tags").foregroundColor(.secondary)
                    Spacer()
                    Button {
                        showTagPickerSheet = true
                    } label: {
                        Text(picked.isEmpty ? "Add" : "Edit")
                            .font(.caption)
                    }
                }
                if !picked.isEmpty {
                    FlowLayoutWrap(spacing: 6) {
                        ForEach(picked) { tag in
                            Text(tag.name)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.blue.opacity(0.15)))
                        }
                    }
                }
            }
            .sheet(isPresented: $showTagPickerSheet) {
                SavedMealTagPickerSheet(
                    allTags: library,
                    allCategories: categories,
                    selectedIDs: state.tagIDs
                ) { newSelection in
                    state.tagIDs = newSelection
                }
            }
        }
    }
}
