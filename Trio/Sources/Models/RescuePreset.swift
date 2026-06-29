import Foundation

/// A curated rescue-carbs item the user can tap to log when treating a low.
/// Stored as a list in `TrioSettings.rescuePresets` (user-customizable).
/// Each instance records via `CarbEntryStored` with `isRescueCarbs = true`
/// and `rescuePresetName = preset.name`, so analytics can stratify BG
/// recovery curves by what was eaten — does a granola bar yield a longer,
/// more durable recovery than jelly beans? Per-preset answer falls out of
/// the data once enough events accumulate.
struct RescuePreset: Codable, Equatable, Identifiable {
    /// Stable identifier so settings reorders / renames are durable.
    let id: UUID
    /// Display name. Becomes `rescuePresetName` on the carb entry.
    var name: String
    /// Fast carbs (g) — the "rescue" payload.
    var carbs: Decimal
    /// Optional fat content — matters for the long-term durability story.
    /// nil = unknown, NOT zero.
    var fat: Decimal?
    /// Optional protein content. nil = unknown, NOT zero.
    var protein: Decimal?
    /// Display emoji or short marker for the picker UI.
    var emoji: String?
    /// Free-text notes shown beneath the name in the picker
    /// (e.g. "fast onset, ~20 min absorption", "may rebound").
    var notes: String?

    init(
        id: UUID = UUID(),
        name: String,
        carbs: Decimal,
        fat: Decimal? = nil,
        protein: Decimal? = nil,
        emoji: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.carbs = carbs
        self.fat = fat
        self.protein = protein
        self.emoji = emoji
        self.notes = notes
    }

    /// Empty by design. The rescue-preset list is user-owned — the
    /// user adds their own items via Settings (knowing their own
    /// stash and what works for their physiology). Shipping curated
    /// defaults would presume what the user keeps on hand and would
    /// pollute the per-preset BG-recovery analytics with items that
    /// never get used. Fresh installs see an empty list and the
    /// RescueCarbsSheet's custom-entry path until presets are added.
    static let defaults: [RescuePreset] = []
}
