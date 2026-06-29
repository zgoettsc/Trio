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

## 5. Rescue carbs — "I'm low, don't dose for this" (SHIPPED — commit pending)

The pattern: BG drops → user eats juice → user logs the carbs (so
analytics stays accurate) → oref sees new COB → dosed insulin against
the rescue → BG over-corrects → low again → eat more juice → cycle.

The workaround until now was "don't log the carbs," which protects
the loop but destroys the record of what you actually ate. This
feature lets you log AND tell the loop to ignore.

### Schema

`CarbEntryStored` gets two new fields:

| Field | Type | Purpose |
|---|---|---|
| `isRescueCarbs` | Bool (default NO) | Excludes the row from oref's meal.json + estimator math |
| `rescuePresetName` | String? | Name of the preset used (nil if custom) — lets analytics stratify recovery curves by what was eaten |

`CarbsEntry` struct mirrors both fields with backward-compatible
optional defaults. New `enteredBy` tag: `"Trio-RescueCarbs"`.

### Filtering — where the exclusion fires

| Site | Behavior |
|---|---|
| `OpenAPS.fetchAndProcessCarbs` | Uses new `predicateForOneDayAgoExcludingRescue` so rescue rows never reach `meal.json` → oref's COB calculation is blind to them |
| `APSManager.sumCarbsSinceWindowOpen` | Filters `isRescueCarbs == YES` so the live-estimator's "carbs already modeled" baseline + the auto-phantom-COB shadow accumulator both exclude rescues |
| `APSManager.sumFatProteinSinceWindowOpen` | Same filter — keeps the FP-guard math clean |

Rescue rows stay in CoreData. They flow into telemetry's `events.jsonl`
via `carbEntry` AND a dedicated `rescueCarbsLogged` event. They show
in History. They're just hidden from the dosing pipeline.

### Curated presets

`RescuePreset` struct stored as a user-customizable array on
`TrioSettings.rescuePresets`. Defaults shipped: juice box, glucose tabs
(×4 and ×3), Skittles, jelly beans, granola bar, banana, honey, apple
juice, Smarties roll. Each entry has name + carbs + optional fat +
optional protein + emoji + notes.

### UI

New **Rescue** button on the Treatments toolbar (red tint, shield icon).
Tap → `RescueCarbsSheet` opens:

1. **Picker** — list of presets. Tap one → preview with editable
   carbs/fat/protein → confirm.
2. **Custom** path at bottom — type macros directly.

Save writes the carb entry with `isRescueCarbs = true`, fires
`rescueCarbsLogged` telemetry, triggers a fresh `determineBasal` so
the loop's state refreshes immediately.

### Telemetry

New event kind `rescueCarbsLogged`. Payload:

| Field | Notes |
|---|---|
| `carbs` | grams logged |
| `fat` / `protein` | only present if user entered (nil ≠ 0) |
| `presetName` | string if from preset, null if custom |
| `custom` | bool — convenience flag |
| `bgAtLog` | latest BG at the moment of logging |
| `duringMealWindow` | true if a meal window was active when rescue fired (signals likely over-bolus context) |

Because the payload carries the preset's effective macros at the
moment of logging, the row is self-contained — even if the user
later edits or deletes the preset, the event still describes what
was actually eaten. No need to snapshot the full preset library.

### Per-preset analytics (the long-term payoff)

With enough events, analysis can answer:
- Does a granola bar produce a longer, more durable recovery than
  jelly beans? (FP delay benefit)
- Do glucose tabs over-correct more often than juice?
- What's the median BG-recovery curve per preset (BG at +15 / +30 / +60 min)?

The recipe in `ANALYSIS_METHODS.md §Analysis 11` joins
`rescueCarbsLogged` events to subsequent BG samples and groups by
`presetName`.

### Files

- `Model/.../contents` (CarbEntryStored: `isRescueCarbs` + `rescuePresetName`)
- `Model/Classes+Properties/CarbEntryStored+CoreDataProperties.swift`
- `Model/Helper/NSPredicates.swift` (new `predicateForOneDayAgoExcludingRescue`)
- `Trio/Sources/Models/CarbsEntry.swift` (new fields + `Trio-RescueCarbs` tag)
- `Trio/Sources/Models/RescuePreset.swift` (NEW; defaults == [], user seeds the library)
- `Trio/Sources/Models/TrioSettings.swift` (`rescuePresets` field)
- `Trio/Sources/APS/Storage/CarbsStorage.swift` (persist new fields)
- `Trio/Sources/APS/OpenAPS/OpenAPS.swift` (exclusion predicate)
- `Trio/Sources/APS/APSManager.swift` (estimator helpers filter rescues)
- `Trio/Sources/Modules/Treatments/View/RescueCarbsSheet.swift` (NEW; empty-state + "Manage rescue presets" link into the nav stack)
- `Trio/Sources/Modules/Treatments/View/TreatmentsRootView.swift` (Rescue toolbar button)
- `Trio/Sources/Modules/AIInsightsConfig/View/RescuePresetsConfigView.swift` (NEW — settings UI for add / edit / delete / reorder; pushed from both AI Insights nav and the Rescue picker)
- `Trio/Sources/Modules/AIInsightsConfig/View/SavedMealPickerView.swift` ("Manage saved meals" link into the same nav stack as the picker)
- `Trio/Sources/Modules/AIInsightsConfig/View/AIInsightsConfigRootView.swift` (Rescue Presets nav entry)
- `Trio/Sources/Services/AlgorithmTelemetry/AlgorithmTelemetryEvent.swift` (new event kind)

### Picker CRUD (user-discoverability)

Both the Treatments → Meals picker (`SavedMealPickerView`) and the
Treatments → Rescue picker (`RescueCarbsSheet`) have a **"Manage …"**
row that pushes the corresponding full-CRUD config view into the
sheet's existing `NavigationView` stack. Saves the user from
dismissing the sheet, navigating into Settings, editing, and
re-opening. Used right where the friction actually lives.

---

## 6. Verified macros — fat + protein (SHIPPED — commit pending)

The inverse calibrator's math today uses carbs only, but verified
macro composition is high-value data for future work — does effective
CR vary with FP load? does Trio's FPU expansion match real BG impact?
Capturing it now (cheap) lets those analyses run as soon as enough
verified meals accumulate.

### Schema

`SavedMealInstance` gets two new optional fields:

| Field | Purpose |
|---|---|
| `userVerifiedFatAmount` | grams; nil means "did not verify" — NOT zero |
| `userVerifiedProteinAmount` | grams; nil = "did not verify" |

The nil-vs-zero distinction matters: a meal with zero fat IS NOT the
same as a meal whose fat content the user didn't verify. Telemetry +
analytics must preserve that distinction.

### UI

`VerifyCarbsSheet` gets a new "Other macros (optional)" section with
two empty fields. Defaults blank, NOT 0. Inline footnote:
> Leave blank if you don't know — blank means "unverified", NOT zero.
> Inverse-calibration math only uses carbs today, but these get stored
> so future analysis can study how macro composition shapes BG response.

When fat/protein are verified, they show in the verified-summary
section beneath the verified carb amount.

### Telemetry

`mealCarbsVerified` event payload extended with optional
`verifiedFat` and `verifiedProtein` fields. Only included when user
provided them.

### Files

- `Model/.../contents` (`userVerifiedFatAmount`, `userVerifiedProteinAmount`)
- `Model/Classes+Properties/SavedMealInstance+CoreDataProperties.swift`
- `Trio/Sources/Modules/AIInsightsConfig/View/SavedMealInstanceDetailView.swift` (sheet + display)

---

## 7. Garmin + pod-site-age context at meal activation (SHIPPED — commit pending)

Trio already pulls a rich Garmin context (`GarminContextSnapshot`)
via Firestore — sleep, HR, HRV, stress, body battery, recent activity
intensity, VO2 max, fitness age — used today by SmartSense for
dosing. We now capture the same snapshot into telemetry at meal
activation, plus hours-since-last-pump-rewind (pod site age). Lets
analysis correlate sensitivity-affecting context with per-meal
outcomes: does HRV-suppressed-overnight predict bigger excursions?
does pod day 3 vs day 1 shift effective CR?

### Schema additions

`SavedMealInstance` gets two new fields:

| Field | Type | Purpose |
|---|---|---|
| `garminContextAtActivationJSON` | String? | Whole `GarminContextSnapshot` serialized at activation. JSON keeps the schema flexible — future Garmin field additions don't require a Core Data migration |
| `pumpSiteAgeHours` | NSNumber? | Hours since the most recent `PumpEventStored` row with `type == "rewind"`. Nil when no rewind history available |

`SavedMealTelemetryRow.ActivationContext` (meals.jsonl) gets the same
two fields. Build schema bumped from 10 → 13.

### Capture path

In `AnnounceMealIntentRequest.announce(...)`:

1. **Pod age** — `PumpSiteAge.hoursSinceLastRewind(now:)`. Synchronous,
   fast (single CoreData query, fetchLimit=1). Always computed; no
   privacy gate (not personal health data).
2. **Garmin** — `fetchGarminContextJSONWithTimeout(seconds: 1.0)`.
   Async with hard 1-second timeout via `withTaskGroup`. **The dosing
   path must not block on a slow Firestore round-trip** — if Garmin
   doesn't respond in 1s, proceed with `garminContextJSON = nil` and
   the meal window opens on schedule. Gated by `telemetryIncludeGarmin`.

Both values flow into:
- `SavedMealStorage.startInstance(...)` → stored on the instance row
- The `mealWindowActivated` event payload (pod age top-level, plus
  a curated subset of Garmin fields as `garmin_*` keys for grep-
  friendly analysis)

### Daily Garmin snapshot

New `garmin.jsonl` file in the telemetry tree, one row per day.
Written from `maintainDailySnapshot` as a fire-and-forget task. Each
row: `{ timestamp, deviceTimeZone, snapshot: <full GarminContextSnapshot> }`.
Lets analytics build long-term trends (sleep, HRV, training load)
independent of meal-window timing. Gated by `telemetryIncludeGarmin`.

### Privacy gate

`TrioSettings.telemetryIncludeGarmin` (Bool, default **ON**). User-
exposed in `TelemetryConfigView` with an inline explainer about
what personal health data the gate covers. When off:

- No `garmin_*` keys in `mealWindowActivated` payload
- `garminContextAtActivationJSON` stays nil on instance rows
- `garmin.jsonl` writer skips (file isn't created)
- Pod site age STILL flows (not personal data, direct dosing relevance)

This matches the principle that the user opts in to sharing personal
health context separately from opting in to operational telemetry.

### Files

- `Trio/Sources/Models/TrioSettings.swift` (`telemetryIncludeGarmin`)
- `Model/.../contents` (SavedMealInstance fields)
- `Model/Classes+Properties/SavedMealInstance+CoreDataProperties.swift`
- `Trio/Sources/APS/PumpSiteAge.swift` (NEW)
- `Trio/Sources/APS/Storage/SavedMealStorage.swift` (startInstance signature)
- `Trio/Sources/Shortcuts/Meal/AnnounceMealIntentRequest.swift` (capture + timeout helper)
- `Trio/Sources/Services/AlgorithmTelemetry/SavedMealTelemetryRow.swift` (ActivationContext fields)
- `Trio/Sources/Services/AlgorithmTelemetry/AlgorithmTelemetryManager.swift` (populate fields, daily Garmin writer)
- `Trio/Sources/Services/AlgorithmTelemetry/AlgorithmTelemetryLogger.swift` (.garmin file kind + writer)
- `Trio/Sources/Modules/AIInsightsConfig/View/TelemetryConfigView.swift` (privacy toggle)

### Verification path

1. Verify pod-age is in `mealWindowActivated` event payload on the
   next meal activation — `payload.pumpSiteAgeHours` numeric value
   (matches `(now - last rewind) / 3600`).
2. With `telemetryIncludeGarmin` ON: verify `garmin_*` keys are
   present in the same payload (resting HR, stress level, sleep
   score, etc.). Verify `garminContextAtActivationJSON` is set on
   the SavedMealInstance row after activation.
3. Toggle `telemetryIncludeGarmin` off → next activation should
   have pod-age but no `garmin_*` fields, and no JSON on the
   instance row.
4. After 24h of app usage with the toggle on: `garmin.jsonl` should
   appear under today's `telemetry/<YYYY-MM>/<DD>/`.

---

## 8. Open v3 items (not built)

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

## 9. Verification path (inverse calibration + estimator guards)

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
