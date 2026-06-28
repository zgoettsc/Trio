# Meal Intelligence v2 — Implementation Spec

Sweeps the unshipped items from `MEAL_INTELLIGENCE_BACKLOG.md` + bugs +
follow-ups from the 2026-06-27 dinner/Indian post-mortem into a single
buildable plan. Order = implementation order (low-risk fixes first,
then settings, then UI, then the live estimator).

---

## Bug 1 — Duplicate-carb alert misses Treatments→Treatments same-flow

**Observed (dinner 2026-06-27, window BFE029FA):**
Two 65g/10f/20p entries logged 39 s apart, no alert fired. First entry
came from `AnnounceMealIntentRequest.startMealAndLogCarbs` (SavedMeals
"Start" path), second from `Treatments.saveMeal`. The duplicate check
in `saveMeal` ran but returned nil.

**Root cause:**
`findDuplicateRecentCarbEntry` queries `viewContext`. The first entry
was written via the storage layer's private context and `context.save()`.
viewContext doesn't auto-refresh in this case, so the query against
viewContext returned an empty result.

**Fix:**
Use `CoreDataStack.shared.newTaskContext()` instead of `viewContext` for
the duplicate-check query. Task contexts always read fresh from the
persistent store coordinator.

**Files:** `Trio/Sources/Modules/Treatments/TreatmentsStateModel.swift`
(method `findDuplicateRecentCarbEntry`).

**Verification:** repeat the SavedMeal-Start → Treatments-Save flow and
confirm the alert fires.

---

## Bug 2 — No warning when an override starts DURING a meal window

**Observed (dinner 2026-06-27):**
Running override started at 22:33:05, 16 min into the meal window.
Override has `percentage: 75, target: 160` — it gutted dosing pressure
during the steepest climb. The `smbIsOff`-style activation warning only
fires at window-open, so no warning was shown.

**Fix:**
Observe override state changes. When an override starts AND a meal
window is active AND the override carries `smbIsOff == true` OR a low
percentage (<=80%) OR an elevated target (>=140) — present a one-shot
warning via local notification:

> ⚠ Override "Running" started during your meal window. SMB dosing
> may be reduced — meal coverage will be weaker.

Implementation:
- `OverrideStorage` already posts a `Foundation.Notification` on
  override changes (verify by grepping for `NotificationCenter.default
  .post.*[Oo]verride`). If not, add one.
- New subscriber lives in `HomeStateModel` (already watches meal-window
  state) — on a fired notification, if `mealWindowActive == true`, post
  a local UN notification using the existing notification infrastructure.
- Also emit an `overrideStartedDuringMealWindow` telemetry event so
  analysis can correlate the warning with subsequent BG performance.

**Files:** `HomeStateModel.swift` (subscribe + warn),
`AlgorithmTelemetryEvent.swift` (new event kind),
`AnnounceMealIntentRequest.swift` (already has
`detectActiveSMBSuppression` — reuse / extend the same condition logic).

---

## Feature 1 — `mealWindowCOBDecayMultiplier` setting

**Rationale:**
Indian + Coconut Chicken both showed BG climbing past the moment COB
dissolved to 0. Oref's COB model under-represents fat/protein meals.
This setting lets the user halve (or otherwise dial) the per-loop COB
decay rate during an active meal window. Different from phantom COB
(which lies about quantity); this preserves the *quantity* and stretches
the *time*. Direct lever, clean mental model.

**Schema:**
- New `TrioSettings` field: `mealWindowCOBDecayMultiplier: Decimal`
  (default `1.0`, range `0.25–1.0`).
- Pass through `TrioCustomOrefVariables` to oref as
  `meal_window_cob_decay_multiplier`.

**Wire in `determine-basal.js`:**
Find where COB consumption is computed each loop (the `cob_decrement`
or equivalent reduction step). When `mealWindowActive == true`, multiply
the decrement by `meal_window_cob_decay_multiplier`. Pseudo:

```js
if (profile.mealWindowActive && profile.meal_window_cob_decay_multiplier) {
  cob_decrement *= profile.meal_window_cob_decay_multiplier;
}
remaining_cob -= cob_decrement;
```

**Telemetry:**
Add `effectiveMealWindowCOBDecayMultiplier` to the per-loop row so
post-hoc analysis can verify the multiplier was applied.

**UI:**
Add a row to the existing Eating Mode Tuning settings screen with a
slider 0.25–1.0 step 0.05. Footer: "Slows oref's COB consumption during
a meal window. 1.0 = normal. 0.5 = drain at half speed. Useful for
fat-heavy meals where actual absorption outlasts the model."

**Telemetry event** when the user changes the value: existing
`mealWindowTuningChanged` event already covers this — just add the field
to the tracked-fields list.

**Files:**
- `TrioSettings.swift` (add field)
- `TrioCustomOrefVariables.swift` (pass through)
- `bundle/oref0/lib/determine-basal/determine-basal.js` (consume)
- `EatingModeTuningView.swift` (UI row)
- `AlgorithmTelemetryManager.swift` (effective-value column +
  tracked-fields list)
- `ANALYSIS_METHODS.md` on telemetry branch (document new field)

---

## Feature 2 — Auto-extend window on classifier upgrade to Complex

**Rationale:**
When the live classifier upgrades Simple → Medium → Complex via the
late-re-rise rule, today only the SMB aggression changes. The window
duration is still whatever was set at activation. The Indian meal at
2026-06-27 01:27 upgraded to Complex at t=178 min but the window ran
the standard duration — late-phase coverage went unmonitored.

**Behavior:**
When the classifier transitions to `.complex` (and only the first time
per window), and the configured extended duration is shorter than
6 hours, extend `mealWindowDurationMinutes` to max(current, 6h).
Re-publish to settings so APSManager picks it up.

**Edge cases:**
- Already at or past 6h → no-op
- User has manually cancelled the window already → no-op
- Don't extend if classifier upgraded from a SavedMeal that already
  seeded Complex (no late-rise trigger fired, so no signal to extend)

**Telemetry:**
Emit `mealWindowAutoExtended` event with old/new duration and the
trigger reason.

**Files:**
- Where the classifier writes `mealCurrentClassification = .complex` —
  add the duration nudge right next to it.
- `AlgorithmTelemetryEvent.swift` (new event kind).

---

## Feature 3 — Per-meal scatter: Autosens-at-activation vs peak-Δ

**Rationale:**
We now log `autosensRatioAtActivation` and can compute `peakDelta`. The
visual answer to "does Autosens actually predict this meal's excursion
size?" is a tiny scatter plot in `SavedMealDetailView`.

**UI:**
New section "Sensitivity vs excursion" in `SavedMealDetailView` that
renders only when ≥3 instances have both fields. Scatter points: each
instance = one dot. X = autosens ratio (0.7–1.3 typical range). Y =
peak-Δ (mg/dL above activation BG). Reference lines at x=1.0 and y=0.
Footer interprets:
- Negative slope: loop already compensating (closed-loop ideal)
- Flat: Autosens is noise for this meal
- Positive slope: sensor flags resistance and dosing isn't acting on it

Add a Smart-Sense variant via a small picker if Smart-Sense data exists.

**Files:** `SavedMealDetailView.swift` (UI), no data-layer changes.

---

## Feature 4 — Carb-counting feedback widget per saved meal

**Rationale:**
The post-hoc estimator now runs per-instance. Across instances we can
surface `median_delta = median(estimatedCarbs - enteredCarbs)`. When a
meal consistently under-counts by ≥20g (over ≥3 instances), suggest a
nudge to the SavedMeal's default carbs.

**UI:**
New section "Carb-count feedback" in `SavedMealDetailView` showing:
- N instances analyzed
- Median entered, median estimated
- Median delta with color (green if |Δ|<20g, orange 20-50g, red >50g)
- "Suggested default: 130 g" button → opens the meal edit with the
  carbs field pre-filled
- Footer notes that suggestions exclude override-affected and
  not-returned-to-baseline rows for reliability

**Files:** `SavedMealDetailView.swift` (UI), `CarbsEstimator` already
provides the per-instance compute, just aggregate.

---

## Feature 5 — Live (a priori) carbs estimator + banner

**Rationale:**
The post-hoc estimator catches misses AFTER the fact. A live version
nudges the user mid-meal to add more carbs (or phantom COB) when the
trajectory shows the entered count is too low.

**Algorithm (method A from the discussion doc):**
Each loop pass during an active meal window, compute:
```
expected_BG = bgAtActivation
             + carbs_absorbed_so_far × ISF/CR
             − insulin_above_baseline × ISF
implied_extra_carbs = max(0, actual_BG − expected_BG) × CR / ISF
```
Where `carbs_absorbed_so_far` = `originalCOB − currentCOB`, and
`insulin_above_baseline` is a rough integral of (tempBasal − scheduled)
plus SMB sum since window start.

**Trigger conditions** (all must hold to fire):
- ≥30 min since window open (gives signal time to develop)
- `implied_extra_carbs > max(20g, 30% of entered)`
- ≥3 consecutive loops meeting the threshold (noise suppression)
- No override currently active
- No suggestion fired in the last 30 min (re-trigger cooldown)

**UI:**
- Home view meal-window pill changes color when triggered
- Tap surfaces sheet:
  > Your BG is rising faster than the 65 g you entered.
  > Estimated additional: **+45 g** (range 35–55 g).
  > [Add 45g now] [Add custom] [Dismiss]
- "Add 45g now" creates a delayed carb entry (10 min absorption start)
- "Add custom" opens Treatments pre-filled

**Telemetry:**
- `liveCarbsEstimateTriggered` event with implied amount and reasoning
- `liveCarbsEstimateAccepted` / `liveCarbsEstimateDismissed` follow-up

**Files:**
- New service `LiveCarbsEstimator.swift` — invoked from APSManager's
  loop-completion hook
- Hook into HomeStateModel for banner state
- `MealWindowPill.swift` and `HomeRootView.swift` for UI
- `AlgorithmTelemetryEvent.swift` for the three new kinds
- `CarbsEstimator` shared math (extract the back-calc into a static
  function both estimators use)

---

## Feature 6 — FPU factor surfacing (low priority)

**Rationale:**
The fat-protein-unit factor is an existing oref setting that controls
how aggressively delayed carb-equivalent gets logged. Surfacing it in
the Eating Mode Tuning screen lets the user dial it without diving
into the preferences JSON.

**UI:**
Just expose the existing setting as a slider in the tuning screen.
No new logic. Document the trade-off in the footer: bumping it up
helps fat-heavy meals but over-corrects quick-carb meals.

**Files:** `EatingModeTuningView.swift` only.

---

## Feature 7 — Confidence ranges everywhere

**Rationale:**
The in-app estimator shows `low–high g` range. The docs sometimes show
a single number. Sync them.

**Files:** `docs/MEAL_INTELLIGENCE_BACKLOG.md`, `ANALYSIS_METHODS.md`
on telemetry branch — augment example calculations to show ±15% range.

---

## Implementation order

1. **Bug 1** — single-line fix, immediate win
2. **Bug 2** — override observer + warning (small)
3. **Feature 6** — FPU setting surfacing (existing oref var, just UI)
4. **Feature 1** — COB decay multiplier (settings + JS + telemetry + UI)
5. **Feature 2** — auto-extend on Complex upgrade
6. **Feature 3** — per-meal Autosens scatter (UI only)
7. **Feature 4** — carb-counting feedback widget (UI + aggregator)
8. **Feature 5** — live carbs estimator (biggest, do last)
9. **Feature 7** — doc sync at the end

Build → test → push at logical breakpoints.
