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

    /// Curated default list shipped with the app. Covers the common
    /// rescue items most T1D users keep on hand. Users can edit / add
    /// to this in settings; the defaults are just a starting point.
    static let defaults: [RescuePreset] = [
        RescuePreset(
            name: "Juice box (4 oz)", carbs: 15, fat: 0, protein: 0,
            emoji: "🧃",
            notes: "Fast onset, ~15-20 min absorption. Classic first-line rescue."
        ),
        RescuePreset(
            name: "Glucose tabs (×4)", carbs: 16, fat: 0, protein: 0,
            emoji: "💊",
            notes: "Predictable absorption, no fat/protein lag."
        ),
        RescuePreset(
            name: "Glucose tabs (×3)", carbs: 12, fat: 0, protein: 0,
            emoji: "💊",
            notes: "Mild rescue when only slightly low."
        ),
        RescuePreset(
            name: "Skittles (small handful)", carbs: 15, fat: 0, protein: 0,
            emoji: "🍬",
            notes: "Fast sugar; some users find these absorb quicker than tabs."
        ),
        RescuePreset(
            name: "Jelly beans (~10)", carbs: 15, fat: 0, protein: 0,
            emoji: "🫘",
            notes: "Fast onset, can over-correct."
        ),
        RescuePreset(
            name: "Granola bar", carbs: 22, fat: 6, protein: 3,
            emoji: "🍫",
            notes: "Slower, more durable recovery thanks to fat + protein. Worse for rapid rescue."
        ),
        RescuePreset(
            name: "Banana (small)", carbs: 23, fat: 0, protein: 1,
            emoji: "🍌",
            notes: "Mid-speed; good for moderate lows that aren't crashing."
        ),
        RescuePreset(
            name: "Honey (1 tbsp)", carbs: 17, fat: 0, protein: 0,
            emoji: "🍯",
            notes: "Very fast onset."
        ),
        RescuePreset(
            name: "Apple juice (4 oz)", carbs: 15, fat: 0, protein: 0,
            emoji: "🍎",
            notes: "Fast onset, similar profile to juice box."
        ),
        RescuePreset(
            name: "Smarties (1 roll)", carbs: 6, fat: 0, protein: 0,
            emoji: "🍬",
            notes: "Small precise dose for mild lows."
        )
    ]
}
