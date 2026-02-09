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

## Part 2: Logic Corrections

### L1. Fix Absorbed Carbs Timing with Absorption Buffer [IMPLEMENTED]

**Priority: MEDIUM**

**Problem:** `fetchAbsorbedAndRemainingCarbs()` classified entries as "absorbed" if `entryDate <= now`. An entry 30 seconds old may not have driven any SMB yet, inflating `absorbedCarbs`.

**Implementation:** Added a 5-minute buffer (`absorptionBuffer = 5 * 60`):
```swift
let effectiveNow = now.addingTimeInterval(-MacroAdaptiveService.absorptionBuffer)
```

Entries are only counted as "absorbed" after oref has had at least one cycle to act on them.

**File:** `MacroAdaptiveService.swift`

---

### L2. Thread-Safety for Gate 3 Hysteresis [IMPLEMENTED]

**Priority: LOW**

**Implementation:** Added `NSLock` for `gate3FailedLastCycle` static flag.

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

**Fix applied:** Built a lightweight Swift-side V2-aware prediction for the "with treatment" line that uses the entry schedule directly:

```swift
// For each 5-min step, sum gamma CDF contributions from each meal at its own timestamp
for meal in selectedMeals {
    let totalMinutes = mealMinutesAgo + minutesAhead
    let absorbed = MacroAbsorptionEngine.gammaCDFValue(tau: tau, atMinutes: totalMinutes)
    carbBGDelta += (totalCarbs * absorbed / cr) * isf
}
```

This models the gradual SMB-driven coverage that V2 actually delivers, rather than the bolus-like spike oref would predict from a single carb scalar. The "no treatment" line still uses oref's IOB-only prediction.

Falls back to oref simulation data if ISF/CR aren't available.

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
| L1 | Absorbed carbs 5-minute timing buffer | Logic | Done |
| L2 | Gate 3 NSLock thread safety | Logic | Done |
| L3 | Proportional SMB attribution by remaining carbs | Logic | Done |
| T1 | V1/V2 segmented toggle on treatment page | UX | Done |
| T2 | MacroDecayChartView removed from treatment screen | UX | Done |
| T3 | V2 meal feed with per-meal independent entry generation | UX | Done |
| T4 | V2 dose preview with V2-aware lightweight forecast chart | UX | Done |
| T5 | Late meal handling, multi-meal, correction-only | UX | Done |
| T6 | Cronometer shortcut preserved in V2 feed | UX | Done |
| U1 | V2 Hub settings page (4 tabs) | UX | Done |

### Post-Review Fixes (from external safety review)

| Finding | Fix | Impact |
|---------|-----|--------|
| S1 linear decay diverges from oref | Ported bilinear + exponential curves from trio-oref | Eliminates IOB tracking mismatch |
| Multi-meal sum discards temporal info | Per-meal independent generateEntries with own timestamp | Prevents over-delivery for old meals |
| Configurable safety ceiling | Hardcoded at 2.5x, removed parameter | Prevents users widening safety boundary |
| SMB rate not in composite cap | Rate reduction when composite > 1.5x | Prevents high amount × high rate |
| Dual simulation can't model V2 entries | Lightweight V2-aware prediction using entry schedule | Accurate forecast for distributed dosing |
| S4 slider ping-pong | Re-entrancy guard on onChange handlers | Prevents infinite loop |

### Not Implemented (Accepted or Low Priority)

| # | Item | Reason |
|---|------|--------|
| S5 | Time-weighted Gate 5 | Current behavior errs toward safety (over-restrictive) |
| L1 note | Derive buffer from actual loop timestamp | 5-minute buffer is robust for standard CGM timing |
| Persistence | Move insulin records from UserDefaults to Core Data | Works fine for current data volume, can revisit |

---

### File Summary

**Modified files (8):**
- `MacroAdaptiveService.swift` — IOB curves, composite ceiling, rate limiting, absorption buffer, thread safety
- `APSManager.swift` — Curve type selection, DIA passing, proportional SMB attribution
- `V2MacroDosingSettingsView.swift` — Fat slider cap, protein validation with re-entrancy guard
- `TreatmentsRootView.swift` — V1/V2 toggle, MacroDecayChart removal
- `TreatmentsStateModel.swift` — V2 meal feed, per-meal entries, V2 chart data
- `V2TreatmentView.swift` — Per-meal independent processing, selected meals passthrough
- `V2DosePreviewView.swift` — Per-meal upfront calculation, late meal handling
- `V2ForecastChart.swift` — V2-aware lightweight BG prediction
- `Screen.swift` — V2 Hub routing

**New files (7):**
- `V2DetectedMeal.swift` — Meal feed model
- `V2TreatmentView.swift` — V2 flow container
- `V2MealCardView.swift` — Meal card component
- `V2DosePreviewView.swift` — Dose preview + adjustments
- `V2ForecastChart.swift` — Two-line BG forecast
- `V2ManualMealEntryView.swift` — Manual entry form
- `V2MacroHubView.swift` — Settings hub
- `V2NutritionSettingsView.swift` — Nutrition settings tab
- `V2GarminSettingsView.swift` — Garmin settings tab
- `V2AnalysisHubView.swift` — Analysis hub tab

---

*This document describes improvements to the V2 Macro Absorption Engine in the Trio open-source automated insulin delivery system. The system is for research and personal use. It is not FDA-approved and should not be used as the sole basis for insulin dosing decisions without clinical oversight.*
