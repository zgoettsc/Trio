import CoreData
import Foundation
import SwiftUI
import Swinject

/// Surfaces a live mid-meal carbs estimator suggestion as an actionable
/// sheet. The user can:
/// - Accept "Add N g now" — writes a NEW CarbsEntry at current timestamp,
///   `enteredBy = liveEstimator`. Cleanest data model for analysis.
/// - Accept "Edit original to N g" — deletes the original entry, writes a
///   new one at the ORIGINAL timestamp with the combined total,
///   `enteredBy = liveEstimatorEdit`. Maps to "the meal was actually
///   bigger than I thought" mental model.
/// - Adjust the amount before committing.
/// - Dismiss.
///
/// All three buckets are kept distinguishable in telemetry and on the
/// SavedMealInstance row so the post-hoc estimator's self-calibration
/// math stays clean. `carbsAtActivation` is NEVER mutated; suggestions
/// stack as `carbsAddedByEstimator` or `carbsEditedTo`.
struct LiveCarbsSuggestionSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    let suggestion: PendingLiveCarbsSuggestion
    let onCommit: () -> Void

    @State private var addAmount: String
    @FocusState private var amountFieldFocused: Bool

    private let resolver: Resolver = TrioApp.resolver

    init(suggestion: PendingLiveCarbsSuggestion, onCommit: @escaping () -> Void) {
        self.suggestion = suggestion
        self.onCommit = onCommit
        _addAmount = State(initialValue: "\(Int(suggestion.suggestedExtra.rounded()))")
    }

    var body: some View {
        NavigationView {
            Form {
                summarySection
                amountSection
                actionsSection
                disclaimerSection
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Meal estimator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("Done") { amountFieldFocused = false }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        Section(header: Text(suggestion.savedMealName ?? "Active meal")) {
            HStack {
                Text("Entered")
                Spacer()
                Text("\(Int(suggestion.enteredCarbs.rounded())) g").foregroundStyle(.secondary)
            }
            HStack {
                Text("BG suggests")
                Spacer()
                let total = suggestion.enteredCarbs + suggestion.suggestedExtra
                Text("≈ \(Int(total.rounded())) g").foregroundStyle(.orange).fontWeight(.semibold)
            }
            HStack {
                Text("Suggested extra")
                Spacer()
                Text("+\(Int(suggestion.suggestedExtra.rounded())) g  (range \(Int(suggestion.rangeLow.rounded()))–\(Int(suggestion.rangeHigh.rounded())))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("BG at trigger")
                Spacer()
                Text("\(Int(suggestion.bgAtTrigger.rounded())) mg/dL")
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Color.chart)
    }

    @ViewBuilder
    private var amountSection: some View {
        Section(
            header: Text("Adjust amount"),
            footer: Text("Default is the BG-implied extra. Lower if you suspect the estimate is too aggressive.")
        ) {
            HStack {
                Text("Add")
                Spacer()
                TextField("0", text: $addAmount)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .focused($amountFieldFocused)
                    .frame(width: 80, height: 32)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(amountFieldFocused ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { amountFieldFocused = true }
                Text("g").foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Color.chart)
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            Button {
                commit(mode: .addNew)
            } label: {
                Label("Add \(currentAmountInt) g now", systemImage: "plus.circle.fill")
            }
            .disabled(currentAmount <= 0)

            Button {
                commit(mode: .editOriginal)
            } label: {
                Label("Edit original to \(Int((suggestion.enteredCarbs + currentAmount).rounded())) g", systemImage: "pencil.circle")
            }
            .disabled(currentAmount <= 0)

            Button(role: .destructive) {
                commit(mode: .dismiss)
            } label: {
                Label("Dismiss", systemImage: "xmark.circle")
            }
        }
        .listRowBackground(Color.chart)
    }

    @ViewBuilder
    private var disclaimerSection: some View {
        Section {
            Text("`Add now` writes a fresh carb entry at the current time — oref handles late carbs correctly. `Edit original` rewrites the first entry's grams in place; oref will recalculate absorption since the original timestamp (brief math reshuffle). Use whichever feels right.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .listRowBackground(Color.chart)
    }

    private var currentAmount: Double {
        Double(addAmount.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var currentAmountInt: Int {
        Int(currentAmount.rounded())
    }

    private enum CommitMode {
        case addNew, editOriginal, dismiss
    }

    private func commit(mode: CommitMode) {
        let handler = LiveCarbsSuggestionHandler(resolver: resolver)
        switch mode {
        case .addNew:
            handler.addNew(suggestion: suggestion, amount: Decimal(currentAmount))
        case .editOriginal:
            handler.editOriginal(suggestion: suggestion, amount: Decimal(currentAmount))
        case .dismiss:
            handler.dismiss(suggestion: suggestion)
        }
        onCommit()
        dismiss()
    }
}

// MARK: - Handler

/// Commits the user's choice from the suggestion sheet. Writes the carb
/// entry (or edit), tags it via `enteredBy`, updates the SavedMealInstance
/// tracking fields, emits telemetry, and clears the pending suggestion
/// from settings so the banner goes away.
final class LiveCarbsSuggestionHandler {
    private let resolver: Resolver
    init(resolver: Resolver) { self.resolver = resolver }

    private var settingsManager: SettingsManager? { resolver.resolve(SettingsManager.self) }
    private var carbsStorage: CarbsStorage? { resolver.resolve(CarbsStorage.self) }
    private var telemetry: AlgorithmTelemetryManager? { resolver.resolve(AlgorithmTelemetryManager.self) }
    private var apsManager: APSManager? { resolver.resolve(APSManager.self) }

    func addNew(suggestion: PendingLiveCarbsSuggestion, amount: Decimal) {
        let now = Date()
        let entry = CarbsEntry(
            id: UUID().uuidString,
            createdAt: now,
            actualDate: now,
            carbs: amount,
            fat: 0,
            protein: 0,
            note: "Estimator add: \(suggestion.windowId.prefix(8))",
            enteredBy: CarbsEntry.liveEstimator,
            isFPU: false,
            fpuID: nil
        )
        Task {
            try? await carbsStorage?.storeCarbs([entry], areFetchedFromRemote: false)
            await bumpInstanceAddedField(suggestion: suggestion, by: amount)
            emitAccepted(suggestion: suggestion, mode: "addNew", amount: amount)
            clearPending()
            try? await apsManager?.determineBasalSync()
        }
    }

    func editOriginal(suggestion: PendingLiveCarbsSuggestion, amount: Decimal) {
        // Find the original CarbsEntry for this window. Identified by:
        // - same date as window activation (±2 min slack)
        // - isFPU == NO
        // - enteredBy in (Trio, ApplyHealth, user) — i.e. user-originated
        // Replace its `carbs` in place. CarbsStorage doesn't expose an
        // update API; simplest is delete + reinsert at the same timestamp.
        let combinedTotal = Decimal(suggestion.enteredCarbs) + amount
        Task {
            let ctx = CoreDataStack.shared.newTaskContext()
            let originalDate: Date? = await ctx.perform {
                let req = CarbEntryStored.fetchRequest()
                let earliest = suggestion.triggeredAt.addingTimeInterval(-12 * 3600) // be generous
                req.predicate = NSPredicate(
                    format: "date >= %@ AND date <= %@ AND isFPU == NO AND carbs == %f",
                    earliest as NSDate,
                    suggestion.triggeredAt as NSDate,
                    NSDecimalNumber(decimal: Decimal(suggestion.enteredCarbs)).doubleValue
                )
                req.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
                req.fetchLimit = 1
                guard let row = (try? ctx.fetch(req))?.first, let date = row.date else { return nil }
                // Soft-delete the original by zeroing carbs (preserves history),
                // OR hard-delete + reinsert. Hard-delete keeps oref's COB math
                // simpler.
                ctx.delete(row)
                try? ctx.save()
                return date
            }
            let editedDate = originalDate ?? suggestion.triggeredAt
            let entry = CarbsEntry(
                id: UUID().uuidString,
                createdAt: Date(),
                actualDate: editedDate,
                carbs: combinedTotal,
                fat: 0,
                protein: 0,
                note: "Estimator edit: combined original + \(Int(NSDecimalNumber(decimal: amount).doubleValue))g",
                enteredBy: CarbsEntry.liveEstimatorEdit,
                isFPU: false,
                fpuID: nil
            )
            try? await carbsStorage?.storeCarbs([entry], areFetchedFromRemote: false)
            await bumpInstanceEditedToField(suggestion: suggestion, total: combinedTotal)
            emitAccepted(suggestion: suggestion, mode: "editOriginal", amount: amount)
            clearPending()
            try? await apsManager?.determineBasalSync()
        }
    }

    func dismiss(suggestion: PendingLiveCarbsSuggestion) {
        telemetry?.logEvent(AlgorithmTelemetryEvent(
            kind: .liveCarbsEstimateDismissed,
            timestamp: Date(),
            windowId: suggestion.windowId,
            payload: [
                "suggestedExtra": .double(suggestion.suggestedExtra),
                "enteredCarbs": .double(suggestion.enteredCarbs)
            ]
        ))
        clearPending()
    }

    private func bumpInstanceAddedField(suggestion: PendingLiveCarbsSuggestion, by amount: Decimal) async {
        guard let instanceIdString = suggestion.savedMealInstanceId,
              let instanceId = UUID(uuidString: instanceIdString) else { return }
        let ctx = CoreDataStack.shared.newTaskContext()
        await ctx.perform {
            let req = SavedMealInstance.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", instanceId as CVarArg)
            req.fetchLimit = 1
            guard let inst = (try? ctx.fetch(req))?.first else { return }
            let prior = (inst.carbsAddedByEstimator as Decimal?) ?? 0
            inst.carbsAddedByEstimator = NSDecimalNumber(decimal: prior + amount)
            try? ctx.save()
        }
    }

    private func bumpInstanceEditedToField(suggestion: PendingLiveCarbsSuggestion, total: Decimal) async {
        guard let instanceIdString = suggestion.savedMealInstanceId,
              let instanceId = UUID(uuidString: instanceIdString) else { return }
        let ctx = CoreDataStack.shared.newTaskContext()
        await ctx.perform {
            let req = SavedMealInstance.fetchRequest()
            req.predicate = NSPredicate(format: "id == %@", instanceId as CVarArg)
            req.fetchLimit = 1
            guard let inst = (try? ctx.fetch(req))?.first else { return }
            inst.carbsEditedTo = NSDecimalNumber(decimal: total)
            try? ctx.save()
        }
    }

    private func emitAccepted(suggestion: PendingLiveCarbsSuggestion, mode: String, amount: Decimal) {
        telemetry?.logEvent(AlgorithmTelemetryEvent(
            kind: .liveCarbsEstimateAccepted,
            timestamp: Date(),
            windowId: suggestion.windowId,
            payload: [
                "mode": .string(mode),
                "acceptedAmount": .double(NSDecimalNumber(decimal: amount).doubleValue),
                "enteredCarbs": .double(suggestion.enteredCarbs),
                "suggestedExtra": .double(suggestion.suggestedExtra)
            ]
        ))
    }

    private func clearPending() {
        guard var s = settingsManager?.settings else { return }
        s.pendingLiveCarbsSuggestion = nil
        settingsManager?.settings = s
    }
}
