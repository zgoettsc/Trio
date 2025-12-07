import Foundation

/// Service for communicating with the Claude API
final class ClaudeAPIService {

    // MARK: - Types

    enum ClaudeError: LocalizedError {
        case noAPIKey
        case invalidURL
        case networkError(Error)
        case invalidResponse
        case apiError(String)
        case decodingError(Error)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "No API key configured. Please add your Claude API key in Settings."
            case .invalidURL:
                return "Invalid API URL"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .invalidResponse:
                return "Invalid response from API"
            case .apiError(let message):
                return "API error: \(message)"
            case .decodingError(let error):
                return "Failed to decode response: \(error.localizedDescription)"
            }
        }
    }

    struct Message: Codable {
        let role: String
        let content: String
    }

    struct ClaudeRequest: Codable {
        let model: String
        let max_tokens: Int
        let system: String?
        let messages: [Message]
    }

    struct ClaudeResponse: Codable {
        struct Content: Codable {
            let type: String
            let text: String
        }

        struct Usage: Codable {
            let input_tokens: Int
            let output_tokens: Int
        }

        let id: String
        let type: String
        let role: String
        let content: [Content]
        let model: String
        let usage: Usage
    }

    struct ClaudeErrorResponse: Codable {
        struct ErrorDetail: Codable {
            let type: String
            let message: String
        }
        let type: String
        let error: ErrorDetail
    }

    // MARK: - Configuration

    private enum Config {
        static let apiURL = "https://api.anthropic.com/v1/messages"
        static let model = "claude-sonnet-4-20250514"
        static let maxTokens = 4096
        static let timeout: TimeInterval = 120
        static let anthropicVersion = "2023-06-01"
    }

    // MARK: - System Prompt

    static let systemPrompt = """
    You are a diabetes data analyst assistant helping users understand patterns in their blood glucose and insulin data from the Trio automated insulin delivery app.

    IMPORTANT SAFETY RULES:
    1. NEVER recommend specific insulin doses - only suggest percentage adjustments (e.g., "consider increasing basal by 5-10%")
    2. ALWAYS recommend consulting a healthcare provider before making significant changes
    3. Flag any dangerous patterns immediately (frequent severe lows below 54 mg/dL, suspected DKA risk with persistent highs)
    4. Be conservative - small adjustments (5-15%) are safer than large ones
    5. Acknowledge the limitations of data-based recommendations
    6. Never suggest changes that could lead to dangerous hypoglycemia

    Your role is to:
    - Identify patterns in blood glucose and treatment data
    - Explain what patterns might mean in plain language
    - Suggest areas to discuss with healthcare provider
    - Answer questions about diabetes management concepts
    - Help users understand their data better

    When analyzing data:
    - Look for time-of-day patterns (dawn phenomenon, post-meal spikes, overnight trends)
    - Identify recurring highs or lows at specific times
    - Note correlations between carb intake and glucose response
    - Consider insulin sensitivity patterns throughout the day
    - Evaluate if current settings (basal, ISF, CR) seem appropriate based on outcomes

    Format recommendations clearly:
    - Use bullet points for multiple suggestions
    - Separate observations from recommendations
    - Always include the caveat to consult healthcare provider
    - Be specific about which time periods or settings you're referring to
    """

    // MARK: - Properties

    private let keychain: Keychain
    private static let apiKeyKey = "claudeAPIKey"

    // MARK: - Initialization

    init(keychain: Keychain = BaseKeychain()) {
        self.keychain = keychain
    }

    // MARK: - API Key Management

    var hasAPIKey: Bool {
        getAPIKey() != nil
    }

    func getAPIKey() -> String? {
        switch keychain.getValue(String.self, forKey: Self.apiKeyKey) {
        case .success(let value):
            return value
        case .failure:
            return nil
        }
    }

    func setAPIKey(_ key: String?) {
        _ = keychain.setValue(key, forKey: Self.apiKeyKey)
    }

    func clearAPIKey() {
        _ = keychain.removeObject(forKey: Self.apiKeyKey)
    }

    // MARK: - API Calls

    /// Send a message to Claude with the diabetes data context
    func sendMessage(
        userMessage: String,
        diabetesData: String,
        conversationHistory: [Message] = []
    ) async throws -> String {
        guard let apiKey = getAPIKey(), !apiKey.isEmpty else {
            throw ClaudeError.noAPIKey
        }

        guard let url = URL(string: Config.apiURL) else {
            throw ClaudeError.invalidURL
        }

        // Build the full message with data context
        let contextMessage = """
        Here is the user's diabetes data from the past 7 days:

        \(diabetesData)

        User's question/request: \(userMessage)
        """

        var messages = conversationHistory
        messages.append(Message(role: "user", content: contextMessage))

        let request = ClaudeRequest(
            model: Config.model,
            max_tokens: Config.maxTokens,
            system: Self.systemPrompt,
            messages: messages
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = Config.timeout
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.addValue(Config.anthropicVersion, forHTTPHeaderField: "anthropic-version")

        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            throw ClaudeError.decodingError(error)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw ClaudeError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeError.invalidResponse
        }

        // Check for error response
        if httpResponse.statusCode != 200 {
            if let errorResponse = try? JSONDecoder().decode(ClaudeErrorResponse.self, from: data) {
                throw ClaudeError.apiError(errorResponse.error.message)
            }
            throw ClaudeError.apiError("HTTP \(httpResponse.statusCode)")
        }

        // Decode success response
        let claudeResponse: ClaudeResponse
        do {
            claudeResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        } catch {
            throw ClaudeError.decodingError(error)
        }

        // Extract text from response
        guard let textContent = claudeResponse.content.first(where: { $0.type == "text" }) else {
            throw ClaudeError.invalidResponse
        }

        return textContent.text
    }

    /// Generate a weekly analysis report
    func generateWeeklyReport(diabetesData: String) async throws -> String {
        let prompt = """
        Please analyze this week's diabetes data and provide a comprehensive report including:

        1. **Summary Statistics**
           - Time in range, time high, time low
           - Average glucose and variability
           - Total daily insulin patterns

        2. **Pattern Analysis**
           - Time-of-day patterns (morning, afternoon, evening, overnight)
           - Post-meal glucose responses
           - Any recurring highs or lows

        3. **Observations**
           - What's working well
           - Areas that could be improved
           - Any concerning patterns that need attention

        4. **Recommendations** (to discuss with healthcare provider)
           - Specific settings that might benefit from adjustment
           - Suggested percentage changes (conservative)
           - Behavioral suggestions (meal timing, etc.)

        Please be thorough but concise. Format the report clearly with sections and bullet points.
        """

        return try await sendMessage(
            userMessage: prompt,
            diabetesData: diabetesData
        )
    }

    /// Quick on-demand analysis
    func quickAnalysis(diabetesData: String) async throws -> String {
        let prompt = """
        Please provide a quick analysis of the current diabetes data:

        1. What are the most notable patterns in the last 7 days?
        2. Are there any immediate concerns or areas needing attention?
        3. What's one specific suggestion that could help improve control?

        Keep the response concise (3-4 paragraphs max).
        """

        return try await sendMessage(
            userMessage: prompt,
            diabetesData: diabetesData
        )
    }
}
