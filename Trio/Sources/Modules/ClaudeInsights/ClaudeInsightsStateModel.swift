import Combine
import Foundation
import Observation
import SwiftUI
import Swinject

extension ClaudeInsights {
    @Observable final class StateModel: BaseStateModel<Provider> {
        // MARK: - Properties

        var apiKey: String = ""
        var hasAPIKey: Bool = false
        var isLoading: Bool = false
        var errorMessage: String?

        // Chat
        var chatMessages: [ChatMessage] = []
        var currentMessage: String = ""

        // Reports
        var lastReport: String?
        var lastReportDate: Date?

        // Quick Analysis
        var quickAnalysisResult: String?

        // MARK: - Services

        private var claudeService: ClaudeAPIService?
        private var dataExporter: ClaudeDataExporter?

        // MARK: - Types

        struct ChatMessage: Identifiable, Equatable {
            let id = UUID()
            let role: String // "user" or "assistant"
            let content: String
            let timestamp: Date
        }

        // MARK: - Lifecycle

        override func subscribe() {
            claudeService = ClaudeAPIService()
            dataExporter = ClaudeDataExporter(resolver: resolver)
            loadAPIKey()
        }

        // MARK: - API Key Management

        func loadAPIKey() {
            if let key = claudeService?.getAPIKey() {
                apiKey = key
                hasAPIKey = true
            } else {
                apiKey = ""
                hasAPIKey = false
            }
        }

        func saveAPIKey() {
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedKey.isEmpty {
                claudeService?.clearAPIKey()
                hasAPIKey = false
            } else {
                claudeService?.setAPIKey(trimmedKey)
                hasAPIKey = true
            }
        }

        func clearAPIKey() {
            apiKey = ""
            claudeService?.clearAPIKey()
            hasAPIKey = false
        }

        // MARK: - Chat Functions

        func sendMessage() async {
            guard !currentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard let claudeService = claudeService, let dataExporter = dataExporter else { return }

            let userMessage = currentMessage
            currentMessage = ""
            errorMessage = nil

            // Add user message to chat
            await MainActor.run {
                chatMessages.append(ChatMessage(
                    role: "user",
                    content: userMessage,
                    timestamp: Date()
                ))
                isLoading = true
            }

            do {
                // Export data
                let diabetesData = try await dataExporter.exportSummary(days: 7)

                // Build conversation history (last 10 messages)
                let history = chatMessages.suffix(10).map { msg in
                    ClaudeAPIService.Message(role: msg.role, content: msg.content)
                }

                // Send to Claude
                let response = try await claudeService.sendMessage(
                    userMessage: userMessage,
                    diabetesData: diabetesData,
                    conversationHistory: Array(history.dropLast()) // Exclude the message we just added
                )

                await MainActor.run {
                    chatMessages.append(ChatMessage(
                        role: "assistant",
                        content: response,
                        timestamp: Date()
                    ))
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }

        func clearChat() {
            chatMessages.removeAll()
            errorMessage = nil
        }

        // MARK: - Report Functions

        func generateWeeklyReport() async {
            guard let claudeService = claudeService, let dataExporter = dataExporter else { return }

            await MainActor.run {
                isLoading = true
                errorMessage = nil
            }

            do {
                let diabetesData = try await dataExporter.exportSummary(days: 7)
                let report = try await claudeService.generateWeeklyReport(diabetesData: diabetesData)

                await MainActor.run {
                    lastReport = report
                    lastReportDate = Date()
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }

        // MARK: - Quick Analysis

        func runQuickAnalysis() async {
            guard let claudeService = claudeService, let dataExporter = dataExporter else { return }

            await MainActor.run {
                isLoading = true
                errorMessage = nil
                quickAnalysisResult = nil
            }

            do {
                let diabetesData = try await dataExporter.exportSummary(days: 7)
                let analysis = try await claudeService.quickAnalysis(diabetesData: diabetesData)

                await MainActor.run {
                    quickAnalysisResult = analysis
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}
