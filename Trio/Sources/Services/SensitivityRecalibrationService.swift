import Foundation

// MARK: - Phase G: Claude Sensitivity Recalibration Service

/// Weekly service that sends meal outcome data to Claude for pattern analysis
/// and returns parameter adjustment recommendations.
///
/// This is non-blocking and async — runs weekly or on manual trigger.
/// Results are presented in the AI Insights UI for user review before applying.

// MARK: - Recalibration Result

/// Structured result from Claude's analysis of meal outcomes.
struct RecalibrationResult: Codable {
    let analysisDate: Date
    let periodDays: Int
    let mealsAnalyzed: Int

    // Recommended parameter updates
    let curveParameterUpdates: CurveParameterUpdates?
    let sensitivityWeightUpdates: SensitivityWeightUpdates?

    // Claude's analysis
    let patterns: [DetectedPattern]
    let explanation: String
    let confidence: ConfidenceLevel

    enum ConfidenceLevel: String, Codable {
        case high, medium, low
    }

    struct CurveParameterUpdates: Codable {
        let carbTau: ParameterUpdate?
        let proteinFactor: ParameterUpdate?
        let fatCoefficient: ParameterUpdate?
        let proteinThreshold: ParameterUpdate?
        let proteinPlateau: ParameterUpdate?
    }

    struct SensitivityWeightUpdates: Codable {
        let sleepWeight: ParameterUpdate?
        let bodyBatteryWeight: ParameterUpdate?
        let stressWeight: ParameterUpdate?
        let restingHRWeight: ParameterUpdate?
        let hrvWeight: ParameterUpdate?
        let activityYesterdayWeight: ParameterUpdate?
        let activityTodayWeight: ParameterUpdate?
    }

    struct ParameterUpdate: Codable {
        let currentValue: Double
        let recommendedValue: Double
        let rationale: String
        let confidence: ConfidenceLevel
    }

    struct DetectedPattern: Codable {
        let patternType: String
        let description: String
        let frequency: String
        let impact: String
        let confidence: ConfidenceLevel
    }
}

// MARK: - Recalibration Service

final class SensitivityRecalibrationService {

    private let outcomeStore = V2OutcomeLearningStore.shared
    private let apiService = ClaudeAPIService()

    // MARK: - System Prompt

    static let recalibrationSystemPrompt = """
    You are a diabetes insulin sensitivity calibration expert analyzing meal outcome data from an automated insulin delivery system (Trio).

    The system uses a three-curve absorption model:
    1. Carb curve: Gamma(2, tau) — tau is the time constant in minutes (default 35, higher = slower absorption)
    2. Protein curve: Delayed sigmoid — proteinFactor (0-0.35) controls gluconeogenesis magnitude, with threshold (15g) and plateau (40g)
    3. Fat curve: Normalized Gaussian — fatCoefficient (default 0.69) is total carb-equivalent per gram of fat

    The system also uses a Garmin-based sensitivity model with rule weights:
    - Sleep quality/duration → insulin resistance
    - Body Battery → recovery state
    - Stress levels → acute resistance
    - Resting HR delta → physiological stress
    - HRV delta → autonomic balance
    - Activity (yesterday/today) → delayed sensitivity improvement

    ANALYSIS TASKS:
    1. Identify patterns the model missed (time-of-day effects, day-of-week patterns, specific food combinations)
    2. Recommend curve parameter adjustments based on systematic over/under-prediction
    3. Recommend Garmin sensitivity weight adjustments if outcomes suggest certain metrics matter more/less
    4. Flag any concerning patterns (frequent lows, delayed highs correlating with specific contexts)

    IMPORTANT:
    - Be conservative — small parameter changes compound over many meals
    - Separate noise from signal — only recommend changes with clear evidence from multiple meals
    - Consider confounding factors before attributing error to model parameters
    - When uncertain, recommend no change rather than a potentially harmful one

    OUTPUT FORMAT:
    Respond with a valid JSON object:
    {
      "curve_parameter_updates": {
        "carb_tau": {"current": X, "recommended": Y, "rationale": "...", "confidence": "high|medium|low"} | null,
        "protein_factor": {...} | null,
        "fat_coefficient": {...} | null,
        "protein_threshold": {...} | null,
        "protein_plateau": {...} | null
      },
      "sensitivity_weight_updates": {
        "sleep_weight": {...} | null,
        "body_battery_weight": {...} | null,
        "stress_weight": {...} | null,
        "resting_hr_weight": {...} | null,
        "hrv_weight": {...} | null,
        "activity_yesterday_weight": {...} | null,
        "activity_today_weight": {...} | null
      },
      "patterns": [
        {"pattern_type": "...", "description": "...", "frequency": "...", "impact": "...", "confidence": "high|medium|low"}
      ],
      "explanation": "Natural language summary of findings and recommendations",
      "confidence": "high|medium|low",
      "meals_analyzed": N
    }
    """

    // MARK: - Run Recalibration

    /// Run weekly recalibration analysis.
    /// Returns nil if insufficient data or API unavailable.
    func runRecalibration(
        apiKey: String,
        lastDays: Int = 7
    ) async -> RecalibrationResult? {
        let export = outcomeStore.exportForRecalibration(lastDays: lastDays)

        guard !export.outcomes.isEmpty else {
            debugPrint("SensitivityRecalibration: No outcomes to analyze")
            return nil
        }

        // Build the data prompt
        let dataPrompt = buildDataPrompt(from: export)

        do {
            let response = try await apiService.analyze(
                prompt: dataPrompt,
                apiKey: apiKey,
                systemPrompt: Self.recalibrationSystemPrompt
            )

            return parseRecalibrationResponse(response, export: export)
        } catch {
            debugPrint("SensitivityRecalibration: API error: \(error)")
            return nil
        }
    }

    // MARK: - Build Prompt

    private func buildDataPrompt(from export: V2RecalibrationExport) -> String {
        var prompt = "Analyze these \(export.outcomes.count) meal outcomes from the last \(export.periodDays) days.\n\n"

        // Current parameters
        prompt += "CURRENT MODEL PARAMETERS:\n"
        prompt += "- Carb tau: \(export.currentParameters.effectiveCarbTau) min\n"
        prompt += "- Protein factor: \(export.currentParameters.effectiveProteinFactor)\n"
        prompt += "- Protein threshold: \(export.currentParameters.effectiveProteinThreshold)g\n"
        prompt += "- Protein plateau: \(export.currentParameters.effectiveProteinPlateau)g\n"
        prompt += "- Fat coefficient: \(export.currentParameters.effectiveFatTotalCoeff)\n\n"

        // Meal outcomes
        prompt += "MEAL OUTCOMES:\n"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        for (i, outcome) in export.outcomes.enumerated() {
            prompt += "\n--- Meal \(i + 1): \(dateFormatter.string(from: outcome.date)) ---\n"
            prompt += "Macros: \(Int(outcome.carbs))g carbs, \(Int(outcome.fat))g fat, \(Int(outcome.protein))g protein\n"
            prompt += "Params: tau=\(String(format: "%.0f", outcome.tauCarb)), "
            prompt += "protFactor=\(String(format: "%.2f", outcome.proteinFactor)), "
            prompt += "fatEquiv=\(String(format: "%.1f", outcome.fatTotalEquiv))g\n"
            prompt += "Dosing: \(Int(outcome.upfrontPercent * 100))% upfront, "
            prompt += "demand=\(String(format: "%.2f", outcome.insulinDemandFactor)), "
            prompt += "BG@meal=\(outcome.bgAtMeal), CR=\(String(format: "%.1f", outcome.carbRatioAtMeal)), "
            prompt += "ISF=\(String(format: "%.0f", outcome.isfAtMeal))\n"

            if outcome.mealModeWasActive {
                prompt += "Meal-mode SMBs: active (\(String(format: "%.1f", outcome.mealSMBMultiplier))x)\n"
            }

            // BG checkpoints
            let cpStrings = outcome.checkpoints.compactMap { cp -> String? in
                guard let bg = cp.bgValue else { return nil }
                let clean = cp.isClean ? "" : " [confounded]"
                return "\(cp.hoursAfterMeal)h: \(bg)\(clean) [\(cp.curvePhase.rawValue)]"
            }
            if !cpStrings.isEmpty {
                prompt += "BG: \(cpStrings.joined(separator: ", "))\n"
            }

            // Adaptive adjustments
            if !outcome.adaptiveAdjustments.isEmpty {
                let adjStrings = outcome.adaptiveAdjustments.map {
                    String(format: "%.2fx (actual:%d predicted:%d)", $0.scalingFactor, Int($0.actualBG), Int($0.predictedBG))
                }
                prompt += "Adaptive: \(adjStrings.joined(separator: ", "))\n"
            }

            // Garmin context
            if let garmin = outcome.garminSnapshot {
                var garminParts: [String] = []
                if let sleep = garmin.sleepScore { garminParts.append("sleep:\(sleep)") }
                if let bb = garmin.currentBodyBattery { garminParts.append("BB:\(bb)") }
                if let stress = garmin.currentStress { garminParts.append("stress:\(stress)") }
                if let steps = garmin.stepsYesterday { garminParts.append("stepsYest:\(steps)") }
                if let cal = garmin.activeCaloriesYesterday { garminParts.append("calYest:\(cal)") }
                if !garminParts.isEmpty {
                    prompt += "Garmin: \(garminParts.joined(separator: ", "))\n"
                }
            }

            if outcome.hasConfoundingMeal {
                prompt += "NOTE: Confounding meal detected in observation window\n"
            }
        }

        return prompt
    }

    // MARK: - Parse Response

    private func parseRecalibrationResponse(
        _ response: String,
        export: V2RecalibrationExport
    ) -> RecalibrationResult? {
        // Try to extract JSON from the response
        guard let jsonData = extractJSON(from: response) else {
            debugPrint("SensitivityRecalibration: Could not extract JSON from response")
            return nil
        }

        do {
            let raw = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            guard let dict = raw else { return nil }

            let confidence = RecalibrationResult.ConfidenceLevel(
                rawValue: dict["confidence"] as? String ?? "low"
            ) ?? .low

            let patterns = (dict["patterns"] as? [[String: Any]] ?? []).map { p in
                RecalibrationResult.DetectedPattern(
                    patternType: p["pattern_type"] as? String ?? "",
                    description: p["description"] as? String ?? "",
                    frequency: p["frequency"] as? String ?? "",
                    impact: p["impact"] as? String ?? "",
                    confidence: RecalibrationResult.ConfidenceLevel(
                        rawValue: p["confidence"] as? String ?? "low"
                    ) ?? .low
                )
            }

            let curveUpdates = parseCurveUpdates(dict["curve_parameter_updates"] as? [String: Any])
            let sensitivityUpdates = parseSensitivityUpdates(dict["sensitivity_weight_updates"] as? [String: Any])

            return RecalibrationResult(
                analysisDate: Date(),
                periodDays: export.periodDays,
                mealsAnalyzed: export.outcomes.count,
                curveParameterUpdates: curveUpdates,
                sensitivityWeightUpdates: sensitivityUpdates,
                patterns: patterns,
                explanation: dict["explanation"] as? String ?? response,
                confidence: confidence
            )
        } catch {
            debugPrint("SensitivityRecalibration: JSON parse error: \(error)")
            return nil
        }
    }

    private func parseCurveUpdates(_ dict: [String: Any]?) -> RecalibrationResult.CurveParameterUpdates? {
        guard let dict = dict else { return nil }
        return RecalibrationResult.CurveParameterUpdates(
            carbTau: parseParameterUpdate(dict["carb_tau"]),
            proteinFactor: parseParameterUpdate(dict["protein_factor"]),
            fatCoefficient: parseParameterUpdate(dict["fat_coefficient"]),
            proteinThreshold: parseParameterUpdate(dict["protein_threshold"]),
            proteinPlateau: parseParameterUpdate(dict["protein_plateau"])
        )
    }

    private func parseSensitivityUpdates(_ dict: [String: Any]?) -> RecalibrationResult.SensitivityWeightUpdates? {
        guard let dict = dict else { return nil }
        return RecalibrationResult.SensitivityWeightUpdates(
            sleepWeight: parseParameterUpdate(dict["sleep_weight"]),
            bodyBatteryWeight: parseParameterUpdate(dict["body_battery_weight"]),
            stressWeight: parseParameterUpdate(dict["stress_weight"]),
            restingHRWeight: parseParameterUpdate(dict["resting_hr_weight"]),
            hrvWeight: parseParameterUpdate(dict["hrv_weight"]),
            activityYesterdayWeight: parseParameterUpdate(dict["activity_yesterday_weight"]),
            activityTodayWeight: parseParameterUpdate(dict["activity_today_weight"])
        )
    }

    private func parseParameterUpdate(_ raw: Any?) -> RecalibrationResult.ParameterUpdate? {
        guard let dict = raw as? [String: Any],
              let current = dict["current"] as? Double,
              let recommended = dict["recommended"] as? Double
        else { return nil }

        return RecalibrationResult.ParameterUpdate(
            currentValue: current,
            recommendedValue: recommended,
            rationale: dict["rationale"] as? String ?? "",
            confidence: RecalibrationResult.ConfidenceLevel(
                rawValue: dict["confidence"] as? String ?? "low"
            ) ?? .low
        )
    }

    private func extractJSON(from text: String) -> Data? {
        // Try to find JSON object in the response
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}")
        {
            let jsonString = String(text[start ... end])
            return jsonString.data(using: .utf8)
        }
        return nil
    }

    // MARK: - Apply Results

    /// Apply recalibration results to personal parameters.
    /// Only applies updates with medium or high confidence.
    func applyResults(_ result: RecalibrationResult, minimumConfidence: RecalibrationResult.ConfidenceLevel = .medium) {
        var params = outcomeStore.loadParameters()
        let minLevel = confidenceLevel(minimumConfidence)

        if let curveUpdates = result.curveParameterUpdates {
            if let update = curveUpdates.carbTau, confidenceLevel(update.confidence) >= minLevel {
                params.carbTau = clamp(update.recommendedValue, min: 20, max: 60)
            }
            if let update = curveUpdates.proteinFactor, confidenceLevel(update.confidence) >= minLevel {
                params.proteinFactor = clamp(update.recommendedValue, min: 0.10, max: 0.60)
            }
            if let update = curveUpdates.fatCoefficient, confidenceLevel(update.confidence) >= minLevel {
                params.fatTotalCoeff = clamp(update.recommendedValue, min: 0.30, max: 1.20)
            }
            if let update = curveUpdates.proteinThreshold, confidenceLevel(update.confidence) >= minLevel {
                params.proteinThreshold = clamp(update.recommendedValue, min: 10, max: 25)
            }
            if let update = curveUpdates.proteinPlateau, confidenceLevel(update.confidence) >= minLevel {
                params.proteinPlateau = clamp(update.recommendedValue, min: 30, max: 60)
            }
        }

        if let sensitivityUpdates = result.sensitivityWeightUpdates {
            if let u = sensitivityUpdates.sleepWeight, confidenceLevel(u.confidence) >= minLevel {
                params.sleepWeight = clamp(u.recommendedValue, min: 0.05, max: 0.40)
            }
            if let u = sensitivityUpdates.bodyBatteryWeight, confidenceLevel(u.confidence) >= minLevel {
                params.bodyBatteryWeight = clamp(u.recommendedValue, min: 0.05, max: 0.30)
            }
            if let u = sensitivityUpdates.stressWeight, confidenceLevel(u.confidence) >= minLevel {
                params.stressWeight = clamp(u.recommendedValue, min: 0.02, max: 0.15)
            }
            if let u = sensitivityUpdates.restingHRWeight, confidenceLevel(u.confidence) >= minLevel {
                params.restingHRWeight = clamp(u.recommendedValue, min: 0.03, max: 0.20)
            }
            if let u = sensitivityUpdates.hrvWeight, confidenceLevel(u.confidence) >= minLevel {
                params.hrvWeight = clamp(u.recommendedValue, min: 0.02, max: 0.15)
            }
            if let u = sensitivityUpdates.activityYesterdayWeight, confidenceLevel(u.confidence) >= minLevel {
                params.activityYesterdayWeight = clamp(u.recommendedValue, min: 0.03, max: 0.25)
            }
            if let u = sensitivityUpdates.activityTodayWeight, confidenceLevel(u.confidence) >= minLevel {
                params.activityTodayWeight = clamp(u.recommendedValue, min: 0.02, max: 0.15)
            }
        }

        outcomeStore.saveParameters(params)
    }

    private func confidenceLevel(_ level: RecalibrationResult.ConfidenceLevel) -> Int {
        switch level {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }
}
