import Foundation

extension ClaudeInsights {
    final class Provider: BaseProvider, ClaudeInsightsProviding {}
}

protocol ClaudeInsightsProviding: Provider {}
