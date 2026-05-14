import Foundation

/// Live-Activity facing snapshot of the meal-announcement window state. Reflects the
/// values in `TrioSettings` (the canonical source) at the moment the LA push was built.
struct MealWindowData {
    let isActive: Bool
    /// Absolute clock time the window expires. Use this for a `Text(timerInterval:)`
    /// countdown so the LA updates without the main app having to re-push every minute.
    let expiresAt: Date
    /// Optional user-provided carb hint; 0 if the user just pressed the button without
    /// supplying an estimate.
    let estimatedCarbs: Decimal
    /// True once a real carb entry was recorded during the window — the window's expiry
    /// is recomputed against the extended duration in that case.
    let carbsConfirmed: Bool
}
