import SwiftUI
import Swinject

extension ClaudeInsights {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                // API Key Section
                apiKeySection

                if state.hasAPIKey {
                    // Quick Analysis Section
                    quickAnalysisSection

                    // Ask Claude Section
                    askClaudeSection

                    // Weekly Report Section
                    weeklyReportSection
                }

                // Disclaimer
                disclaimerSection
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Claude Insights")
            .navigationBarTitleDisplayMode(.large)
            .onAppear(perform: configureView)
        }

        // MARK: - Sections

        private var apiKeySection: some View {
            Section {
                if state.hasAPIKey {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("API Key Configured")
                        Spacer()
                        Button("Change") {
                            state.hasAPIKey = false
                        }
                        .foregroundColor(.accentColor)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter your Claude API Key")
                            .font(.headline)
                        Text("Get your API key from console.anthropic.com")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        SecureField("sk-ant-...", text: $state.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()

                        Button("Save API Key") {
                            state.saveAPIKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.apiKey.isEmpty)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("API Configuration")
            } footer: {
                Text("Your API key is stored securely in the device keychain.")
            }
            .listRowBackground(Color.chart)
        }

        private var quickAnalysisSection: some View {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "bolt.fill")
                            .foregroundColor(.orange)
                        Text("Quick Analysis")
                            .font(.headline)
                    }

                    Text("Get instant insights about your last 7 days of data")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button {
                        Task {
                            await state.runQuickAnalysis()
                        }
                    } label: {
                        HStack {
                            if state.isLoading && state.quickAnalysisResult == nil {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text("Analyze Now")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isLoading)

                    if let result = state.quickAnalysisResult {
                        Divider()
                        Text(result)
                            .font(.body)
                            .padding(.vertical, 8)
                    }

                    if let error = state.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("On-Demand Analysis")
            }
            .listRowBackground(Color.chart)
        }

        private var askClaudeSection: some View {
            Section {
                NavigationLink {
                    ChatView(state: state)
                } label: {
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text("Ask Claude")
                                .font(.headline)
                            Text("Chat about your diabetes data")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("Interactive Chat")
            } footer: {
                Text("Ask questions like \"Why am I high in the morning?\" or \"What patterns do you see?\"")
            }
            .listRowBackground(Color.chart)
        }

        private var weeklyReportSection: some View {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "doc.text.fill")
                            .foregroundColor(.purple)
                        Text("Weekly Report")
                            .font(.headline)
                    }

                    if let reportDate = state.lastReportDate {
                        Text("Last generated: \(reportDate.formatted())")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button {
                        Task {
                            await state.generateWeeklyReport()
                        }
                    } label: {
                        HStack {
                            if state.isLoading && state.quickAnalysisResult != nil {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Generate Report")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.isLoading)

                    if let report = state.lastReport {
                        NavigationLink {
                            ReportView(report: report, date: state.lastReportDate ?? Date())
                        } label: {
                            Text("View Latest Report")
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Reports")
            }
            .listRowBackground(Color.chart)
        }

        private var disclaimerSection: some View {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Important Disclaimer")
                            .font(.headline)
                    }

                    Text("""
                    Claude Insights provides educational analysis only. \
                    It is NOT a substitute for professional medical advice. \
                    Always consult your healthcare provider before making changes to your diabetes treatment.
                    """)
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.chart)
        }
    }
}
