# V3 Improvements — Safety, Logic, and UX/UI Redesign

**Date:** February 9, 2026
**Updated:** February 9, 2026 (post-review fixes)
**Sources:** Code review of V2 implementation, whitepaper comparison, UX audit, external safety review
**Scope:** Insulin safety fixes, logic corrections, complete treatment UX redesign, settings consolidation

---

## Table of Contents

- [Part 1: Insulin Safety Improvements](#part-1-insulin-safety-improvements)
- [Part 2: Logic Corrections](#part-2-logic-corrections)
- [Part 3: UX/UI Redesign — Treatment Flow](#part-3-uxui-redesign--treatment-flow)
- [Part 4: UX/UI Redesign — Settings Consolidation](#part-4-uxui-redesign--settings-consolidation)
- [Part 5: Implementation Status](#part-5-implementation-status)

---

## Part 1: Insulin Safety Improvements

### S1. Meal-Attributed IOB Uses oref-Matching Insulin Curves [IMPLEMENTED]

**Priority: HIGH**
**Risk: Over-delivery of insulin in the 6-8h window for high-fat meals**

**Problem:**
`MacroAdaptiveService.recordMealInsulin()` was a pure accumulator that never modeled insulin decay. For an 8-hour pizza meal, the 3U upfront bolus at t=0 has mostly decayed by t=6h (DIA is typically 4-6h), but `mealAttributedIOB` still reported the full 3U.

This caused the BG-adaptive formula to systematically over-estimate active insulin, making `error = actualBGDelta - predictedBGImpact` more positive, which scaled UP remaining entries — delivering more insulin in the 6-8h window than needed.

**Initial fix:** Linear decay: `fractionRemaining = max(0, 1.0 - age / dia)`

**Review finding:** Linear decay diverges from oref's actual IOB curves (bilinear quadratic or exponential), creating a new systematic bias where meal-attributed IOB tracks differently from system IOB.

**Final implementation:**
Ported oref's exact IOB curves from `trio-oref/lib/iob/calculate.js`:

```swift
enum IOBDecayCurve {
    case bilinear                          // Piecewise quadratic polynomials
    case exponential(peakMinutes: Double)   // rapid-acting: 75, ultra-rapid: 55

    func fractionRemaining(minsAgo: Double, diaHours: Double) -> Double
}
```

The bilinear model uses the same polynomial coefficients as oref (`-0.001852*x1*x1 + 0.001852*x1 + 1.0` pre-peak, `0.001323*x2*x2 - 0.054233*x2 + 0.555560` post-peak). The exponential model uses the LoopKit/Loop formula with tau, rise time factor, and auxiliary scale factor S.

`APSManager` reads the user's `InsulinCurve` preference (`.bilinear`, `.rapidActing`, `.ultraRapid`) and passes the corresponding `IOBDecayCurve` to `runAdaptiveCycle()`.

**Files:** `MacroAdaptiveService.swift`, `APSManager.swift`

---

### S2. Composite Demand Ceiling — Hardcoded at 2.5x [IMPLEMENTED]

**Priority: HIGH**
**Risk: Theoretical insulin delivery up to 3.34x original amount at elevated delivery rate**

**Problem:**
Three independent multipliers compound without cross-checks:
- Garmin demand factor: up to 1.67x
- BG-adaptive cumulative scaling: up to 2.0x
- Meal-mode SMB multiplier: up to 3.0x delivery rate

**Implementation:**
Added a composite ceiling in `scaleFutureEntries()` that caps `demandFactor × cumulativeScaling ≤ 2.5x`:

```swift
let compositeDemand = newCumulative * demandFactor
if compositeDemand > Self.defaultMaxCompositeDemand, demandFactor > 0 {
    newCumulative = Self.defaultMaxCompositeDemand / demandFactor
}
```

**Review finding:** The original plan made this configurable (range 1.5-3.5). The reviewer correctly identified this contradicts the UX philosophy of not exposing safety ceilings to users.

**Fix applied:** The 2.5x ceiling is now hardcoded as `private static let defaultMaxCompositeDemand = 2.5`. The `maxCompositeDemand` parameter was removed from `runAdaptiveCycle()` — it's purely internal.

**Review finding #2:** The ceiling caps entry amounts but doesn't account for the meal-mode SMB delivery rate multiplier.

**Fix applied:** Added rate limiting to `MealModeState.evaluate()`. When composite demand exceeds 1.5x:
- At 1.5-2.0x composite demand: SMB multiplier linearly reduces toward 1.5x
- Above 2.0x composite demand: SMB multiplier capped at 1.5x

This prevents 2.5x amount × 3.0x rate scenarios.

**Review finding #3:** Need logging when the ceiling is hit to evaluate whether 2.5x is too aggressive.

**Fix applied:** Added `debug(.apsManager, ...)` logging for both the composite ceiling hit (with demand/scaling/composite values) and the SMB rate reduction (with before/after multiplier values). This enables post-hoc analysis of whether the ceiling is constraining legitimate needs.

**Files:** `MacroAdaptiveService.swift`

---

### S3. Fat Coefficient Slider Capped to Match Learning Clamp [IMPLEMENTED]

**Priority: MEDIUM**
**Risk: User accidentally sets fat coefficient to 2.0, generating 80g carb-equivalent for 40g fat**

**Implementation:** Fat slider upper bound changed from `0.30 ... 2.00` to `0.30 ... 1.20` to match the learning clamp in `V2CurveOutcomeLearning.swift`.

**File:** `V2MacroDosingSettingsView.swift`

---

### S4. Validate proteinPlateau > proteinThreshold [IMPLEMENTED]

**Priority: MEDIUM**
**Risk: Setting threshold=30 and plateau=20 breaks the smooth protein ramp**

**Implementation:** Added `onChange` handlers that push plateau ahead if threshold approaches it, and push threshold back if plateau drops toward it.

**Review finding:** Two `onChange` handlers modifying each other's values can create a ping-pong loop.

**Fix applied:** Added `@State private var isAdjustingProteinConstraints = false` re-entrancy guard. Each handler checks this flag and returns early if it's already being adjusted:

```swift
guard !isAdjustingProteinConstraints else { return }
isAdjustingProteinConstraints = true
defer { isAdjustingProteinConstraints = false }
```

**File:** `V2MacroDosingSettingsView.swift`

---

### S5. Auto-Degradation on Repeated Composite Ceiling Hits [IMPLEMENTED]

**Priority: HIGH**
**Risk: Engine can get stuck at the ceiling with no automatic recovery**

**Problem:**
If the BG-adaptive loop is consistently pushing demand upward (e.g., due to a slow-absorbing meal causing repeated positive BG errors), the cumulative scaling will hit the composite ceiling every cycle. The engine is capped at the ceiling, but it's still running at maximum aggressiveness — if the ceiling turns out to be too high, the user is stuck at an elevated delivery rate with no automatic pullback.

**Implementation:**
When a meal hits the composite ceiling 3 consecutive times, `scaleFutureEntries()` automatically decays the cumulative scaling by 0.8x:

```swift
private static let ceilingHitDegradationThreshold = 3
private static let degradationDecayFactor = 0.8

// In scaleFutureEntries, after detecting ceiling hit:
if hitCount >= Self.ceilingHitDegradationThreshold {
    let degradedCumulative = cappedCumulative * Self.degradationDecayFactor
    newCumulative = max(Self.minCumulativeScaling, degradedCumulative)
    ceilingHitCounts[mealID] = 0  // reset counter after degradation
}
```

This means:
- Cycle 1-2: ceiling hit, counter increments, scaling stays at ceiling
- Cycle 3: ceiling hit again, auto-degrade fires, scaling drops to 80% of ceiling
- If ceiling is hit 3 more times: scaling drops to 64% of ceiling, etc.
- If a cycle does NOT hit the ceiling: counter resets, no degradation

This provides automatic self-correction without user intervention and pairs with the ceiling hit logging (S2) for post-hoc analysis.

**File:** `MacroAdaptiveService.swift`

---

## Part 2: Logic Corrections

### L1. Fix Absorbed Carbs Timing with Dynamic Absorption Buffer [IMPLEMENTED]

**Priority: MEDIUM**

**Problem:** `fetchAbsorbedAndRemainingCarbs()` classified entries as "absorbed" if `entryDate <= now`. An entry 30 seconds old may not have driven any SMB yet, inflating `absorbedCarbs`.

**Initial implementation:** Hardcoded 5-minute buffer.

**Review finding:** If the loop is delayed (phone backgrounded, Bluetooth reconnection), 5 minutes could be wrong. The buffer should adapt to actual loop timing.

**Final implementation:** Dynamic buffer using `max(5min, timeSinceLastLoop)`:
```swift
let timeSinceLastLoop = lastLoopDate.map { Date().timeIntervalSince($0) } ?? Self.minAbsorptionBuffer
let absorptionBuffer = max(Self.minAbsorptionBuffer, timeSinceLastLoop)
```

`APSManager` passes `lastLoopDate` to `runAdaptiveCycle()`, which threads it to both `fetchAbsorbedAndRemainingCarbs()` call sites. External callers (like APSManager's proportional attribution) default to the 5-minute minimum.

**Files:** `MacroAdaptiveService.swift`, `APSManager.swift`

---

### L2. Thread-Safety for Gate 3 Hysteresis [IMPLEMENTED]

**Priority: LOW**

**Implementation:** Added `NSLock` for `gate3FailedLastCycle` static flag.

**File:** `MacroAdaptiveService.swift`

---

### L4. Comprehensive Thread Safety for MacroAdaptiveService [IMPLEMENTED]

**Priority: HIGH**
**Risk: Data races between loop timer and bolus delivery paths**

**Problem:**
`MacroAdaptiveService` has multiple entry points that can execute concurrently:
- `runAdaptiveCycle()` is called from the loop timer every 5 minutes
- `recordMealInsulin()` is called from bolus delivery (including SMB deliveries)
- `recordMealDemandFactor()` is called when a new meal is created
- `mealCompleted()` is called when a meal finishes absorbing

These all read/write shared mutable state (`cumulativeScaling`, `mealInsulinRecords`, `mealDemandFactors`, `lastAdjustmentTime`, `adjustmentHistory`, `ceilingHitCounts`). Without synchronization, concurrent access can corrupt state.

**Implementation:**
Single `NSLock` (`stateLock`) protecting all mutable instance state. Every read or write of shared state acquires the lock:

```swift
private let stateLock = NSLock()
```

Protected operations:
- `recordMealInsulin()` — full method under lock (was already done)
- `getMealAttributedIOB()` — snapshot records under lock, compute outside
- `getTotalMealInsulin()` — snapshot records under lock
- `recordMealDemandFactor()` — write + persist under lock
- `getMealDemandFactor()` — read under lock
- `runAdaptiveCycle()` composite demand loop — read demand factors + cumulative scaling under lock
- `runAdaptiveCycle()` damping check — read `lastAdjustmentTime` under lock
- `runAdaptiveCycle()` adjustment recording — read `cumulativeScaling` + append `adjustmentHistory` under lock
- `scaleFutureEntries()` — all cumulative scaling reads/writes, ceiling hit tracking, persist under lock
- `mealCompleted()` — all state cleanup under lock

Lock granularity is kept fine: acquire for state access, release before I/O (Core Data fetches, context.perform). This avoids holding the lock across async operations.

**File:** `MacroAdaptiveService.swift`

---

### L3. Proportional SMB Attribution [IMPLEMENTED]

**Priority: MEDIUM**

**Problem:** `performBolus()` split SMB insulin equally across active meals regardless of remaining carbs.

**Implementation:** Split proportionally by remaining carbs. Made `fetchAbsorbedAndRemainingCarbs` `internal` for `APSManager` access.

**File:** `APSManager.swift`, `MacroAdaptiveService.swift`

---

## Part 3: UX/UI Redesign — Treatment Flow

### T1. V1/V2 Mode Toggle [IMPLEMENTED]

Segmented control at top of treatment page. Default from `useV2MacroAbsorption` setting. Per-session override only.

**File:** `TreatmentsRootView.swift`

---

### T2. Removed MacroDecayChartView [IMPLEMENTED]

Removed the COB/POB/FOB stacked area chart from the treatment page. Kept the file for potential analysis page use.

**File:** `TreatmentsRootView.swift`

---

### T3. V2 Meal Feed — Per-Meal Independent Processing [IMPLEMENTED]

**What:** Meal feed showing recent nutrition events from HealthKit observer with multi-select.

**Review finding:** The original plan summed macros from multiple selected meals and used the latest timestamp, discarding temporal information. A granola bar from 20 minutes ago + a current meal would generate entries as if none of the earlier carbs had been absorbed.

**Fix applied:** Each selected meal is now tracked independently with its own timestamp. When the user selects multiple meals:

1. Each meal's `V2DetectedMeal` object (with original timestamp) is passed through to the dose preview
2. `prepareV2IndependentMealEntries()` calls `MacroAbsorptionEngine.generateEntries()` per meal with its own `mealTime`
3. The gamma CDF at each meal's elapsed time correctly accounts for already-absorbed carbs
4. Each meal gets its own `mealID` so the adaptive service tracks them independently

The combined macro totals are still shown for display, but the engine processes meals with full temporal information.

**Files:** `V2TreatmentView.swift`, `V2MealCardView.swift`, `V2ManualMealEntryView.swift`, `V2DetectedMeal.swift`, `TreatmentsStateModel.swift`

---

### T4. V2 Dose Preview with V2-Aware Forecast Chart [IMPLEMENTED]

**What:** Dose preview with two-line BG forecast, treatment plan, adjustment sliders, confirm flow.

**Review finding:** `simulateDetermineBasal()` takes a single `simulatedCarbsAmount` scalar. V2's value is distributing entries across hours. A single carb amount simulates a bolus-wizard spike, not V2's gradual coverage.

**Fix applied:** Built a lightweight Swift-side V2-aware prediction that uses the entry schedule directly.

**Second review finding:** The original implementation used oref's IOB prediction for the "no treatment" line and the lightweight model for "with treatment". Different models have different error characteristics, so the gap between lines would include model divergence, not just treatment effect. Users would misinterpret the visual.

**Final implementation:** Both forecast lines use the same `predict()` function with different parameters:
- "No treatment": `predict(bolusUnits: 0, meals: [], ...)` — only existing IOB decay
- "With treatment": `predict(bolusUnits: proposed, meals: selectedMeals, ...)` — full V2 prediction

```swift
private func predict(bolusUnits: Double, meals: [V2DetectedMeal], demandFactor: Double, tau: Double)
    -> [(date: Date, value: Double)]
```

The shared model uses ISF/CR-based BG prediction with per-meal gamma CDF contributions. Because both lines use identical math, the gap is purely the treatment effect — zero model divergence.

**Files:** `V2ForecastChart.swift`, `V2DosePreviewView.swift`, `TreatmentsStateModel.swift`

---

### T5. Edge Cases — Late Meals, Multi-Meal [IMPLEMENTED]

- Late meal banner (>1h old) with elapsed time warning
- Per-meal gamma CDF ensures already-absorbed carbs aren't double-counted
- Already-dosed meal indicators with re-dose warning
- Correction-only shortcut bypasses meal selection

**Files:** `V2DosePreviewView.swift`, `V2TreatmentView.swift`

---

### T6. Cronometer Integration

Cronometer shortcut kept in V2 meal feed. The full `CronometerMealRecommendationView` sheet remains functional for V1 mode. In V2 mode, the meal feed replaces the picker/recommendation flow.

**Files:** `V2TreatmentView.swift`

---

## Part 4: UX/UI Redesign — Settings Consolidation

### U1. V2 Hub Settings Page [IMPLEMENTED]

Tabbed hub with Nutrition / Engine / Garmin / Analysis tabs replacing the single `V2MacroDosingSettingsView` navigation target.

**Files:** `V2MacroHubView.swift`, `V2NutritionSettingsView.swift`, `V2GarminSettingsView.swift`, `V2AnalysisHubView.swift`, `Screen.swift`

---

## Part 5: Implementation Status

### Completed (All items implemented and committed)

| # | Item | Type | Status |
|---|------|------|--------|
| S1 | IOB decay with oref-matching curves (bilinear + exponential) | Safety | Done |
| S2 | Composite demand ceiling (hardcoded 2.5x, not configurable) | Safety | Done |
| S2b | SMB rate reduction when composite demand > 1.5x | Safety | Done |
| S3 | Fat slider cap 2.00 -> 1.20 | Safety | Done |
| S4 | Protein plateau/threshold validation with re-entrancy guard | Safety | Done |
| S5 | Auto-degradation on repeated composite ceiling hits | Safety | Done |
| L1 | Absorbed carbs 5-minute timing buffer | Logic | Done |
| L2 | Gate 3 NSLock thread safety | Logic | Done |
| L4 | Comprehensive thread safety for MacroAdaptiveService shared state | Logic | Done |
| L3 | Proportional SMB attribution by remaining carbs | Logic | Done |
| T1 | V1/V2 segmented toggle on treatment page | UX | Done |
| T2 | MacroDecayChartView removed from treatment screen | UX | Done |
| T3 | V2 meal feed with per-meal independent entry generation | UX | Done |
| T4 | V2 dose preview with V2-aware lightweight forecast chart | UX | Done |
| T5 | Late meal handling, multi-meal, correction-only | UX | Done |
| T6 | Cronometer shortcut preserved in V2 feed | UX | Done |
| U1 | V2 Hub settings page (4 tabs) | UX | Done |

### Post-Review Fixes (from external safety reviews)

| Finding | Fix | Impact |
|---------|-----|--------|
| S1 linear decay diverges from oref | Ported bilinear + exponential curves from trio-oref | Eliminates IOB tracking mismatch |
| Multi-meal sum discards temporal info | Per-meal independent generateEntries with own timestamp | Prevents over-delivery for old meals |
| Configurable safety ceiling | Hardcoded at 2.5x, removed parameter | Prevents users widening safety boundary |
| SMB rate not in composite cap | Rate reduction when composite > 1.5x | Prevents high amount × high rate |
| No ceiling-hit visibility | Added debug logging for ceiling hits + rate reductions | Enables post-hoc analysis |
| Dual simulation can't model V2 entries | Lightweight V2-aware prediction using entry schedule | Accurate forecast for distributed dosing |
| Forecast model divergence between lines | Same predict() function for both lines | Gap = pure treatment effect |
| L1 hardcoded 5min buffer | Dynamic max(5min, timeSinceLastLoop) from APSManager | Adapts to delayed loop cycles |
| S4 slider ping-pong | Re-entrancy guard on onChange handlers | Prevents infinite loop |
| No automatic fallback on repeated ceiling | Auto-degradation: 3 consecutive ceiling hits decays cumulativeScaling by 0.8x | Self-correcting without user intervention |
| Shared mutable state unprotected | NSLock wrapping all mutable state in MacroAdaptiveService | Prevents data races from concurrent loop/bolus paths |

### Not Implemented (Accepted or Low Priority)

| # | Item | Reason |
|---|------|--------|
| — | Time-weighted Gate 5 | Current behavior errs toward safety (over-restrictive) |
| — | Move insulin records from UserDefaults to Core Data | Works for current volume; not transactional but data is a tracking heuristic, not delivery record. Composite ceiling limits worst case on corruption. |
| — | Persistence: move all state to Core Data | UserDefaults is adequate for the handful of lightweight dictionaries. Composite ceiling + auto-degradation limit worst case on corruption. |

---

### File Summary

**Modified files (6):**
- `MacroAdaptiveService.swift` — IOB curves, composite ceiling, rate limiting, dynamic absorption buffer, ceiling logging, auto-degradation, comprehensive thread safety (NSLock)
- `APSManager.swift` — Curve type selection, DIA/lastLoopDate passing, proportional SMB attribution
- `V2MacroDosingSettingsView.swift` — Fat slider cap, protein validation with re-entrancy guard
- `TreatmentsRootView.swift` — V1/V2 toggle, MacroDecayChart removal
- `TreatmentsStateModel.swift` — V2 meal feed, per-meal entries, V2 chart data
- `Screen.swift` — V2 Hub routing

**New files (10):**
- `V2DetectedMeal.swift` — Meal feed model
- `V2TreatmentView.swift` — V2 flow container with per-meal independent processing
- `V2MealCardView.swift` — Meal card component
- `V2DosePreviewView.swift` — Dose preview with per-meal upfront calculation
- `V2ForecastChart.swift` — Two-line BG forecast with shared prediction model
- `V2ManualMealEntryView.swift` — Manual entry form
- `V2MacroHubView.swift` — Settings hub (4 tabs)
- `V2NutritionSettingsView.swift` — Nutrition settings tab
- `V2GarminSettingsView.swift` — Garmin settings tab
- `V2AnalysisHubView.swift` — Analysis hub tab

---

*This document describes improvements to the V2 Macro Absorption Engine in the Trio open-source automated insulin delivery system. The system is for research and personal use. It is not FDA-approved and should not be used as the sole basis for insulin dosing decisions without clinical oversight.*
