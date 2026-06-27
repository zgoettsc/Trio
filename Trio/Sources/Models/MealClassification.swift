import Foundation

/// Live classifier output for an active meal window. The live classifier (see
/// `MealClassifier` in APS) upgrades this through the window's lifetime when
/// the 3-phase rule detects a late-fat-onset pattern. Upgrades are one-way —
/// the rule never downgrades.
///
/// Drives:
/// - The window's effective duration (Complex pushes to
///   `mealClassifierMaxTotalDurationMinutes`, default 600 from activation).
/// - Whether phantom COB is injected for the remainder of the window
///   (Complex enables, others leave the existing `mealWindowPhantomCOB`
///   setting alone).
///
/// See `docs/MEAL_INTELLIGENCE_DESIGN.md` §4 for the full rule.
enum MealClassification: String, Codable, CaseIterable, Equatable {
    case simple
    case medium
    case complex

    /// Strict ordering — used by the upgrade-only rule to ensure transitions
    /// only move up the scale (simple → medium → complex).
    var rank: Int {
        switch self {
        case .simple: return 0
        case .medium: return 1
        case .complex: return 2
        }
    }

    var displayName: String {
        switch self {
        case .simple: return "Simple"
        case .medium: return "Medium"
        case .complex: return "Complex"
        }
    }

    /// Human-readable description for settings UI / telemetry payloads.
    var description: String {
        switch self {
        case .simple: return "Fast carbs, single peak, flat tail"
        case .medium: return "Typical mixed meal"
        case .complex: return "Fat/protein-heavy with delayed late peak"
        }
    }
}
