# V3 Changes Made — February 2026

This document records the changes made to the V3 Three-Curve Macro Absorption Engine and related systems, along with the reasoning behind each change.

---

## 1. Composition-Aware Upfront Dosing Algorithm

**File:** `MacroAbsorptionEngine.swift`

**Problem:** The old `fatScaledMinUpfront()` function only considered absolute fat grams to determine how much insulin to deliver upfront. This under-dosed carb-dominant meals — a 100g carb / 5g fat rice bowl got only ~75% upfront, when it should behave almost identically to a standard oref bolus. The system was designed to handle late fat/protein effects for complex meals, but it was also suppressing insulin for simple carb meals.

**Change:** Replaced `fatScaledMinUpfront()` with `compositionAwareMinUpfront()` that analyzes the full macro mix:

```
carbRatio = carbs / (carbs + fat + protein)
compositionBase = 0.50 + carbRatio × 0.45    // 50% at pure fat/protein, 95% at pure carbs
fiberReduction = min(0.08, max(0, fiber - 5) × 0.005)
fatDelay = min(0.15, fat / 50 × 0.15)
effectiveFloor = max(0.50, compositionBase - fiberReduction - fatDelay)
```

**Key outcomes:**

| Meal Type | C/F/P | Old Upfront | New Upfront |
|-----------|-------|-------------|-------------|
| Rice bowl | 80/3/5 | ~75% | ~90% |
| Juice | 30/0/0 | 80% | ~95% |
| Sandwich | 40/12/20 | ~67% | ~70% |
| Pizza | 65/30/25 | ~50% | ~58% |
| Cheese steak | 40/50/35 | ~35% | ~50% |

**Reasoning:** The whole point of split dosing is to cover late fat and protein effects for complex meals. High-carb meals should function almost identically to normal oref. The 50% absolute floor ensures we never under-dose, while the composition ratio drives the recommendation upward for carb-dominant meals.

---

## 2. Future Entry Consolidation (15-Minute Buckets)

**File:** `MacroAbsorptionEngine.swift`

**Problem:** A typical HFHP dinner generated 60-77 future entries:
- Carb curve: every 10 minutes → ~23 entries
- Protein curve: every 15 minutes → ~26 entries
- Fat curve: every 15 minutes → ~28 entries

This was excessive and cluttered the oref input.

**Change:**
1. Changed carb curve interval from 10 to 15 minutes
2. Added `consolidateEntries()` function that merges all three curve outputs into unified 15-minute time buckets
3. Entries at the same time point from different curves are summed into a single entry
4. The `note` field combines source types (e.g., "carb-absorption+protein-gluconeogenesis")

**Result:** A typical HFHP dinner now produces ~28-30 entries instead of 60-77. Total carb-equivalent amounts are identical — only the granularity changes. oref still sees the same total demand at each time window.

---

## 3. Garmin Sensitivity Model — Scaled Down and Capped at ±30%

**File:** `GarminSensitivityModel.swift`

**Problem:** The Garmin demand factor had an asymmetric range of 0.71x to 1.67x, meaning it could increase insulin by up to 67% on a bad day. Individual impact magnitudes were large enough that a single bad night of sleep (-0.22 + -0.10 = -0.32) would max out the entire range, making all other signals irrelevant.

**Change (Option B):**
1. **Scaled all individual impacts down ~50%** so multiple signals contribute meaningfully before hitting the cap
2. **Clamped the demand factor directly** to [0.70, 1.30] for a symmetric ±30% range

**Impact comparison (worst case):**

| Metric | Old Impact | New Impact |
|--------|-----------|------------|
| Terrible sleep score | -0.22 | -0.11 |
| <5h sleep duration | -0.10 | -0.05 |
| Critical body battery | -0.18 | -0.09 |
| High acute stress | -0.08 | -0.04 |
| Sustained high stress | -0.06 | -0.03 |
| Elevated RHR (>12 bpm) | -0.12 | -0.06 |
| HRV >20% below baseline | -0.08 | -0.04 |
| **Worst case total** | **-0.84** | **-0.42** |

**Old range:** 0.71x to 1.67x (asymmetric due to 1/x inversion)
**New range:** 0.70x to 1.30x (symmetric, clamped directly on demand factor)

**Reasoning:** The Garmin model uses heuristic weights, not regression-derived values. Limiting to ±30% gives the system enough range to meaningfully adjust for lifestyle factors while preventing runaway insulin delivery on a bad day. The scaled-down individual impacts ensure that on a truly terrible day (bad sleep + high stress + depleted), multiple factors contribute to the final number rather than one metric bottoming it out.

---

## 4. Treatment Plan Display — Matched Values and Correction Breakdown

**File:** `V2DosePreviewView.swift`

**Problem:** The Treatment Plan section displayed `upfrontUnits` (pure carb coverage) while "Use Recommended" set `state.insulinCalculated` (which includes BG correction and IOB). These were different numbers, creating confusion about what the system was recommending.

**Change:**
1. Treatment Plan now shows "Recommended bolus" as the top-line number (matches what "Use Rec." sets)
2. Below it, shows the breakdown: carb coverage and BG correction/IOB as separate line items
3. Correction amount is color-coded: orange for positive (needs correction up), green for negative (IOB reducing dose)

---

## 5. Editable Insulin Delivery Field

**File:** `V2DosePreviewView.swift`

**Problem:** The bolus amount was a read-only `Text` view. Users could not type a custom amount. The only way to change it was "Use Rec." or indirectly via sliders. After pressing "Use Rec.", the button disabled (amount == recommended), and the user couldn't adjust further without the slider.

**Change:**
1. Replaced `Text` with an editable `TextField` bound to `state.amount`
2. "Use Rec." button now always enabled (unless calculated is 0) — acts as a "reset to recommended" action
3. When sliders change, `recalculate()` updates both the calculated value and the text field
4. User can type any custom insulin amount directly

---

## 6. Meal Outcome Recording Fix (V2 Macros Tab)

**File:** `TreatmentsStateModel.swift`

**Problem:** V2MealOutcome records were only created in `applyCronometerRecommendation()` (the Cronometer sheet path). When dosing via the V2 Macros tab (V2TreatmentView → V2DosePreviewView → invokeTreatmentsTask), `v2PendingOutcome` was nil, so no outcome was ever saved. This caused the meal analysis to show 0 meals despite multiple doses.

**Change:** Added outcome creation in `invokeTreatmentsTask()` when V2 macros are active and no pending outcome exists. The new code reads the current meal macros, curve parameters, BG, and carb ratio from state and creates a V2MealOutcome with the correct values. This ensures every V2 dose — whether from the Cronometer path or the V2 Macros tab — records an outcome for tracking and learning.

---

## 7. Cronometer Page Removal

**File:** `TreatmentsRootView.swift`

**Problem:** The "Log" and "Crono" buttons in the V1 treatment view launched the Cronometer-specific workflow (fetch meal from Apple Health, show recommendation sheet with adjustment factor and auto-learning). This was redundant with the V2 Macros tab which provides a better workflow: direct meal detection from HealthKit, multi-meal selection, per-meal temporal independence, and integrated dose preview.

**Change:**
1. Removed the "Log" button (opened Cronometer app with baseline recording)
2. Removed the "Crono" button (fetched Cronometer meal and showed recommendation sheet)
3. Removed the `CronometerMealRecommendationView` sheet presentation
4. Removed the `CronometerMealPickerView` sheet presentation
5. Removed the Cronometer error alert
6. V1 Standard mode retained as fallback for simple carb-only boluses without macro tracking

**The adjustment factor and auto-learning system** (`CronometerRecommendationStore`) is no longer invoked from any UI path. The V2 outcome learning system (`V2OutcomeLearningStore`) handles parameter tuning for the three-curve engine independently.

---

## 8. Demand Override Slider Range Updated

**File:** `V2DosePreviewView.swift`

**Minor change:** Updated the demand override slider range from [0.6, 1.7] to [0.7, 1.3] with 0.05 step size, matching the new ±30% Garmin cap. Default upfront percent initialization changed from 0.20 to 0.50 to match the new composition-aware floor.

---

## 9. V2 Meal Detection — Midnight Baseline Fix

**File:** `NutritionSnapshot.swift`

**Problem:** The V2 Macros tab couldn't detect any meals from Cronometer, even though the old Cronometer page (now removed) detected them fine. This was a pre-existing bug affecting both old and new code.

**Root cause:** `inferredMealEvents(for:)` required at least 2 snapshots to compute deltas (`guard snapshots.count >= 2 else { return [] }`). The V2 tab's detection flow:

1. `loadV2DetectedMeals()` calls `fetchLatestMealDelta()` → saves snapshot #1
2. Then calls `inferredMealEvents(forLastHours: 8)` → finds only 1 snapshot → returns `[]`

The Cronometer page's `recordAndComputeLatestMeal()` handled this differently — when only 1 snapshot exists, it uses a **midnight baseline of zeros** and computes the delta from that. So the Cronometer page worked, but the V2 tab (which uses `inferredMealEvents`) did not.

This breaks whenever the HealthKit background observer hasn't been firing (airplane mode, app wasn't backgrounded, first day of use, etc.), leaving no pre-meal baseline snapshot.

**Change:**
1. **Single-snapshot bootstrap:** When only 1 snapshot exists for a day, treat midnight (all zeros) as the baseline and return the cumulative values as a single meal event — matching `recordAndComputeLatestMeal()`'s behavior
2. **First-snapshot baseline:** When 2+ snapshots exist but the first one already has non-zero cumulative values (observer fired late, after food was already logged), include a delta from midnight to the first snapshot so that food isn't silently lost

**Result:** V2 Macros tab now detects meals reliably regardless of whether background observer snapshots exist. The midnight baseline ensures the first meal of the day is always visible.
