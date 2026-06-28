import Foundation

/// In-flight suggestion from the live mid-meal carbs estimator. Persisted
/// on TrioSettings so a suggestion that fires while the app is closed
/// still surfaces as a banner / sheet on the next foreground.
///
/// Cleared when the user acts on it (accepts Add-New or Edit-Original) or
/// explicitly dismisses. Stale entries (older than 2 hours) get auto-cleared
/// on read — by then the meal is mostly absorbed and the suggestion is no
/// longer useful.
struct PendingLiveCarbsSuggestion: Codable, Equatable, Identifiable {
    /// Identifier for SwiftUI `.sheet(item:)` — uniquely keyed on the
    /// windowId + triggeredAt so a re-fire within the same window replaces
    /// the prior sheet instance cleanly.
    var id: String { "\(windowId)-\(Int(triggeredAt.timeIntervalSince1970))" }

    /// The meal window this suggestion belongs to. Re-firing within the
    /// same window replaces the prior suggestion (one active per window).
    let windowId: String
    /// Wall-clock time the estimator triggered.
    let triggeredAt: Date
    /// What the user originally entered for this meal at activation.
    let enteredCarbs: Double
    /// Implied extra grams beyond what was entered. The user can accept
    /// this verbatim or adjust before committing.
    let suggestedExtra: Double
    /// ±15% range around `suggestedExtra` reflecting ISF/CR uncertainty.
    let rangeLow: Double
    let rangeHigh: Double
    /// Snapshot of BG at the moment of the trigger (for context display).
    let bgAtTrigger: Double
    /// Optional — only present when the meal was started from a SavedMeal.
    /// Lets the accept-handler attribute the added carbs to the right
    /// SavedMealInstance row for the post-hoc estimator's feedback math.
    let savedMealInstanceId: String?
    /// Optional — saved meal name for display ("Coconut Chicken meal looks
    /// bigger than logged").
    let savedMealName: String?
}
