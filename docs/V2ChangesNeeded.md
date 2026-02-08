# V2 Dosing Strategy — Changes Needed

**Date:** February 8, 2026
**Sources:** Internal code review + commissioned external critique
**Scope:** V2DosingStrategy.md, MacroAbsorptionEngine.swift, MacroAdaptiveService.swift, V2CurveOutcomeLearning.swift, GarminSensitivityModel.swift, V2MacroDosingSettingsView.swift

---

## Summary

The core three-curve model, split dosing logic, and curve math are solid. The issues live in the adaptive/learning layers, safety gates, and a few whitepaper-to-code mismatches. Below are 13 specific changes grouped by priority.

---

## HIGH PRIORITY

### 1. BG-Adaptive Service Uses Total IOB Instead of Meal-Attributed IOB

**File:** `Trio/Sources/Services/MacroAdaptiveService.swift`, line 201

**Current code:**
```swift
let predictedBGImpact = (absorbedCarbs / cr) * isf - currentIOB * isf
```

**Problem:** `currentIOB` is total insulin on board from all sources — basal, corrections, prior meals, manual boluses. The formula compares a meal-specific carb absorption prediction against system-wide IOB. A large correction bolus from a prior high inflates `currentIOB`, making `predictedBGImpact` very negative, making `error` very positive, which scales UP remaining entries even though the meal itself is absorbing correctly.

Additionally, oref is independently issuing correction SMBs for the same high BG. The adaptive service scales up future entries to deliver more insulin, and oref issues corrections to deliver more insulin — double-correcting the same problem. The 50% damping and 0.5–1.5 cycle clamp reduce but do not eliminate this.

**Change:** Track meal-attributed IOB separately. When the upfront bolus is delivered and SMBs are issued against V2 entries, accumulate the insulin attributed to this mealID. Use that meal-specific IOB in the prediction formula instead of total system IOB:

```swift
let mealIOB = getMealAttributedIOB(mealID: mealID)  // new function
let predictedBGImpact = (absorbedCarbs / cr) * isf - mealIOB * isf
```

This requires either tagging insulin doses with mealID in Core Data, or estimating meal IOB from the bolus + SMBs delivered while V2 entries were active for this meal.

**Why:** Without this, every adaptive adjustment is contaminated by non-meal insulin. The system could systematically over-dose on meals that happen after correction boluses.

---

### 2. BG-Adaptive "Actual Trend" Extrapolation Is Inaccurate

**File:** `Trio/Sources/Services/MacroAdaptiveService.swift`, line 209

**Current code:**
```swift
let trendBasedActual = trend * (absorbedAndRemaining.minutesSinceFirst / 5.0)
```

**Problem:** This takes the current 5-minute CGM trend and linearly extrapolates it across the entire duration since the first entry. If the meal started 3 hours ago and the current trend is +2 mg/dL/5min, this yields `2 × (180/5) = 72 mg/dL` — "what would happen if the current rate held for 3 hours," not "what actually happened over 3 hours." A meal that spiked 60 mg/dL at hour 1 and is now flat at +2/5min would be treated identically to one that was flat for 3 hours and just started rising.

**Change:** Use cumulative CGM delta instead of trend extrapolation. Record the BG at meal start (already stored as `bgAtMeal` in V2MealOutcome) and compute:

```swift
let actualBGDelta = currentBG - mealStartBG
let error = actualBGDelta - predictedBGImpact
```

This requires passing `bgAtMeal` into the adaptive cycle, either by looking it up from the V2MealOutcome or storing it when the meal is created.

**Why:** The current formula produces wildly different error values depending on transient CGM noise. A cumulative delta reflects what actually happened.

---

### 3. Static Phase Attribution Ignores Actual Meal Composition

**File:** `Trio/Sources/Services/V2CurveOutcomeLearning.swift`, lines 381–388

**Current code:**
```swift
checkpoints: [
    V2BGCheckpoint(hoursAfterMeal: 1, bgValue: nil, isClean: true, curvePhase: .carb),
    V2BGCheckpoint(hoursAfterMeal: 2, bgValue: nil, isClean: true, curvePhase: .carb),
    V2BGCheckpoint(hoursAfterMeal: 3, bgValue: nil, isClean: true, curvePhase: .protein),
    V2BGCheckpoint(hoursAfterMeal: 4, bgValue: nil, isClean: true, curvePhase: .overlap),
    V2BGCheckpoint(hoursAfterMeal: 6, bgValue: nil, isClean: true, curvePhase: .fat),
    V2BGCheckpoint(hoursAfterMeal: 8, bgValue: nil, isClean: true, curvePhase: .fat),
],
```

**Problem:** Phase attribution is hardcoded regardless of what the person actually ate. For a meal with 80g carbs, 40g fat, and only 8g protein (below the 15g threshold), zero protein entries are generated. Yet the 3h checkpoint is still tagged `.protein` and BG errors at 3h adjust `proteinFactor` — a parameter that had no effect on this meal. Similarly, for a low-fat meal (3g fat, below the 5g threshold), the 6h and 8h checkpoints still attribute errors to the fat curve.

Compounding this: the 3–5h overlap zone is the most ambiguous window physiologically. A high BG at 4h could mean carb tau is wrong, protein factor is wrong, or fat is hitting earlier than modeled. Distributing error at 30% weight to all three curves may just add noise to all parameters.

**Change:** Compute phase attribution dynamically based on the actual macros at meal time:

```swift
static func computePhases(carbs: Double, fat: Double, protein: Double,
                           proteinThreshold: Double) -> [V2BGCheckpoint] {
    let hasProtein = protein > proteinThreshold
    let hasFat = fat >= 5

    return [
        V2BGCheckpoint(hoursAfterMeal: 1, curvePhase: .carb),
        V2BGCheckpoint(hoursAfterMeal: 2, curvePhase: .carb),
        V2BGCheckpoint(hoursAfterMeal: 3, curvePhase: hasProtein ? .protein : .carb),
        V2BGCheckpoint(hoursAfterMeal: 4, curvePhase: hasProtein && hasFat ? .overlap :
                                                       hasProtein ? .protein :
                                                       hasFat ? .fat : .carb),
        V2BGCheckpoint(hoursAfterMeal: 6, curvePhase: hasFat ? .fat : .skip),
        V2BGCheckpoint(hoursAfterMeal: 8, curvePhase: hasFat ? .fat : .skip),
    ]
}
```

Additionally, consider dropping the `.overlap` phase from parameter learning entirely (external critique recommendation). Only learn from clean single-curve checkpoints — 1h/2h for carbs, 6h/8h for fat — and skip the ambiguous middle zone. This may converge slower but more accurately.

**Why:** Wrong attribution = wrong parameter adjustments = the system learns the wrong lessons from every meal that doesn't have all three macros in significant amounts.

---

### 4. Confounding Meal Detection Is Dead Code

**File:** `Trio/Sources/Services/V2CurveOutcomeLearning.swift`, line 389

**Current code:**
```swift
hasConfoundingMeal: false   // hardcoded, never set to true
```

The learning system filters on this flag (line 257: `!outcome.hasConfoundingMeal`), but nothing ever sets it to `true`. If a user eats a snack 2 hours after lunch, the lunch outcome's 4h/6h/8h checkpoints reflect both meals, but errors are attributed to the lunch curves.

**Change:** Implement confounding meal detection in the backfill method. When backfilling checkpoints for outcome X, check if any other V2MealOutcome was recorded between X's meal time and X's last checkpoint time:

```swift
func detectConfoundingMeals() {
    var outcomes = loadAll()
    for i in 0..<outcomes.count {
        let mealTime = outcomes[i].date
        let windowEnd = mealTime.addingTimeInterval(8 * 3600)  // 8h window
        let hasOverlap = outcomes.contains { other in
            other.id != outcomes[i].id &&
            other.date > mealTime &&
            other.date < windowEnd
        }
        if hasOverlap {
            outcomes[i].hasConfoundingMeal = true
        }
    }
    persistOutcomes(outcomes)
}
```

For a more nuanced approach (per the external critique), instead of binary exclusion, mark individual checkpoints as clean/dirty based on whether a confounding meal's absorption window overlaps that specific checkpoint time.

**Why:** Without this, every meal followed by a snack within 8 hours corrupts the learning data. Most people eat more than once per 8-hour window.

---

### 5. Add IOB Safety Gate for SMB Enhancement

**File:** `Trio/Sources/Services/MacroAdaptiveService.swift`, lines 20–49

**Current gates:** (1) active meal entries, (2) BG above floor, (3) trend flat/rising, (4) CGM fresh.

**Missing gate:** No check on whether IOB already exceeds predicted remaining absorption. Scenario: BG is 95 and flat, all four gates pass, meal-mode multiplier delivers an enhanced SMB. But there's already 8 units of IOB from the upfront bolus + earlier SMBs, with only 5g of carb entries remaining. The stacked insulin will cause a crash once it peaks.

**Change:** Add Gate 5 — IOB vs remaining absorption:

```swift
// Gate 5: IOB should not exceed remaining predicted need
// remainingCarbs / CR = insulin still needed; if IOB > that, back off
let remainingInsulinNeed = remainingCarbsForActiveMeals / carbRatio
guard currentIOB <= remainingInsulinNeed * 1.2 else { return baseState }  // 20% buffer
```

This requires passing `currentIOB`, `carbRatio`, and the sum of remaining carb entries into `MealModeState.evaluate()`.

**Why:** The existing gates protect against low BG and falling trends, but not against insulin stacking where BG hasn't dropped *yet*. This is a real hypoglycemia vector — BG can look fine while insulin is accumulating, then crash 30–60 minutes later.

---

## MEDIUM PRIORITY

### 6. Fat Coefficient Should Be Nonlinear

**File:** `Trio/Sources/Models/MacroAbsorptionEngine.swift`, lines 146–148

**Current code:**
```swift
fatTotalEquiv = fat * params.effectiveFatTotalCoeff   // linear: 0.69 * fat_grams
```

**Problem:** The default coefficient of 0.69 is derived from Wolpert (2013) who studied 50g fat meals (+42% insulin). But Bell (2020) found the dose-response is nonlinear: 60g fat needed +21%, 40g fat needed +6%, 20g fat needed +6%. A single linear coefficient overcharges moderate-fat meals (where the effect is small) and may undercharge extreme-fat meals.

The jump from the Wolpert-derived 0.55 to 0.69 is described as targeting "median-to-upper range" — a design choice presented as a derivation.

**Change:** Replace the linear coefficient with a saturating ramp, similar to the existing protein model:

```swift
static func fatCarbEquivalent(fatGrams: Double, maxCoeff: Double = 0.69,
                               threshold: Double = 10, plateau: Double = 50) -> Double {
    guard fatGrams >= 5 else { return 0 }
    if fatGrams <= threshold { return fatGrams * 0.10 }  // modest effect below 10g
    if fatGrams >= plateau { return fatGrams * maxCoeff }
    let rampFraction = (fatGrams - threshold) / (plateau - threshold)
    let effectiveCoeff = 0.10 + rampFraction * (maxCoeff - 0.10)
    return fatGrams * effectiveCoeff
}
```

This would give:
- 10g fat → 1.0g equiv (vs current 6.9g)
- 20g fat → 5.6g equiv (vs current 13.8g)
- 28g fat → 10.8g equiv (vs current 19.3g)
- 50g fat → 34.5g equiv (same as current)

The result: moderate-fat meals get less aggressive dosing (matching Bell 2020), high-fat meals are unchanged.

**Why:** The linear model treats a 10g-fat sandwich the same per-gram as a 50g-fat pizza. The literature says they're qualitatively different.

---

### 7. Gate 3 Trend Threshold: Code Does Not Match Whitepaper

**File:** `Trio/Sources/Services/MacroAdaptiveService.swift`, line 38

**Current code:**
```swift
guard let trend = bgTrend, trend >= -1.0 else { return baseState }
```

**Whitepaper (V2DosingStrategy.md, Section 9) says:**
> the delta between the two most recent readings must be ≥ −5 mg/dL per 5 minutes

The code threshold of `-1.0 mg/dL/5min` is 5x more restrictive than the documented `-5 mg/dL/5min`. A barely-perceptible -1.1 mg/dL dip disables meal-mode enhancement.

**Change:** Either:
- (a) Update the code to match the whitepaper: `trend >= -5.0`
- (b) If `-1.0` is intentionally conservative, update the whitepaper to document the actual threshold

Recommendation: use `-3.0` as a compromise — allows normal post-bolus settling but cuts off before a true downward trend.

**Why:** The discrepancy means meal-mode enhancement is disabled far more often than the whitepaper describes. Anyone reading the whitepaper to understand system behavior will have wrong expectations.

---

### 8. Garmin Sensitivity Weights Need Epistemic Disclaimer

**File:** `docs/V2DosingStrategy.md`, Section 8 + `Trio/Sources/Models/GarminSensitivityModel.swift`

**Problem:** The impact weights (sleep < 40 → -0.22, Body Battery < 15 → -0.18, etc.) are hand-tuned heuristics, not derived from regression or clinical data. The Donga (2010) paper found ~25% reduction from one night of 4h sleep, but the Garmin model can stack to a 1.67x demand factor (67% increase) from multiple metrics. The individual weights and their additivity are unvalidated.

The whitepaper presents these weights with the same confidence as the literature-derived absorption curves.

**Change in whitepaper:** Add a subsection explicitly stating:
- The weights are starting heuristics based on directional findings from the literature
- The specific magnitudes are estimated, not calibrated against BG outcome data
- The outcome learning system is intended to validate and adjust these over time
- Users should monitor the demand factor's effect on their outcomes and adjust or disable if results are poor

**Change in code:** Add a comment block at the top of `GarminSensitivityModel.swift` noting the heuristic nature:

```swift
// NOTE: Impact weights are initial heuristics, not regression-derived.
// They are directionally grounded in literature but magnitudes are estimated.
// The outcome learning system validates these over time.
```

**Why:** Users and reviewers should know the difference between "0.69 coefficient from Wolpert's 42% finding" and "sleep < 40 → -0.22 because it felt about right."

---

### 9. Cumulative Scaling State Lost on App Restart

**File:** `Trio/Sources/Services/MacroAdaptiveService.swift`, line 104

**Current code:**
```swift
private var cumulativeScaling: [String: Double] = [:]  // instance variable, lost on restart
```

**Problem:** If the app is killed and restarted mid-meal, `cumulativeScaling` resets to empty. The next adaptive cycle treats the meal as if no adjustments were ever made, allowing a fresh ±100% range of scaling on top of whatever was already applied to the persisted Core Data entries. A meal that was already scaled up 80% could be scaled up another 100% after restart.

**Change:** Persist cumulative scaling state alongside the meal. Options:
- (a) Store it in the V2MealOutcome record (already persisted to UserDefaults)
- (b) Write it to a small separate UserDefaults key keyed by mealID
- (c) Store it as a property on the CarbEntryStored entities themselves

Option (a) is simplest — add a `cumulativeAdaptiveScaling: Double` field to V2MealOutcome and read it back on service initialization.

**Why:** The cumulative clamp (0.0–2.0) is a safety limit. Losing state defeats the limit.

---

## LOW PRIORITY

### 10. Protein Factor Range Inconsistency

**File:** `V2MacroDosingSettingsView.swift`, line 137 vs `V2CurveOutcomeLearning.swift`, line 335

**Settings slider:**
```swift
Slider(value: $proteinFactor, in: 0.10 ... 0.80, step: 0.01)
```

**Learning system clamp:**
```swift
params.proteinFactor = max(0.10, min(0.60, current + avgAdj))
```

**Whitepaper:**
- Section 5 parameterization table: range 0.10–0.80
- Section 11 clamping table: range 0.10–0.60

A user could set proteinFactor to 0.70 via the slider, then the learning system silently clamps it to 0.60 on the next recalibration.

**Change:** Unify the ranges. Either:
- (a) Learning clamp matches slider: `max(0.10, min(0.80, ...))`
- (b) Slider matches learning: `in: 0.10 ... 0.60`
- (c) Learning respects the user's manual setting as a ceiling — only adjust within the range below the user's slider position

Recommendation: (a), since the slider range is the user-facing contract. Update both the code and the whitepaper Section 11 table.

**Why:** Silent overwriting of user settings erodes trust in the system.

---

### 11. Missing 5-Hour Checkpoint

**File:** `Trio/Sources/Services/V2CurveOutcomeLearning.swift`, lines 381–388

**Current checkpoints:** 1h, 2h, 3h, 4h, 6h, 8h

**Problem:** The protein curve peaks at 4–5h. The 4h checkpoint is tagged `.overlap`. There's a 2-hour gap (4h→6h) that misses the protein peak entirely. The fat curve doesn't peak until 6h, so the 6h checkpoint is dominated by fat. There's no clean protein-peak observation.

**Change:** Add a 5h checkpoint:

```swift
V2BGCheckpoint(hoursAfterMeal: 5, bgValue: nil, isClean: true, curvePhase: .protein),
```

**Why:** Better signal for protein parameter learning. Currently the system only observes protein at 3h (during onset, not peak) and 4h (tagged overlap).

---

### 12. Claude AI Recalibration Is Underspecified

**File:** `docs/V2DosingStrategy.md`, Section 11 (Claude AI Recalibration subsection)

**Problem:** The whitepaper devotes 3 sentences to the Claude integration. It doesn't describe:
- What prompt is sent to Claude
- What structured output format is expected
- How the response is validated (e.g., JSON schema check)
- What prevents Claude from returning parameters outside clamped ranges
- How hallucinated or malformed responses are handled
- Rate limiting / cost management
- Whether the user sees the recommendation before it's applied

**Change:** Expand the whitepaper section to cover prompt structure, expected JSON schema, validation pipeline, parameter clamping on Claude output, user confirmation flow, and error handling. If this is implemented in code, document the corresponding service.

**Why:** An AI system adjusting insulin dosing parameters with no documented guardrails is a safety and trust concern.

---

### 13. UserDefaults for Outcome Storage

**File:** `Trio/Sources/Services/V2CurveOutcomeLearning.swift`, lines 131–159

**Current code:**
```swift
guard let data = UserDefaults.standard.data(forKey: outcomesKey) else { return [] }
var outcomes = try JSONDecoder().decode([V2MealOutcome].self, from: data)
```

**Problem:** All outcomes (with nested Garmin snapshots, adaptive adjustment arrays, checkpoint arrays) are serialized as a single JSON blob in UserDefaults. Over 90 days at 3 meals/day, that's ~270 records fully deserialized on every `loadAll()` call. UserDefaults is backed by a single plist loaded into memory and is not designed for this access pattern.

**Change:** Migrate to Core Data (the app already uses it extensively) or a lightweight SQLite store. The `V2MealOutcome` maps naturally to a Core Data entity with relationships to checkpoints and adaptive adjustments.

**Why:** Performance degrades as data accumulates. UserDefaults can also have size limits on some platforms.

---

### 14. Gentilcore Liquid Fat Caveat

**File:** `docs/V2DosingStrategy.md`, Section 4

**Current text:**
> Where 0.8 minutes per gram of fat is derived from gastric emptying studies (Gentilcore et al., 2006; Horowitz et al., 1993).

**Problem:** Gentilcore studied liquid fat loads (olive oil infused into the duodenum), not mixed solid meals. Solid food with fat may empty differently — mechanical breakdown adds delay, fat mixed into a food matrix releases differently than pure oil.

**Change:** Add a caveat:
> Note: The 0.8 min/g coefficient is derived from liquid fat load studies. Solid food with fat may exhibit different gastric emptying rates due to mechanical breakdown. This coefficient serves as a starting point; the outcome learning system adjusts effective τ from real meal data.

**Why:** Intellectual honesty. The coefficient is directionally correct but the source doesn't perfectly match the use case.

---

### 15. Add Fiber Modifier to Carb Absorption Tau

**File:** `Trio/Sources/Models/MacroAbsorptionEngine.swift`, line 209–212

**Current code:**
```swift
static func carbTau(baseTau: Double, fatGrams: Double) -> Double {
    let fatSlowingCoefficient = 0.8 // minutes per gram of fat
    return baseTau + (fatGrams * fatSlowingCoefficient)
}
```

**Problem:** The carb absorption time constant τ is modified by fat (which slows gastric emptying) but not by dietary fiber. High-fiber meals independently slow gastric emptying and glucose absorption through multiple mechanisms:

- Soluble fiber forms a viscous gel in the stomach and small intestine, physically slowing carb access to the intestinal wall
- Fiber delays gastric emptying independent of fat content (Torsdottir et al., 1991; Jenkins et al., 1978)
- High-fiber meals produce lower and later glycemic peaks even with identical carb content

A 60g carb lentil bowl with 15g fiber and 3g fat currently gets essentially the same τ as 60g of white rice with 3g fat — the model treats them identically despite dramatically different absorption profiles. The lentils would peak later and lower, but the system would still deliver the same upfront bolus percentage.

**Data source:** Fiber is already available in Apple Health as part of the nutritional data from Cronometer. It can be extracted from meal snapshots using the same `HKQuantityType(.dietaryFiber)` query used for carbs, fat, and protein — no new data pipeline needed.

**Change:** Add a fiber slowing coefficient to `carbTau`:

```swift
static func carbTau(baseTau: Double, fatGrams: Double, fiberGrams: Double = 0) -> Double {
    let fatSlowingCoefficient = 0.8   // minutes per gram of fat
    let fiberSlowingCoefficient = 0.3 // minutes per gram of fiber above threshold
    let fiberThreshold = 5.0          // below this, fiber effect is negligible

    let fatDelay = fatGrams * fatSlowingCoefficient
    let fiberDelay = max(0, fiberGrams - fiberThreshold) * fiberSlowingCoefficient

    return baseTau + fatDelay + fiberDelay
}
```

The 0.3 min/g coefficient is conservative — fiber's effect on gastric emptying is real but smaller than fat's. The 5g threshold avoids adjusting for trace amounts. Example impacts:

| Meal | Fat | Fiber | τ_base | τ_effective | Current τ (no fiber) |
|------|-----|-------|--------|-------------|---------------------|
| White rice | 3g | 1g | 35 | 37.4 min | 37.4 min (same) |
| Lentil bowl | 3g | 15g | 35 | 40.4 min | 37.4 min |
| Bean burrito | 18g | 12g | 35 | 51.5 min | 49.4 min |
| High-fiber cereal | 2g | 28g | 35 | 43.5 min | 36.6 min |

The high-fiber cereal case is the most impactful: without fiber adjustment, it gets nearly the same τ as juice. With fiber, τ increases by 7 minutes, reducing the upfront bolus and extending SMB delivery — matching the slower absorption profile.

**Downstream changes needed:**
- `MacroAbsorptionEngine.generateEntries()`: pass fiber into `carbTau()`
- `MacroAbsorptionResult`: add `originalFiber: Double` field
- Cronometer meal snapshot extraction: add `HKQuantityType(.dietaryFiber)` query
- `V2MealOutcome`: add `fiber: Double` field for outcome tracking
- `V2MacroDosingSettingsView`: show fiber's effect in the example calculation
- `V2DosingStrategy.md`: document fiber modifier in Section 4

**Why:** Fiber is a well-established independent modifier of carb absorption rate. The data is already available from Cronometer via Apple Health. The implementation cost is minimal — one additional term in an existing function — and it closes the most obvious gap in the carb absorption model. A high-fiber, low-fat meal is currently the scenario where the model is most wrong.

---

## Items NOT Changed (Confirmed Correct)

The following were reviewed and found to be correctly implemented:

- Gamma(2, τ) CDF/PDF formulas
- Fat modification of τ: `baseTau + fat × 0.8`
- 95% absorption duration: `τ × 4.74`
- Protein smooth ramp with threshold/plateau/maxFactor
- Protein sigmoid × Gaussian-decay temporal shape (onset 180 min, steepness 40, peak 300, decay σ 120)
- Fat Gaussian (center 360, σ 90, floor at 120 min)
- Normalized entry generation for all three curves (sums to exact total)
- Safety invariant: upfront carbs returned for bolus, not stored as Core Data entries
- Insulin demand factor applied to both upfront and future entries
- All Garmin sensitivity thresholds and impacts match whitepaper tables
- Sensitivity factor clamp 0.60–1.40, demand factor inversion `1/sensitivityFactor`
- Outcome learning: recency weighting formula, ICR ±10% matching, per-phase error signs
- Carb tau adjustment direction (high BG → decrease tau → more upfront insulin)
- Settings UI slider ranges match whitepaper (except protein factor noted above)
- Example calculation in settings correctly uses engine functions
