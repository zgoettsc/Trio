# V2 Dosing Strategy — Changes Needed

**Date:** February 8, 2026
**Sources:** Internal code review + commissioned external critique
**Scope:** V2DosingStrategy.md, MacroAbsorptionEngine.swift, MacroAdaptiveService.swift, V2CurveOutcomeLearning.swift, GarminSensitivityModel.swift, V2MacroDosingSettingsView.swift

**Implementation status updated:** February 8, 2026

---

## Summary

The core three-curve model, split dosing logic, and curve math are solid. The issues live in the adaptive/learning layers, safety gates, and a few whitepaper-to-code mismatches. Below are the original 16 specific changes grouped by priority, plus additional items discovered during implementation.

**14 of 16 original items have been implemented.** Items #12 and #13 are deferred — see details below.

**Additional completed work:**
- **Export system** — comprehensive meal data export with pre/post-meal BG traces, scheduled entries, Garmin contributions, user settings, and dosing summary
- **mealID linkage fix** — resolved critical bug where scheduled entries were always empty in the export due to disconnected UUIDs between V2MealOutcome and Core Data fpuIDs
- **Export documentation** — see `docs/V2ExportSystem.md` for full details

**Remaining work:**
- **#12** — Claude AI recalibration spec (needs design decisions)
- **#13** — Core Data migration for outcome storage (architectural change)

---

## HIGH PRIORITY

### 1. BG-Adaptive Service Uses Total IOB Instead of Meal-Attributed IOB

**Status: IMPLEMENTED**

**File:** `Trio/Sources/Services/MacroAdaptiveService.swift`

**Problem:** `currentIOB` was total insulin on board from all sources — basal, corrections, prior meals, manual boluses. The formula compared a meal-specific carb absorption prediction against system-wide IOB. A large correction bolus from a prior high inflated `currentIOB`, making `predictedBGImpact` very negative, making `error` very positive, which scaled UP remaining entries even though the meal itself was absorbing correctly.

Additionally, oref was independently issuing correction SMBs for the same high BG. The adaptive service scaled up future entries to deliver more insulin, and oref issued corrections to deliver more insulin — double-correcting the same problem. The 50% damping and 0.5–1.5 cycle clamp reduced but did not eliminate this.

**What was done:**
- Added `mealAttributedIOB: [String: Double]` dictionary to track insulin per mealID
- Added `recordMealInsulin(mealID:units:)` to accumulate insulin attributed to a meal
- Added `getMealAttributedIOB(mealID:)` to retrieve the meal-specific total
- Changed the prediction formula from `currentIOB * isf` to `mealIOB * isf`
- Cleanup on `mealCompleted()` removes the meal's IOB entry

**Implementation decision:** Used a simple in-memory accumulator (`recordMealInsulin` adds, `getMealAttributedIOB` reads) rather than tagging insulin doses with mealID in Core Data. This is simpler but does not model IOB decay — the recorded value is total insulin attributed, not remaining active insulin. This is acceptable for the adaptive correction use case (which compares cumulative effects), but a future improvement could apply an exponential decay curve based on DIA to make the IOB estimate more accurate over time.

**Remaining work:**
- The call site that delivers boluses and SMBs must call `recordMealInsulin()` with the mealID and units delivered. This wiring depends on where in the oref integration the bolus/SMB decisions are made. The function exists and is ready to be called.
- Consider adding IOB decay modeling using the user's DIA setting for longer meals (6-8h) where the upfront bolus has substantially decayed by the time late entries are evaluated.

---

### 2. BG-Adaptive "Actual Trend" Extrapolation Is Inaccurate

**Status: IMPLEMENTED**

**File:** `Trio/Sources/Services/MacroAdaptiveService.swift`

**Problem:** The old code took the current 5-minute CGM trend and linearly extrapolated it across the entire duration since the first entry. A meal that spiked 60 mg/dL at hour 1 and was now flat would be treated identically to one that was flat for 3 hours and just started rising.

**What was done:**
- Added `mealStartBGs: [String: Double]` parameter to `runAdaptiveCycle()` (defaults to empty, backwards-compatible)
- Replaced `trend * (minutesSinceFirst / 5.0)` with `currentBG - mealStartBG`
- Falls back to `bg` (no delta) if `mealStartBGs` doesn't contain the mealID
- Removed `bgTrend` from the guard clause for adaptive adjustment (trend is still used by Gate 3 for meal-mode, but no longer for error calculation)
- `trendError` in `AdaptiveAdjustment` is now set to 0 (field retained for Codable compatibility)

**Implementation decision:** The `mealStartBGs` map is passed in from outside rather than looked up internally from V2MealOutcome. This keeps MacroAdaptiveService decoupled from the outcome storage layer. The caller can populate it from `V2MealOutcome.bgAtMeal` for each active meal.

**Remaining work:**
- The call site that invokes `runAdaptiveCycle()` must populate `mealStartBGs` from the active V2MealOutcome records. The `bgAtMeal` field already exists on every outcome.

---

### 3. Static Phase Attribution Ignores Actual Meal Composition

**Status: IMPLEMENTED**

**File:** `Trio/Sources/Services/V2CurveOutcomeLearning.swift`

**Problem:** Phase attribution was hardcoded regardless of what the person actually ate. A low-protein meal still attributed 3h errors to `proteinFactor`. A low-fat meal still attributed 6h/8h errors to the fat curve.

**What was done:**
- Added `V2BGCheckpoint.computePhases(carbs:fat:protein:proteinThreshold:)` static function
- Added `.skip` case to `CurvePhase` enum for checkpoints not relevant to the meal
- Checkpoints at 3h, 4h, 5h, 6h, 8h are now dynamically assigned based on whether protein > threshold and fat >= 5g
- `createOutcome()` now calls `computePhases()` instead of using hardcoded checkpoints
- The learning loop in `recalculateCurveParameters()` handles `.skip` by breaking (no adjustment)

**Implementation decision:** Kept the `.overlap` phase for meals with both protein and fat (at 4h), rather than dropping it entirely as the external critique suggested. Rationale: dropping overlap entirely would lose all signal from the 4h window, which for full-macro meals is actually the most information-dense checkpoint. The 30% reduced weight already limits its influence. If parameter convergence is noisy in practice, the overlap phase can be dropped later — but removing it now loses data we may want.

**Remaining work:** None for the code change. Monitor whether parameter convergence improves with dynamic attribution vs. the old static approach using the outcome analysis view.

---

### 4. Confounding Meal Detection Is Dead Code

**Status: IMPLEMENTED**

**File:** `Trio/Sources/Services/V2CurveOutcomeLearning.swift`

**Problem:** `hasConfoundingMeal` was hardcoded to `false` and never set to `true`. Meals followed by snacks within 8 hours corrupted the learning data.

**What was done:**
- Added `detectConfoundingMeals()` method to `V2OutcomeLearningStore`
- Uses the more nuanced per-checkpoint approach (external critique recommendation): individual checkpoints are marked `isClean = false` when a confounding meal's start time falls before that checkpoint's time
- Sets `hasConfoundingMeal = true` on the outcome when any overlap exists
- Called automatically at the end of `backfillOutcomes()` so detection runs whenever new BG data is filled in
- Correctly clears `hasConfoundingMeal` back to `false` if outcomes are deleted and no overlap remains

**Implementation decision:** Went with per-checkpoint dirty marking rather than binary whole-meal exclusion. This preserves early checkpoints (1h, 2h) that are clean even when a snack at 3h contaminates later checkpoints. Since the learning system already checks `cp.isClean` in its inner loop, dirty checkpoints are automatically excluded from parameter adjustments without losing the clean ones.

**Remaining work:** None. The detection is fully automated via the backfill hook.

---

### 5. Add IOB Safety Gate for SMB Enhancement

**Status: IMPLEMENTED**

**File:** `Trio/Sources/Services/MacroAdaptiveService.swift`

**Problem:** No check on whether IOB already exceeded predicted remaining absorption. Insulin stacking could cause hypoglycemia even when BG looked fine.

**What was done:**
- Added Gate 5 to `MealModeState.evaluate()` after Gate 4
- Added `currentIOB`, `remainingCarbsForActiveMeals`, and `carbRatio` parameters to `evaluate()`
- Gate logic: `remainingInsulinNeed = remainingCarbs / carbRatio`; fails if `currentIOB > remainingInsulinNeed * 1.2`
- `runAdaptiveCycle()` now computes `totalRemainingCarbs` across all active meals before calling `evaluate()`
- Gate is guarded by `carbRatio > 0` and `remainingCarbs > 0` to avoid division issues

**Implementation decision:** Used the 20% buffer (1.2x) as specified in the changes doc. The gate is evaluated using total remaining carbs across all active meals and total system IOB. This is a conservative choice — it could over-restrict when multiple meals are active and IOB is split across them. A per-meal IOB gate would be more precise but requires the meal-attributed IOB tracking from #1 to be fully wired. The current approach errs on the side of safety.

**Remaining work:** None for the gate itself. Once meal-attributed IOB (#1) is fully wired at the call site, consider switching Gate 5 to use per-meal IOB instead of total system IOB for higher precision.

---

## MEDIUM PRIORITY

### 6. Fat Coefficient Should Be Nonlinear

**Status: IMPLEMENTED**

**File:** `Trio/Sources/Models/MacroAbsorptionEngine.swift`

**Problem:** A single linear coefficient (0.69) overcharged moderate-fat meals and may have undercharged extreme-fat meals. Bell (2020) showed the dose-response is nonlinear.

**What was done:**
- Added `fatCarbEquivalent(fatGrams:maxCoeff:threshold:plateau:)` static function
- Saturating ramp: 0.05 coefficient at ≤10g fat, linear ramp to `maxCoeff` at ≥50g fat
- Called from `generateEntries()` instead of the old `fat * params.effectiveFatTotalCoeff`
- Updated the example calculation in `V2MacroDosingSettingsView` to use `fatCarbEquivalent()`

**Implementation decision:** Used the exact ramp specified in the changes doc. The threshold (10g) and plateau (50g) are hardcoded rather than user-configurable, since they represent physiological breakpoints, not personal preferences. The `maxCoeff` parameter is still tunable via the fat coefficient slider and outcome learning. Monotonicity is verified by unit test.

**Remaining work:** None. The fat coefficient slider now controls the peak of the ramp rather than a linear multiplier. The settings UI label ("g-equiv/g") is technically less accurate now since the coefficient is nonlinear, but changing it to something like "max coefficient" adds complexity for marginal clarity.

---

### 7. Gate 3 Trend Threshold: Code Does Not Match Whitepaper

**Status: IMPLEMENTED**

**File:** `Trio/Sources/Services/MacroAdaptiveService.swift`

**Problem:** Code threshold was `-1.0 mg/dL/5min` (5x more restrictive than documented `-5.0`) and had no hysteresis. CGM noise near the threshold caused rapid toggling.

**What was done:**
- Changed threshold from `-1.0` to `-3.0` (compromise between old `-1.0` and documented `-5.0`)
- Added `gate3FailedLastCycle` static flag for hysteresis
- Once the gate fails (trend < -3.0), it requires trend to recover to ≥ 0.0 before re-enabling
- Added `resetHysteresis()` static function for testing

**Implementation decision:** Used `-3.0` as the threshold rather than the whitepaper's `-5.0`. Rationale: `-5.0` is quite permissive — a -5.0 mg/dL/5min trend means BG is dropping 60 mg/dL/hour, which is a significant fall. `-3.0` allows normal post-meal dips (which are often -1 to -2) while still catching real drops. The whitepaper should be updated to document `-3.0` as the actual threshold.

**Remaining work:** Update V2DosingStrategy.md Section 9 to document the `-3.0` threshold with hysteresis instead of the original `-5.0`. The code is correct; the whitepaper is now the stale artifact.

---

### 8. Garmin Sensitivity Weights Need Epistemic Disclaimer

**Status: IMPLEMENTED**

**Files:** `Trio/Sources/Models/GarminSensitivityModel.swift`, `docs/V2DosingStrategy.md`

**What was done:**
- Added a 6-line comment block at the top of `GarminSensitivityModel.swift` noting weights are heuristics, not regression-derived
- Added an "Epistemic Note" blockquote in V2DosingStrategy.md Section 8 (The Demand Factor Model) explicitly stating the weights are estimated, unvalidated for additive stacking, and subject to outcome learning validation

**Remaining work:** None.

---

### 9. Cumulative Scaling State Lost on App Restart

**Status: IMPLEMENTED**

**File:** `Trio/Sources/Services/MacroAdaptiveService.swift`

**Problem:** `cumulativeScaling` was an instance variable, lost on app restart. A meal already scaled up 80% could be scaled up another 100% after restart, defeating the safety clamp.

**What was done:**
- Added `init()` that restores `cumulativeScaling` from `UserDefaults` key `"V2CumulativeScaling"`
- Added `persistCumulativeScaling()` called after every scaling update and after `mealCompleted()` cleanup
- Uses JSON encoding of `[String: Double]` dictionary

**Implementation decision:** Used option (b) from the changes doc — a separate UserDefaults key — rather than option (a) (storing in V2MealOutcome). Rationale: the cumulative scaling map is service state, not outcome data. Storing it in V2MealOutcome would require loading/decoding all outcomes just to read the scaling state on service init, which is exactly the performance concern raised in #13. A small, separate key is fast to read and doesn't couple the adaptive service to the outcome store.

**Remaining work:** None. Could be migrated alongside #13 if/when V2MealOutcome moves to Core Data, but there's no functional need.

---

## LOW PRIORITY

### 10. Protein Factor Range Inconsistency

**Status: IMPLEMENTED**

**File:** `Trio/Sources/Services/V2CurveOutcomeLearning.swift`

**What was done:**
- Changed the learning system clamp from `min(0.60, ...)` to `min(0.80, ...)` to match the slider range
- Followed recommendation (a): the slider range (0.10–0.80) is the user-facing contract

**Remaining work:** Update V2DosingStrategy.md Section 11 clamping table to show 0.10–0.80 instead of 0.10–0.60.

---

### 11. Missing 5-Hour Checkpoint

**Status: IMPLEMENTED**

**File:** `Trio/Sources/Services/V2CurveOutcomeLearning.swift`

**What was done:**
- Added a 5h checkpoint to `V2BGCheckpoint.computePhases()` — tagged `.protein` when protein > threshold, `.fat` when only fat is present, `.skip` otherwise
- Total checkpoints per meal increased from 6 to 7: 1h, 2h, 3h, 4h, 5h, 6h, 8h
- Backfill automatically fills the 5h checkpoint from CGM data

**Remaining work:** None.

---

### 12. Claude AI Recalibration Is Underspecified

**Status: NOT IMPLEMENTED**

**File:** `docs/V2DosingStrategy.md`, Section 11

**Problem:** The whitepaper devotes 3 sentences to the Claude integration. It doesn't describe the prompt structure, expected JSON schema, validation pipeline, parameter clamping on Claude output, user confirmation flow, or error handling.

**Why deferred:** This is a documentation expansion task that requires design decisions about the Claude integration itself — prompt engineering, JSON schema definition, safety guardrails, UX flow for user confirmation. These decisions should be made alongside the actual Claude recalibration service implementation (in `ClaudeRecalibrationService` or equivalent), not in isolation. Writing a spec for a service that doesn't have a finalized design yet risks creating a spec that doesn't match reality.

**What needs to happen:**
1. Design the Claude recalibration prompt and expected response JSON schema
2. Define the validation pipeline: schema check → parameter range clamping → sanity check (no parameter changes > X% in one cycle)
3. Define the user confirmation UX: show the recommendation, explain what changed and why, require explicit approval before applying
4. Define error handling: malformed JSON, parameters outside ranges, API failures, rate limiting
5. Document all of the above in V2DosingStrategy.md Section 11
6. Implementation should follow the spec, not precede it

---

### 13. UserDefaults for Outcome Storage

**Status: NOT IMPLEMENTED**

**File:** `Trio/Sources/Services/V2CurveOutcomeLearning.swift`

**Problem:** All outcomes are serialized as a single JSON blob in UserDefaults. Over 90 days at 3 meals/day, that's ~270 records fully deserialized on every `loadAll()` call.

**Why deferred:** This is a significant architectural migration. The app uses Core Data extensively, and V2MealOutcome maps naturally to a Core Data entity with relationships to checkpoints and adaptive adjustments. However:
- Core Data schema changes require migration support (lightweight or custom) for existing users
- The V2MealOutcome struct has nested arrays (checkpoints, adaptive adjustments) that need to become Core Data relationships
- All callers of `loadAll()`, `save()`, `update()`, and `persistOutcomes()` need to be rewritten
- The current UserDefaults approach works correctly at the current data scale — it's a performance concern, not a correctness concern
- New fields added in this change (fiber, 5h checkpoint, confounding meal detection) would need to be in the Core Data schema, making the migration more complex if done now

**What needs to happen:**
1. Define a Core Data model for `V2MealOutcomeEntity` with relationships to `V2BGCheckpointEntity` and `V2AdaptiveAdjustmentEntity`
2. Write a one-time migration that reads existing UserDefaults JSON and inserts into Core Data
3. Replace all `UserDefaults`-based CRUD in `V2OutcomeLearningStore` with `NSManagedObjectContext` operations
4. Add `NSFetchedResultsController` or similar for the outcome analysis view instead of loading all records
5. Remove the UserDefaults key after successful migration
6. Test with ~270 records to verify performance improvement

---

### 14. Gentilcore Liquid Fat Caveat

**Status: IMPLEMENTED**

**File:** `docs/V2DosingStrategy.md`, Section 4

**What was done:**
- Added a blockquote caveat after the 0.8 min/g coefficient noting it's derived from liquid fat load studies
- Added a paragraph documenting the new fiber modification of τ with the formula and 0.3 min/g coefficient

**Remaining work:** None.

---

### 15. Add Fiber Modifier to Carb Absorption Tau

**Status: IMPLEMENTED**

**Files:** `MacroAbsorptionEngine.swift`, `V2CurveOutcomeLearning.swift`, `V2DosingStrategy.md`

**What was done:**
- Added `fiberGrams: Double = 0` parameter to `carbTau()` with 0.3 min/g coefficient and 5g threshold
- Added `fiber: Double = 0` parameter to `generateEntries()`
- Added `originalFiber: Double` to `MacroAbsorptionResult`
- Added `fiber: Double` to `V2MealOutcome` struct
- `createOutcome()` now passes `result.originalFiber` into the outcome
- Documented the fiber modifier formula in V2DosingStrategy.md Section 4

**Implementation decision:** Used the coefficients exactly as specified (0.3 min/g, 5g threshold). The default value of `fiber: 0` in `generateEntries()` makes the change backwards-compatible — existing call sites that don't have fiber data continue to work without modification.

**Remaining work:**
- The Cronometer meal snapshot extraction needs to add an `HKQuantityType(.dietaryFiber)` query to pull fiber from Apple Health. This is the same pattern used for carbs, fat, and protein — no new data pipeline, just an additional query.
- The settings view example calculation doesn't yet show fiber's effect. A fiber field could be added to the example section, but the current example ("65g Carbs, 28g Fat, 35g Protein") is already dense. Consider adding a separate high-fiber example instead.

---

### 16. Testing Strategy for Safety-Critical Changes

**Status: IMPLEMENTED**

**File:** `TrioTests/V2MacroEngineTests.swift` (new file)

**What was done:** Added a test suite covering the specified test cases:

- **Gate 5 tests:** IOB at threshold passes, IOB exceeds threshold fails, zero IOB passes
- **Gate 3 hysteresis tests:** trend above threshold passes, trend below threshold fails, hysteresis requires recovery to 0 before re-enabling (3-step sequence)
- **Fat coefficient tests:** below 5g returns 0, at threshold uses minimal coefficient, at plateau uses full coefficient, mid-range is between extremes, monotonicity verification across full range
- **Fiber modifier tests:** below threshold has no effect, above threshold increases tau correctly, high-fiber cereal example matches expected value
- **Phase attribution tests:** low-protein meal gets no protein checkpoints, low-fat meal skips fat checkpoints, full-macro meal gets all phases, 5h checkpoint exists for protein peak
- **Confounding meal tests:** meals 3h apart are within 8h window, meals 10h apart are not
- **Protein factor range test:** clamp at 0.80 matches slider bound

**Implementation decision:** Used Swift Testing framework (`@Suite`, `@Test`, `#expect`) to match the project's existing test patterns. Tests are pure unit tests that don't require Core Data context — they test the engine functions, gate evaluation, and phase attribution directly.

**What was NOT tested (and what remains):**
- **Integration test for cumulative scaling persistence (#9):** Requires creating a `MacroAdaptiveService` instance, writing to UserDefaults, destroying the instance, creating a new one, and verifying state is restored. This is testable but needs careful UserDefaults cleanup to avoid test pollution.
- **Meal-attributed IOB tests (#1):** The accumulator functions (`recordMealInsulin`, `getMealAttributedIOB`) are trivially correct, but the full integration — bolus delivery → record → adaptive cycle reads correct value — requires mocking the bolus delivery path.
- **Replay test for phase attribution convergence (#3):** Requires historical V2MealOutcome records with known BG checkpoints to verify parameter trajectories. This is a data-dependent test best done with real or realistic synthetic meal data.
- **Full confounding meal detection test (#4):** The per-checkpoint dirty marking logic is tested indirectly via the overlap window check, but a full test requires creating V2MealOutcome records, persisting them, calling `detectConfoundingMeals()`, and verifying checkpoint `isClean` flags. This requires UserDefaults setup/teardown.

---

## ADDITIONAL ITEMS (Discovered During Implementation)

### 17. Fiber Full-Stack Integration

**Status: IMPLEMENTED** (commit `e6095d3`)

**Problem:** Item #15 added fiber support to the engine (`MacroAbsorptionEngine.carbTau()` and `generateEntries()` accept a `fiber` parameter) and to the outcome struct (`V2MealOutcome.fiber`). However, fiber is always `0` because no part of the data pipeline actually collects or passes fiber data. The engine support exists but is inert.

**Root cause investigation:** Fiber is absent from every layer:

| Layer | Current State | What's Needed |
|-------|--------------|---------------|
| Apple Health permissions | Only requests `.dietaryCarbohydrates`, `.dietaryFatTotal`, `.dietaryProtein` | Add `.dietaryFiber` to `requestPermissions()` |
| Cronometer extraction | Only queries carbs, fat, protein from HealthKit | Add `HKQuantityType(.dietaryFiber)` query |
| `CarbsEntry` struct | Has `carbs`, `fat`, `protein` — no `fiber` | Add `fiber: Double` field |
| `InferredMealEvent` struct | Has `carbs`, `fat`, `protein` — no `fiber` | Add `fiber: Double` field |
| Core Data `CarbEntryStored` | Has `carbs`, `fat`, `protein` attributes — no `fiber` | Add `fiber` attribute (requires migration) |
| `CarbsStorage.saveCarbEquivalents()` | Passes `carbs`, `fat`, `protein` to engine | Pass `fiber` too |
| `TreatmentsStateModel` | Threads macros to CarbsStorage — no `fiber` | Add `fiber` property, thread it through |
| Treatment/meal entry UI | Has carbs, fat, protein fields — no fiber | Add optional fiber field |

**Files that need changes:**

1. **`Trio/Sources/APS/Storage/HealthKitManager.swift`** — Add `.dietaryFiber` to HealthKit permission request
2. **`Trio/Sources/Modules/Cronometer/CronometerViewModel.swift`** (or equivalent) — Query fiber from Apple Health alongside other macros
3. **`Trio/Sources/APS/Storage/CarbsEntry.swift`** — Add `fiber: Double` field
4. **`Trio/Sources/APS/Storage/InferredMealEvent.swift`** — Add `fiber: Double` field
5. **`Trio.xcdatamodeld`** — Add `fiber` attribute to `CarbEntryStored` entity (lightweight migration)
6. **`Trio/Sources/APS/Storage/CarbsStorage.swift`** — Thread `fiber` from `CarbsEntry` to `MacroAbsorptionEngine.generateEntries(fiber:)`
7. **`Trio/Sources/Modules/Treatments/TreatmentsStateModel.swift`** — Add `fiber` property, pass to CarbsStorage
8. **`Trio/Sources/Modules/Treatments/TreatmentsView.swift`** (or equivalent) — Optional: add fiber input field to manual meal entry

**Implementation plan:**

Phase 1 — Data pipeline (no UI changes):
1. Add `.dietaryFiber` to HealthKit permissions
2. Add `fiber` to `CarbsEntry` and `InferredMealEvent`
3. Add `fiber` attribute to Core Data model (lightweight migration — new optional attribute with default 0)
4. Wire fiber through `CarbsStorage` → `MacroAbsorptionEngine.generateEntries(fiber:)`
5. Wire fiber through `TreatmentsStateModel` → `CarbsStorage`

Phase 2 — Cronometer integration:
6. Query `HKQuantityType(.dietaryFiber)` in Cronometer snapshot extraction
7. Populate fiber in the `CronometerMealRecommendation` (or equivalent) data flow

Phase 3 — Manual entry (optional):
8. Add fiber field to meal entry UI for users who don't use Cronometer

**Note:** Phase 1 and 2 are required for fiber to stop being `0`. Phase 3 is nice-to-have — most fiber data will come from Cronometer/Apple Health.

**Dependency:** The Core Data migration in Phase 1 is a small additive change (new optional attribute with default value). This is independent of the larger outcome storage migration in #13. Lightweight Core Data migration handles this automatically.

---

### Export System (Completed — not in original 16)

**Status: IMPLEMENTED**

**Files:** `V2CurveOutcomeLearning.swift`, `V2OutcomeAnalysisView.swift`, `CarbsStorage.swift`, `TreatmentsStateModel.swift`

**What was built:** Comprehensive JSON meal data export accessible from Settings > V2 Macro Dosing > Outcome Analysis. Captures every meal the V2 engine has processed with full dosing context:

- Pre-meal BG trace (2h before meal)
- Post-meal BG trace (meal to +8h)
- All V2 scheduled dosing entries from Core Data (via fpuID linkage)
- Garmin sensitivity contributions (re-derived from stored snapshot)
- Full user settings snapshot (V2 engine + OpenAPS/oref settings)
- Dosing summary (upfront insulin, protein/fat equivalents, entry counts)
- Complete V2MealOutcome with macros, engine params, checkpoints, adaptive adjustments

**Critical bug fixed — mealID linkage (commit `b76b71e`):**
The initial export always showed zero scheduled entries. Root cause: `V2MealOutcome.mealID` was a random UUID created in `applyCronometerRecommendation()`, while `MacroAbsorptionEngine.generateEntries()` created a separate UUID used as `fpuID` in Core Data. They never matched. Fix:
1. `CarbsStorage` now exposes `v2LastEngineMealID` after the engine runs
2. Outcome save is deferred from `applyCronometerRecommendation()` to `invokeTreatmentsTask()` (after `saveMeal()`)
3. Pending outcome is finalized with the engine's actual mealID via `withMealID()`

See `docs/V2ExportSystem.md` for complete documentation including timing sequence, data flow, all export struct fields, and known limitations.

---

## Items NOT Changed (Confirmed Correct)

The following were reviewed and found to be correctly implemented:

- Gamma(2, τ) CDF/PDF formulas
- Fat modification of τ: `baseTau + fat × 0.8` (now also `+ fiberDelay`)
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
- Settings UI slider ranges match whitepaper (protein factor now unified at 0.10–0.80)
- Example calculation in settings correctly uses engine functions (now with nonlinear fat)

---

## Summary of Remaining Work

### Integration Wiring (functions exist, need call-site connections)

| Item | What needs wiring | Where |
|------|------------------|-------|
| #1 | Call `recordMealInsulin(mealID, units)` when boluses/SMBs are delivered | Bolus delivery + SMB delivery code paths |
| #2 | Populate `mealStartBGs` from `V2MealOutcome.bgAtMeal` for active meals | Caller of `runAdaptiveCycle()` |
| #5 | Gate 5 params already computed internally — no additional wiring needed | — |

### New Features (design + implementation needed)

| Item | Scope | Effort |
|------|-------|--------|
| #12 — Claude AI recalibration spec | Design prompt schema, validation pipeline, user confirmation UX, error handling. Then implement service + document in whitepaper. | Large — requires design decisions before implementation |
| #13 — Core Data migration for outcomes | Define Core Data model, write migration, replace UserDefaults CRUD, add fetch controllers. | Large — architectural change, but not urgent (UserDefaults works at current scale) |

### Whitepaper Updates (documentation only)

| Item | What | Where |
|------|------|-------|
| #7 | Document `-3.0` threshold with hysteresis (replaces `-5.0`) | V2DosingStrategy.md Section 9 |
| #10 | Update clamping table to show 0.10–0.80 (replaces 0.10–0.60) | V2DosingStrategy.md Section 11 |

### Priority Order for Remaining Work

1. **#1/#2 Integration wiring** — Completes the adaptive service's meal-specific IOB and BG delta calculations. The adaptive service works but uses less precise inputs without this wiring.
2. **#12 Claude AI spec** — Defines the AI recalibration feature. Can be designed using the export data (which is now fully functional) to prototype prompts and validate parameter recommendations.
3. **#13 Core Data migration** — Performance optimization. Only becomes urgent at high meal volume (~270+ records).
