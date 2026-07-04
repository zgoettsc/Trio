import Foundation
import LoopKit

struct CarbsEntry: JSON, Equatable, Hashable, Identifiable {
    let id: String?
    let createdAt: Date
    let actualDate: Date?
    let carbs: Decimal
    let fat: Decimal?
    let protein: Decimal?
    let note: String?
    let enteredBy: String?
    let isFPU: Bool?
    let fpuID: String?
    /// Rescue-carbs flag. When true the carb entry was logged by the user
    /// to TREAT A LOW (juice, glucose tabs, granola bar, etc.) rather
    /// than as meal fuel. Excluded from oref's COB calculation so the
    /// loop doesn't dose extra insulin against the very carbs the user
    /// ate to recover. All defaults `false` when nil for back-compat.
    let isRescueCarbs: Bool?
    /// Free-text preset name when the rescue was logged via the curated
    /// preset picker (e.g. "Juice box", "Glucose tabs", "Granola bar").
    /// Nil when typed as custom. Lets analytics group BG-recovery curves
    /// by what was eaten.
    let rescuePresetName: String?
    /// Optional user-selected tags for this entry — same library as saved
    /// meals. Empty / nil when untagged. Persisted onto CarbEntryStored
    /// via tagIDsJSON so the History edit sheet can retroactively add or
    /// change them without a re-write of the entry.
    let tagIDs: [UUID]?

    static let local = "Trio"
    static let appleHealth = "applehealth"
    /// New CarbsEntry written by the live mid-meal carbs estimator when the
    /// user accepts an "Add Ng now" suggestion. Lets analysis distinguish
    /// estimator-injected carbs from user-entered carbs so the post-hoc
    /// estimator's self-calibration loop stays clean.
    static let liveEstimator = "Trio-LiveEstimator"
    /// Carbs from the "Edit original to N g" path — replaces the original
    /// entry at its original timestamp with the new larger amount.
    static let liveEstimatorEdit = "Trio-LiveEstimator-Edit"
    /// Carbs logged via the Treatments → Rescue path to recover from a low.
    /// These do NOT enter oref's COB calculation; tag lets the meal.json
    /// builder filter them out.
    static let rescueCarbs = "Trio-RescueCarbs"

    /// Memberwise init that defaults the rescue-carbs fields to nil so
    /// existing call sites don't have to be updated. Rescue path passes
    /// them explicitly.
    init(
        id: String?,
        createdAt: Date,
        actualDate: Date?,
        carbs: Decimal,
        fat: Decimal?,
        protein: Decimal?,
        note: String?,
        enteredBy: String?,
        isFPU: Bool?,
        fpuID: String?,
        isRescueCarbs: Bool? = nil,
        rescuePresetName: String? = nil,
        tagIDs: [UUID]? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.actualDate = actualDate
        self.carbs = carbs
        self.fat = fat
        self.protein = protein
        self.note = note
        self.enteredBy = enteredBy
        self.isFPU = isFPU
        self.fpuID = fpuID
        self.isRescueCarbs = isRescueCarbs
        self.rescuePresetName = rescuePresetName
        self.tagIDs = tagIDs
    }

    static func == (lhs: CarbsEntry, rhs: CarbsEntry) -> Bool {
        lhs.createdAt == rhs.createdAt
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(createdAt)
    }
}

extension CarbsEntry {
    private enum CodingKeys: String, CodingKey {
        case id = "_id"
        case createdAt = "created_at"
        case actualDate
        case carbs
        case fat
        case protein
        case note = "notes"
        case enteredBy
        case isFPU
        case fpuID
        case isRescueCarbs
        case rescuePresetName
        case tagIDs
    }
}

extension CarbsEntry {
    func convertSyncCarb(operation: LoopKit.Operation = .create) -> SyncCarbObject {
        SyncCarbObject(
            absorptionTime: nil,
            createdByCurrentApp: true,
            foodType: nil,
            grams: Double(carbs),
            startDate: createdAt,
            uuid: UUID(uuidString: id!),
            provenanceIdentifier: enteredBy ?? "Trio",
            syncIdentifier: id,
            syncVersion: nil,
            userCreatedDate: nil,
            userUpdatedDate: nil,
            userDeletedDate: nil,
            operation: operation,
            addedDate: nil,
            supercededDate: nil
        )
    }
}
