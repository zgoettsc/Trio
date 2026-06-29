# Meal Intelligence v3 — Spec & Shipped Features

Covers everything that landed after `MEAL_INTELLIGENCE_v2_SPEC.md` —
inverse CR/ISF calibration + a hardening pass on the live mid-meal
estimator that wraps the trigger in four context guards plus an
auto-retract for stale banners.

Keep in sync with the mirror on the `telemetry` branch.

---

## 1. Inverse calibration (SHIPPED — commit f652226f0, label fix 8adb0c52d)

**Idea:** flip the post-hoc carbs estimator. Forward estimator infers
carbs from BG response + assumed CR/ISF; inverse infers CR/ISF from
BG response + user-verified ground-truth carbs. Calibrates the
foundational settings the forward estimator silently inherits.

### Math

Forward (already shipped):
```
carbs_implied = peak_rise × CR/ISF + insulin × CR
```

Inverse — solve for CR (assume ISF correct):
```
CR = carbs / (peak_rise/ISF + insulin)
```

Inverse — solve for ISF (assume CR correct):
```
ISF = peak_rise × CR / (carbs − insulin × CR)
```

When `carbs − insulin × CR ≤ 0` the meal's verified carbs were ≤ what
the delivered insulin covered at the current CR — no rise budget
remains for ISF to explain. **ISF goes indeterminate** in that case and
that row drops from the ISF median; CR back-calc still produces.

### Schema

`SavedMealInstance` adds two attestation fields:

| Field | Type | Purpose |
|---|---|---|
| `userVerifiedCarbsAmount` | NSDecimalNumber? | Ground-truth grams the user attests to |
| `verifiedAt` | Date? | When the attestation was recorded |

Attestation **never mutates** `carbsAtActivation` and does NOT write a
new `CarbsEntry`. It's a calibration record, not a dosing change.

### UI

**Per-instance** (`SavedMealInstanceDetailView`):
1. New "Verified carbs" section — "Mark as verified (I know the exact
   carbs)" button → `VerifyCarbsSheet` for entry; clear / re-edit
   affordances when already verified.
2. New "Calibration (back-calc)" section — appears once verified.
   Shows back-calc CR + ISF with % delta vs the profile-at-meal-time
   captured in `*AtActivation` snapshots. Color-coded delta: <10%
   green, <25% orange, ≥25% red.

**Per-meal** (`SavedMealDetailView`):
- New "Calibration (verified meals)" aggregator — median back-calc
  CR + ISF across all verified instances of this saved meal.
- Guards: "Need ≥3 verified meals before changing your profile based
  on this" amber label when n < 3.

### Confidence + caveats

`InverseCalibrator` mirrors `CarbsEstimator`'s exclusion logic:
override-affected → low; temp target / didn't-return-to-baseline /
backfilled → medium floor; fallback profile values used → low cap;
legacy negative-insulin rows (pre-fix overlap bug) → SMB-sum
substitution with explicit caveat in the footnote.

### Telemetry

Two new event kinds:

- `mealCarbsVerified` — fired on save. Payload includes
  `verifiedCarbs`, `priorVerifiedCarbs`, `entered`, `assumedCR`,
  `assumedISF`, `backCalcCR`, `backCalcISF`, `deltaCRPercent`,
  `deltaISFPercent`, `isfIndeterminate`, `confidence`. Self-contained
  so offline analysis doesn't need to rejoin the instance table.
- `mealCarbsVerifiedCleared` — fired on clear. Payload:
  `priorVerifiedCarbs`.

### Files

- `Model/TrioCoreDataPersistentContainer.xcdatamodeld/.../contents`
- `Model/Classes+Properties/SavedMealInstance+CoreDataProperties.swift`
- `Trio/Sources/Modules/AIInsightsConfig/View/InverseCalibrator.swift` (NEW)
- `Trio/Sources/Modules/AIInsightsConfig/View/SavedMealInstanceDetailView.swift`
- `Trio/Sources/Modules/AIInsightsConfig/View/SavedMealDetailView.swift`
- `Trio/Sources/Services/AlgorithmTelemetry/AlgorithmTelemetryEvent.swift`

---

## 2. Live mid-meal estimator — hardening pass

The estimator shipped in v2 (Feature 5) ran with no context awareness:
it fired any time `impliedSoFar − enteredCarbs ≥ max(20, 30%)` for 3
consecutive loops, gated only by a 30-min cooldown and the override
check. Today's Sunday Breakfast (65g + 20g + estimator-accepted +31g =
116g logged, real likely ~95g) tripped FOUR triggers, two while BG was
actively dropping and the loop was suspended at the safety floor.

Five fixes, in commit order:

### 2a. FP guard (commit 6a7917600)

**Rule:** suppress if `fat + protein ≥ 25g` (logged via non-FPU
`CarbEntryStored` rows since window open) **AND** `minutesSinceOpen < 60`.

**Rationale:** on FP-heavy meals the early-window "BG higher than
expected" signal is the carb absorption curve, not under-counted carbs.
Accepting the suggestion stacks phantom carbs that drive over-aggressive
SMBs and parks the user with too-much-IOB when the FP-delayed half of
the rise finally lands.

**Behavior:** guard releases on its own at the 60-min mark; consecutive
counter is **not** reset so the first eligible loop post-60 can fire if
the trigger is still real.

**Setting:** `liveCarbsEstimatorFPGuardEnabled` (defaults on). Toggle
surfaced in Eating Mode Tuning.

### 2b. Trend guard (commit 526771841)

**Rule:** suppress if `shortAvgDelta ≤ 0` AND `delta5m ≤ 2` — BG is
flat or falling, not actively rising.

**Rationale:** the implied-extra math is direction-blind. Accumulated
rise + IOB stays elevated long after BG has peaked, so the trigger
keeps firing "your meal looks bigger" while BG is actively dropping —
exactly opposite of what's actually happening. If the user is going
low, that's a hypo alarm and a different signal — don't conflate.

### 2c. Loop-parked guard (commit 526771841)

**Rule:** suppress if `eventualBG ≤ 55` — oref has pinned at or near
the minimum-floor sentinel (39 + headroom for sensor noise).

**Rationale:** when the loop has shut off insulin because it predicts
a crash, telling the user to add more carbs to the model can't help —
the loop has no room to dose those carbs and they'd just stack on top
of already-too-much IOB.

### 2d. Auto-retract (commit 526771841)

**Rule:** at the top of each loop pass, if there's a pending suggestion
for the current window AND conditions have turned (`shortAvgDelta ≤ 0`
OR `eventualBG ≤ 55`), wipe `pendingLiveCarbsSuggestion` from settings.

**Effect:** the banner disappears on the next loop pass — previously it
sat until the user tapped through, even when the suggestion was no
longer valid.

### 2e. Live carb sum (commit f4e226b86)

**Rule:** sum non-FPU `CarbEntryStored` rows since window open every
loop pass; use that as the trigger's `enteredCarbs` baseline.

**Rationale:** the previous baseline was `s.mealWindowEstimatedCarbs`,
a snapshot **frozen at meal-window activation**. After the user
accepted a +31g estimator suggestion (carbs went 65 → 96 in the actual
entries), the snapshot stayed at 65. The math kept seeing the same
+27g "gap" against an outdated baseline and re-fired against carbs
that had already been added. Reading the live sum makes acceptance
visible to the trigger and stops the repeat-prompt loop cold.

### Guard stack ordering

```
1. evaluateLiveCarbsEstimate is called each loop pass while window active
2. Auto-retract: wipe stale pending banner if conditions turned
3. Gating preconditions (windowId, activation date, BG, ISF, CR, no override)
4. enteredCarbs = live CarbEntryStored sum (2e)
5. Compute impliedSoFar, extra, threshold; increment consecutive counter
6. Require 3-consecutive-above-threshold
7. FP guard (2a) — return without resetting counter
8. Trend guard (2b) — return
9. Loop-parked guard (2c) — return
10. 30-min cooldown check
11. Fire: write pendingLiveCarbsSuggestion, send notification, log triggered event
```

### Suppression telemetry

New event kind: `liveCarbsEstimateSuppressed`. Payload includes:

| Field | When | Notes |
|---|---|---|
| `reason` | always | One of `fpGuard`, `trendNotRising`, `loopParked`, `retracted` |
| `extra` | most reasons | Implied extra at the moment of suppression |
| `enteredCarbs` | most reasons | Live carb sum used in the math |
| `bg`, `minutesSinceOpen` | most reasons | Context for analysis |
| `fpGramsLogged`, `fpGuardThresholdGrams`, `fpGuardWindowMinutes` | fpGuard | FP totals + cutoff |
| `shortAvgDelta`, `delta5m` | trendNotRising | Trend signals |
| `eventualBG` | loopParked | Loop's predicted BG |
| `nowFalling`, `nowParked`, `priorSuggestedExtra` | retracted | Which condition turned + what was prior |

### Settings

| Field | Default | Effect |
|---|---|---|
| `liveCarbsEstimatorEnabled` | true | Master switch (already shipped) |
| `liveCarbsEstimatorNotificationsEnabled` | true | Push (already shipped) |
| `liveCarbsEstimatorNotificationSound` | true | Sound (already shipped) |
| `liveCarbsEstimatorFPGuardEnabled` | true | NEW — FP early-window guard |

Trend, loop-parked, retract, and live-carb-sum are not user-toggleable
— they're correctness fixes, not aggression knobs.

### Files

- `Trio/Sources/APS/APSManager.swift` (all five guards + helpers)
- `Trio/Sources/Models/TrioSettings.swift` (FP guard setting + Decodable)
- `Trio/Sources/Modules/AIInsightsConfig/View/EatingModeTuningView.swift` (FP toggle)
- `Trio/Sources/Services/AlgorithmTelemetry/AlgorithmTelemetryEvent.swift` (suppressed event)

---

## 3. Behavior-based meal-window exit (SHIPPED — commit pending)

Replaces rigid timer-based window expiry with a state-based "the
meal is done" detector. Solves the case the user hit on quick-action
lunches: window opens via Action Button without carbs entered, BG
climbs, classifier upgrades Simple → Medium (not Complex), loop
correctly fires SMBs, window expires at the rigid 90-min mark while
BG is still climbing and the loop is still dosing — meal-mode
aggression yanked at exactly the wrong moment.

### Why the previous design fell short

`mealWindowDurationMinutes` (90) ran to expiry. Auto-extend only fired
on Complex upgrade (late-re-rise pattern). Steadily-climbing meals
that hit Medium but not Complex closed at the timer regardless of BG
trajectory. The system already has the signals — it just wasn't using
them for window close.

### Exit rules (any one closes the window)

Evaluated on every loop pass while `mealWindowBehaviorBasedExitEnabled`
is on, AFTER `minutesSinceOpen ≥ mealWindowDurationMinutes` (the
minimum-duration floor):

| Rule | Conditions (all must hold) | Use case |
|---|---|---|
| `peakDropConfirmed` | drop from running max ≥ 30 mg/dL AND ≥ 45 min since max AND `shortAvgDelta < 0` AND `eventualBG > 55` | Normal "BG came down" exit. FP late-second-peak resets via new max instead of triggering false exit |
| `loopIdleAtBaseline` | no SMB fired in last 30 min AND BG ∈ [80, 140] AND `eventualBG > 55` | Monotonic-finish meals that absorb cleanly without a sharp peak (small carb-only) |
| `maxDurationCap` | `minutesSinceOpen ≥ mealWindowBehaviorExitMaxMinutes` (default 600 = 10 h) | Safety cap — enforced via `auditExpiredMealWindow`'s tightened cap when behavior-exit is on |

### Floor-park inhibitor

The detector returns immediately if `eventualBG ≤ 55` (oref parked
near safety floor). The meal is NOT done if the loop has shut off
insulin to prevent a crash — keep the window open so the user has
meal-mode floor logic + the visible banner during recovery.

### Minimum-duration floor

Behavior-exit never fires before `mealWindowDurationMinutes` (default
90). Single-sample noise + thin early-window data + short
fast-carb meals all benefit from the floor.

### Hard safety cap

`mealWindowBehaviorExitMaxMinutes` (default 600) bounds how long a
window can run. Enforced in `AlgorithmTelemetryManager.auditExpiredMealWindow`:
when behavior-exit is on, the cap on natural-expiry rises from 360 to
this value; when off, falls back to the old 360 cap.

### Telemetry

New event: `mealWindowClosedByExitRule`. Payload always includes
`reason` (one of the three above), `minutesSinceOpen`, `carbsConfirmed`,
plus rule-specific fields:

- `peakDropConfirmed`: bg, peakBG, dropFromPeak, minutesSincePeak,
  shortAvgDelta, eventualBG
- `loopIdleAtBaseline`: bg, peakBG, minutesSinceLastSMB,
  shortAvgDelta, eventualBG
- `maxDurationCap`: emitted via `mealWindowExpired` as before
  (rule path remains the safety-cap timer)

`recordWindowClose` writes `closeReason = "behaviorBasedExit:<rule>"`
so the per-meal summary row identifies which rule fired without
re-joining the events table.

### Settings

| Field | Default | Effect |
|---|---|---|
| `mealWindowBehaviorBasedExitEnabled` | true | Master switch |
| `mealWindowBehaviorExitMaxMinutes` | 600 (10 h) | Hard safety cap |

Toggle exposed in Eating Mode Tuning → "Meal window — exit". Cap is
not user-toggleable for v1; raise it in v4 if needed for ultra-long
FP meals.

### Files

- `Trio/Sources/Models/TrioSettings.swift` (two new settings + Decodable)
- `Trio/Sources/Services/AlgorithmTelemetry/AlgorithmTelemetryEvent.swift` (new event kind)
- `Trio/Sources/Services/AlgorithmTelemetry/AlgorithmTelemetryManager.swift` (cap raise + closeMealWindowByExitRule)
- `Trio/Sources/APS/APSManager.swift` (evaluateMealWindowExit + peakBG/SMB helpers)
- `Trio/Sources/Modules/AIInsightsConfig/View/EatingModeTuningView.swift` (toggle)

### Verification path

1. Quick-action a meal without entering carbs (mirror today's lunch
   bug). Confirm the window stays open past 90 min as long as BG is
   climbing or SMBs are firing.
2. After BG peaks and starts dropping, confirm `peakDropConfirmed`
   event fires within ~50 min of the peak (drop ≥ 30 + 45 min min).
3. FP meal with a clear second peak: verify the dip-and-re-rise
   bumps the running max instead of closing the window during the dip.
4. Disable the toggle and confirm timer-based 90-min expiry returns
   on the next meal.

---

## 4. Real-time phantom COB auto-injector (SHIPPED — DEFAULT OFF — commit pending)

**Status: EXPERIMENTAL.** Default OFF. Flipping ON requires typing
`ENABLE` in an in-app confirmation sheet. This is a real safety
surface: when active, the loop doses real insulin based on inferred
carb arrival that nobody explicitly told it about.

### Why

The quick-action meal mode is meant to be a flag — "I'm eating, deal
with it" — without forcing the user to enter macros. Current
behavior on a no-carbs-logged window: classifier upgrades, SMB
ratio boost fires, but oref's eventualBG model has no COB anchor,
so it stays conservative on dosing. Observed today's lunch
(2026-06-28 17:44, BG 120→174, only 4.15U of SMBs over 90 min for
what was clearly a ~75g meal). Loop wasn't failing; it was correctly
being cautious without a meal signal in its model.

### Mental model

Each loop pass, infer how many carbs BG behavior says have arrived
since window open. Subtract carbs already in the model
(logged + previously-injected phantom). The remainder is the unmodeled
arrival — inject it. oref's mealCOB now reflects the inferred meal
and doses for the arrival without the user having to type anything.

### Math

```
implied_so_far = max(0, current_bg - bg_at_activation) × CR/ISF
                 + insulin_since_window × CR
already_modeled = logged_carbs + previously_injected_phantom
unmodeled = implied_so_far - already_modeled
inject_this_loop = clamp(unmodeled × (1 - damping), 0, per_loop_cap)
new_cumulative = min(prior_injected + inject_this_loop, per_window_cap)
```

Same forward-estimator identity as the post-hoc CarbsEstimator and
the live-carbs notification — repurposed to drive phantom COB
instead of a banner.

### Safety gates (all must hold to inject this loop)

| Gate | Why |
|---|---|
| Master switch on | User has explicitly opted in via the typed confirmation |
| Meal window active | No injection outside an active window |
| Classifier ≥ Medium | BG pattern confirms a meal, not drift / noise |
| `shortAvgDelta > 0` | Only inject while BG is actively rising — never inject for carbs that aren't actively arriving. Central safety; protects against post-peak over-stacking and sensor-noise creep |
| Per-loop new phantom > 0.1g | Sub-noise sized increments don't fire |
| Cumulative < per-window cap | Bounds runaway accumulation |

When `shortAvgDelta ≤ 0` or other gates fail, we simply **don't add
more**. We never **withdraw** previously-injected phantom — withdrawal
would cause a sudden oref behavior change (sees big drop in COB, halts
dosing aggressively) and risks over-correction. Let oref's natural
COB decay handle the wind-down.

### Damping

`mealWindowAutoPhantomCOBDampingFactor` (default 0.5) scales the
per-loop new phantom by `(1 - damping)`. Smooths the closed-loop
feedback so a single noisy sample can't push us to the per-loop cap.

### Caps

| Setting | Default | Purpose |
|---|---|---|
| `mealWindowAutoPhantomCOBMaxGramsPerLoop` | 8g | Per 5-min loop — caps single-sample dominance |
| `mealWindowAutoPhantomCOBMaxGramsPerWindow` | 200g | Per-window total — bounds runaway accumulation. Covers any realistic single meal |

### Per-window state

`mealWindowAutoPhantomCOBInjectedGrams` (settings field) holds the
running cumulative. Reset to 0 on all window-close paths
(user cancel, natural expiry, behavior-based exit) and on detection
of a new window-id by the per-loop function.

### oref integration

New `TrioCustomOrefVariables.mealWindowAutoPhantomCOBLevel` field
carries the current cumulative to determine-basal.js. JS reads it as:

```js
const mwAutoPhantomLevel = trio_custom_variables.mealWindowAutoPhantomCOBLevel || 0;
if (mealWindowActive && mealWindowMinutesRemaining > 0 && mwAutoPhantomLevel > 0) {
    meal_data.mealCOB = Math.max(meal_data.mealCOB || 0, mwAutoPhantomLevel);
    meal_data.carbs   = Math.max(meal_data.carbs   || 0, mwAutoPhantomLevel);
}
```

Independent of the legacy one-shot `mwPhantomCOB` path (per-saved-meal
phantom at activation). Both can apply; MAX wins. The
`rT.mealWindowApplied.phantomCOBGrams` telemetry field carries the
combined effective level.

### UI — ALL-CAPS confirmation

Toggle row in Eating Mode Tuning → "Auto phantom COB (experimental)".
Tapping it does NOT flip the setting; it presents a sheet:

- Title: "Confirm enable"
- Orange "Real insulin will be dosed based on inferred carbs" header
- Educational paragraph about gates + risks
- Text field requesting the literal word `ENABLE` (case-sensitive)
- "Enable" button (destructive role) disabled until exact match
- "Cancel" button

Mistypes do nothing. Case-sensitive. Single accidental tap on the
toggle is not enough — only the typed confirmation flips it.
Reset-to-defaults intentionally does NOT touch this setting.

### Telemetry — and shadow mode

**Three loop-sample fields populate every meal-window pass regardless
of the master switch**, so two weeks of toggle-OFF data tells you
exactly what the injector would have done before you turn it on.
Schema v15:

| field | populated | what it carries |
|---|---|---|
| `autoPhantomShadowGramsThisLoop` | every meal-window pass | what the math says to inject this loop after gates + caps. 0 when a gate blocked |
| `autoPhantomShadowCumulativeGrams` | every meal-window pass | running shadow total since window open. In-memory accumulator; resets on window flip or app restart |
| `autoPhantomGateStatus` | every meal-window pass | `wouldFire` / `notRising` / `classifierBelowMedium` / `perWindowCap` / `perLoopCap` / `noResidual` / `noContext` |

These three are the **assessment surface**. See `ANALYSIS_METHODS.md
§Analysis 10` on the telemetry branch for the two-week baseline recipe
and the decision criteria for flipping the toggle on.

Plus two real-time events (only fire when switch is on):

| kind | when | payload |
|---|---|---|
| `mealWindowAutoPhantomCOBInjected` | Every loop pass that actually injects | injectedThisLoop, newCumulative, unmodeledImplied, impliedSoFar, priorInjected, bg, shortAvgDelta, iob, isf, cr, classification, minutesSinceOpen |
| `mealWindowAutoPhantomCOBToggled` | User flips master switch on or off (paired with the typed confirmation on enable) | enabled |

Per-loop injection events let us audit live behavior. The
toggle event marks the pre/post boundary for baseline analysis.

### Interaction with the live-carbs notification

The live-carbs notification ("your meal looks bigger") computes the
same residual but surfaces it as a user prompt. With the auto-injector
on, that suggestion is largely redundant — the system is already
acting on the residual silently. For v1 they coexist: notification
keeps firing (gated by FP/trend/loop-parked/retract guards) as an
advisory, since seeing "+25g auto-injected" in real time may help
the user develop trust in the auto path. If notification noise
becomes a problem, suppress when auto-injector is on.

### Files

- `Trio/Sources/Models/TrioSettings.swift` (five new settings + Decodable)
- `Trio/Sources/Models/TrioCustomOrefVariables.swift` (mealWindowAutoPhantomCOBLevel passthrough)
- `Trio/Sources/APS/OpenAPS/OpenAPS.swift` (gate the level on enabled, populate from settings)
- `trio-oref/lib/determine-basal/determine-basal.js` + bundle (consume the level)
- `Trio/Sources/APS/APSManager.swift` (evaluateAutoPhantomCOB per-loop detector)
- `Trio/Sources/Services/AlgorithmTelemetry/AlgorithmTelemetryEvent.swift` (two new event kinds)
- `Trio/Sources/Services/AlgorithmTelemetry/AlgorithmTelemetryManager.swift` (reset cumulative on window-close)
- `Trio/Sources/Modules/Home/HomeStateModel.swift` (reset cumulative on user-cancel)
- `Trio/Sources/Modules/AIInsightsConfig/View/EatingModeTuningView.swift` (toggle + AutoPhantomCOBConfirmSheet)

### Verification path

1. Build, enable telemetry, leave the toggle OFF for at least two
   weeks of normal meal usage.
2. Pull `loop.jsonl` for the period. Every meal-window pass should
   carry the three shadow fields. Aggregate per `windowId` and apply
   the decision criteria in `ANALYSIS_METHODS.md §Analysis 10`:
   ≥10 windows with shadow cumulative > 20g, healthy gate
   distribution, no run-away cumulatives > 150g.
3. Grep `events.jsonl` for `mealWindowAutoPhantomCOBInjected` —
   should be **zero rows** during baseline (master switch off).
4. After baseline passes the criteria: enable via the ALL-CAPS sheet.
4. On the next quick-action meal without carbs logged, watch for
   `mealWindowAutoPhantomCOBInjected` events in real-time telemetry.
   Verify `shortAvgDelta` is positive in every payload, cumulative
   monotonically increases, per-loop caps respected.
5. Verify oref's mealCOB matches the injected level on the next
   loop sample after each injection.
6. Compare peak BG / time-above-180 for next 5 quick-action meals
   vs pre-enable baseline.

---

## 5. Open v3 items (not built)

### 3a. Meal tags

Lightweight characterization without macros — `chicken`, `rice`,
`large`, `fatty`, etc. Hybrid schema: structured dimensions (Size,
FatLevel, CarbType, ProteinType) for prediction logic + free-form
tags for browsing. Per-user aggregation drives carb-equivalent
predictions on fresh meals. See `MEAL_INTELLIGENCE_BACKLOG.md §5` for
full design, risks, and phasing.

### 3b. Hypo-aware carb prompt

Today's bug surfaced a separate UX gap: when BG is dropping fast with
high IOB, the user needs a "eat 15g fast carbs" suggestion. The meal
estimator should never carry that signal (it's a different math + a
different mental model). Open question: build a separate hypo path or
rely on existing low-glucose alarms?

### 3c. True current-profile comparison in the calibration aggregator

The aggregator currently labels its delta as "vs profile-at-meal-time"
and compares against the first instance's `*AtActivation` snapshot.
Accurate when CR/ISF haven't shifted, slightly stale otherwise. Pull
today's profile via the `scheduledValueAt` helper (already exists for
per-instance fallback) for a true "vs current" comparison.

### 3d. Historical row backfill

Re-run `SavedMealOutcomeCalculator` on closed instances so the
pre-fix temp-basal-overlap bug rows get clean `totalInsulinDeliveredU`
values without the SMB-sum fallback path.

---

## 6. Verification path (inverse calibration + estimator guards)

1. Mark today's Sunday Breakfast as verified at the user's best guess
   (~95g). Check the per-instance Calibration section shows back-calc
   CR + ISF with % delta — both should be moderate-orange given the
   over-counted entered total (116g logged vs 95g real).
2. Trigger the live estimator on a future FP-light fast-carb meal —
   verify the prompt fires when BG is climbing and the loop is dosing.
3. Trigger on a future FP-heavy meal — verify FP guard fires
   `liveCarbsEstimateSuppressed { reason: "fpGuard" }` in telemetry
   for the first 60 min.
4. Mid-meal, when BG turns down, verify any pending banner auto-retracts
   and a `liveCarbsEstimateSuppressed { reason: "retracted" }` event
   lands.
5. After accepting a suggestion, verify no follow-up trigger fires
   against the just-accepted carbs (live carb sum is in play).
