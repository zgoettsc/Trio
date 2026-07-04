//
//  CarbEntryEditorView.swift
//  FreeAPS
//
//  Created by Marvin Polscheit on 15.01.25.
//
import CoreData
import SwiftUI

struct CarbEntryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var state: History.StateModel
    let carbEntry: CarbEntryStored

    /*
     This is the objectID of the entry that the user is editing. It is NOT always the `carbEntry: CarbEntryStored` that we pass to the `CarbEntryEditorView`.
     We need this because FPUs and carbs are treated completely different and that complicates the update process.
     */
    @State private var entryToEdit: NSManagedObjectID?

    @State private var editedCarbs: Decimal
    @State private var editedFat: Decimal
    @State private var editedProtein: Decimal
    @State private var editedNote: String
    @State private var isFPU: Bool
    @State private var editedDate: Date
    @State private var originalCarbs: Decimal = 0
    @State private var editedTagIDs: Set<UUID> = []
    @State private var showTagPicker = false

    init(state: History.StateModel, carbEntry: CarbEntryStored) {
        self.state = state
        self.carbEntry = carbEntry
        _editedCarbs = State(initialValue: 0) // gets updated in the task block
        _editedFat = State(initialValue: 0) // gets updated in the task block
        _editedProtein = State(initialValue: 0) // gets updated in the task block
        _editedNote = State(initialValue: carbEntry.note ?? "")
        _isFPU = State(initialValue: carbEntry.isFPU)
        _entryToEdit = State(initialValue: nil)
        _editedDate = State(initialValue: Date())
    }

    /// True when the user has bumped carbs on an already-committed entry.
    /// Historical oref decisions can't be re-run, so this is a soft warn.
    private var carbsEditedFromOriginal: Bool {
        editedCarbs != originalCarbs
    }

    private var mealFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumIntegerDigits = 3
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private var carbLimitExceeded: Bool {
        editedCarbs > state.settingsManager.settings.maxCarbs
    }

    private var fatLimitExceeded: Bool {
        editedFat > state.settingsManager.settings.maxFat
    }

    private var proteinLimitExceeded: Bool {
        editedProtein > state.settingsManager.settings.maxProtein
    }

    private var limitExceeded: Bool {
        carbLimitExceeded || fatLimitExceeded || proteinLimitExceeded
    }

    private var isButtonDisabled: Bool {
        editedCarbs == 0 && editedFat == 0 && editedProtein == 0
    }

    private var buttonLabel: some View {
        if carbLimitExceeded {
            return Text("Max Carbs of \(state.settingsManager.settings.maxCarbs.description) g Exceeded")
        } else if fatLimitExceeded {
            return Text("Max Fat of \(state.settingsManager.settings.maxFat.description) g Exceeded")
        } else if proteinLimitExceeded {
            return Text("Max Protein of \(state.settingsManager.settings.maxProtein.description) g Exceeded")
        }

        return Text("Save and Update")
    }

    private var buttonBackgroundColor: Color {
        var treatmentButtonBackground = Color(.systemBlue)
        if limitExceeded {
            treatmentButtonBackground = Color(.systemRed)
        } else if isButtonDisabled {
            treatmentButtonBackground = Color(.systemGray)
        }

        return treatmentButtonBackground
    }

    var stickyButton: some View {
        ZStack {
            Rectangle()
                .frame(width: UIScreen.main.bounds.width, height: 65)
                .foregroundStyle(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color.white)
                .background(.thinMaterial)
                .opacity(0.8)
                .clipShape(Rectangle())

            Button(
                action: {
                    guard let entryToEdit = entryToEdit else { return }

                    state.updateEntry(
                        entryToEdit,
                        newCarbs: editedCarbs,
                        newFat: editedFat,
                        newProtein: editedProtein,
                        newNote: editedNote,
                        newDate: editedDate,
                        newTagIDs: Array(editedTagIDs)
                    )
                    dismiss()
                }, label: {
                    buttonLabel
                        .font(.headline)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(10)
                }
            )
            .frame(width: UIScreen.main.bounds.width * 0.9, height: 40, alignment: .center)
            .disabled(isButtonDisabled)
            .background(buttonBackgroundColor)
            .tint(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("Carbs")
                        TextFieldWithToolBar(
                            text: $editedCarbs,
                            placeholder: "0",
                            keyboardType: .numberPad,
                            numberFormatter: mealFormatter,
                            unitsText: String(localized: "g", comment: "Units for carbs")
                        )
                    }

                    if state.settingsManager.settings.useFPUconversion {
                        HStack {
                            Text("Fat")
                            TextFieldWithToolBar(
                                text: $editedFat,
                                placeholder: "0",
                                keyboardType: .numberPad,
                                numberFormatter: mealFormatter,
                                unitsText: String(localized: "g", comment: "Units for carbs")
                            )
                        }

                        HStack {
                            Text("Protein")
                            TextFieldWithToolBar(
                                text: $editedProtein,
                                placeholder: "0",
                                keyboardType: .numberPad,
                                numberFormatter: mealFormatter,
                                unitsText: String(localized: "g", comment: "Units for carbs")
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "square.and.pencil")
                            Text("Note").foregroundStyle(.secondary)
                        }
                        TextEditor(text: Binding(
                            get: { editedNote },
                            set: { editedNote = String($0.prefix(500)) }
                        ))
                        .frame(minHeight: 72, maxHeight: 200)
                        .scrollContentBackground(.hidden)
                        if editedNote.count > 375 {
                            HStack {
                                Spacer()
                                Text("\(editedNote.count) / 500")
                                    .font(.caption)
                                    .foregroundStyle(editedNote.count >= 500 ? .red : .secondary)
                            }
                        }
                    }
                }.listRowBackground(Color.chart)

                tagsSection

                if carbsEditedFromOriginal, !isFPU {
                    Section {
                        Label {
                            Text("Editing carbs won't rerun oref's past decisions — insulin already delivered against the original amount stays as-is. COB updates going forward. Use only to correct the historical log.")
                                .font(.caption)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }.listRowBackground(Color.chart)
                }

                Section {
                    DatePicker(
                        "Time",
                        selection: $editedDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }.listRowBackground(Color.chart)
            }
            .safeAreaInset(
                edge: .bottom,
                spacing: 30
            ) {
                stickyButton
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Edit Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            /*
             User taps on a FPU entry in the DataTable list. There are two cases:
             - the User has entered this FPU entry WITH carbs
             - the User has entered this FPU entry WITHOUT carbs
             In the first case, we simply need to load the corresponding carb entry. For this case THIS is the entry we want to edit.
             In the second case, we need to load the zero-carb entry that actualy holds the FPU values (and the carbs). For this case THIS is the entry we want to edit.
             */
            if carbEntry.isFPU {
                if let result = await state.handleFPUEntry(carbEntry.objectID) {
                    editedCarbs = result.entryValues?.carbs ?? 0
                    originalCarbs = result.entryValues?.carbs ?? 0
                    editedFat = result.entryValues?.fat ?? 0
                    editedProtein = result.entryValues?.protein ?? 0
                    editedNote = result.entryValues?.note ?? ""
                    entryToEdit = result.entryID
                    editedDate = result.entryValues?.date ?? Date()
                }
                /*
                 User taps on a carb entry in the DataTable list. There are again two cases which don't need explicit handling:
                 - the User has only entered carbs
                 - the User has entered carbs with FPU
                 In both cases, we need to simply load the carb entry that holds all the necessary values for us. This is the entry we want to edit.
                 */
            } else {
                if let values = await state.loadEntryValues(from: carbEntry.objectID) {
                    editedCarbs = values.carbs
                    originalCarbs = values.carbs
                    editedFat = values.fat
                    editedProtein = values.protein
                    editedNote = values.note
                    editedDate = values.date
                    entryToEdit = carbEntry.objectID
                }
            }
            if let id = entryToEdit {
                editedTagIDs = Set(await state.loadEntryTagIDs(from: id))
            }
        }
    }

    private var tagsSection: some View {
        let library = state.settingsManager.settings.mealTags
        let categories = state.settingsManager.settings.tagCategories
        let picked = library
            .filter { editedTagIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return Section(
            header: Text("Tags — optional"),
            footer: Text("Same library as saved meals. Handy for grouping the meal for later analysis.")
        ) {
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
            Button {
                showTagPicker = true
            } label: {
                Label(picked.isEmpty ? "Add tags" : "Edit tags", systemImage: "tag")
            }
            .sheet(isPresented: $showTagPicker) {
                SavedMealTagPickerSheet(
                    allTags: library,
                    allCategories: categories,
                    selectedIDs: editedTagIDs
                ) { newSelection in
                    editedTagIDs = newSelection
                }
            }
        }
        .listRowBackground(Color.chart)
    }
}
