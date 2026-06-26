import AppIntents
import Foundation
import Intents
import Swinject

@available(iOS 16.0, *) struct AnnounceMealIntent: AppIntent {
    static var title: LocalizedStringResource = "I'm Eating"

    static var description = IntentDescription(
        LocalizedStringResource(
            "Tells Trio you are eating now. Trio will more aggressively cover the meal using BG acceleration without requiring you to enter carbs."
        )
    )

    /// Optional carb hint. If omitted, no carbs are recorded — the loop just opens an
    /// eating window. If supplied, Trio uses it as a meal-window hint (not a carb entry).
    @Parameter(
        title: "Estimated Carbs (optional)",
        description: "Rough carb estimate in g; leave blank if unknown.",
        controlStyle: .field,
        inclusiveRange: (lowerBound: 0, upperBound: 200)
    ) var estimatedCarbs: Double?

    @Parameter(
        title: "Confirm Before Activating",
        description: "If on, you'll be asked to confirm.",
        default: false
    ) var confirmBeforeApplying: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("I'm eating now") {
            \.$estimatedCarbs
            \.$confirmBeforeApplying
        }
    }

    @MainActor func perform() async throws -> some ProvidesDialog {
        if confirmBeforeApplying {
            try await requestConfirmation(
                result: .result(
                    dialog: IntentDialog(stringLiteral: String(localized: "Activate eating mode now?"))
                )
            )
        }
        let carbsHint = estimatedCarbs.map { Decimal($0) }
        let msg = try await AnnounceMealIntentRequest().announce(estimatedCarbs: carbsHint)
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}

@available(iOS 16.0, *) struct CancelMealAnnouncementIntent: AppIntent {
    static var title: LocalizedStringResource = "Cancel Eating Mode"

    static var description = IntentDescription(
        LocalizedStringResource("Cancels an active Trio eating-mode window early.")
    )

    @Parameter(
        title: "Confirm Before Cancelling",
        description: "If on, you'll be asked to confirm.",
        default: false
    ) var confirmBeforeApplying: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Cancel eating mode") {
            \.$confirmBeforeApplying
        }
    }

    @MainActor func perform() async throws -> some ProvidesDialog {
        if confirmBeforeApplying {
            try await requestConfirmation(
                result: .result(
                    dialog: IntentDialog(stringLiteral: String(localized: "Cancel eating mode now?"))
                )
            )
        }
        let msg = try await AnnounceMealIntentRequest().cancel()
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}
