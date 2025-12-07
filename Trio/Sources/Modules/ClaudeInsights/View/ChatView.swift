import SwiftUI

extension ClaudeInsights {
    struct ChatView: View {
        @Bindable var state: StateModel
        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState
        @FocusState private var isInputFocused: Bool

        var body: some View {
            VStack(spacing: 0) {
                // Chat Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if state.chatMessages.isEmpty {
                                emptyStateView
                            } else {
                                ForEach(state.chatMessages) { message in
                                    ChatBubble(message: message)
                                        .id(message.id)
                                }

                                if state.isLoading {
                                    HStack {
                                        ProgressView()
                                        Text("Claude is thinking...")
                                            .foregroundColor(.secondary)
                                    }
                                    .padding()
                                }
                            }
                        }
                        .padding()
                    }
                    .onChange(of: state.chatMessages.count) { _, _ in
                        if let lastMessage = state.chatMessages.last {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }

                // Error Message
                if let error = state.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.1))
                }

                Divider()

                // Input Area
                HStack(spacing: 12) {
                    TextField("Ask about your data...", text: $state.currentMessage, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .focused($isInputFocused)

                    Button {
                        Task {
                            await state.sendMessage()
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                            .foregroundColor(
                                state.currentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isLoading
                                    ? .gray
                                    : .accentColor
                            )
                    }
                    .disabled(
                        state.currentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isLoading
                    )
                }
                .padding()
                .background(Color.chart)
            }
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Ask Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        state.clearChat()
                    }
                    .disabled(state.chatMessages.isEmpty)
                }
            }
        }

        private var emptyStateView: some View {
            VStack(spacing: 16) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)

                Text("Ask Claude About Your Data")
                    .font(.headline)

                Text("Your diabetes data from the last 7 days will be shared with Claude to provide personalized insights.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Example questions:")
                        .font(.caption)
                        .fontWeight(.semibold)

                    ExampleQuestion(text: "Why am I high in the morning?")
                    ExampleQuestion(text: "What patterns do you see in my data?")
                    ExampleQuestion(text: "How can I improve my time in range?")
                    ExampleQuestion(text: "Are my carb ratios working?")
                }
                .padding()
                .background(Color.chart.opacity(0.5))
                .cornerRadius(12)
            }
            .padding(.vertical, 40)
        }
    }

    private struct ExampleQuestion: View {
        let text: String

        var body: some View {
            HStack {
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.accentColor)
                Text(text)
                    .font(.caption)
            }
        }
    }

    private struct ChatBubble: View {
        let message: StateModel.ChatMessage

        var body: some View {
            HStack {
                if message.role == "user" {
                    Spacer(minLength: 40)
                }

                VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                    Text(message.content)
                        .padding(12)
                        .background(
                            message.role == "user"
                                ? Color.accentColor
                                : Color.chart
                        )
                        .foregroundColor(
                            message.role == "user"
                                ? .white
                                : .primary
                        )
                        .cornerRadius(16)

                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if message.role == "assistant" {
                    Spacer(minLength: 40)
                }
            }
        }
    }
}
