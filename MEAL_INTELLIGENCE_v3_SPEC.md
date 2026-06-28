# Meal Intelligence v3 — Spec & Shipped Features

Covers everything that landed after `MEAL_INTELLIGENCE_v2_SPEC.md` —
inverse CR/ISF calibration + a hardening pass on the live mid-meal
estimator that wraps the trigger in four context guards plus an
auto-retract for stale banners.

Keep in sync with the mirror in `docs/MEAL_INTELLIGENCE_v3_SPEC.md`
on the feature branch.

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

## 3. Open v3 items (not built)

### 3a. Meal tags

Lightweight characterization without macros — `chicken`, `rice`,
`large`, `fatty`, etc. Hybrid schema: structured dimensions (Size,
FatLevel, CarbType, ProteinType) for prediction logic + free-form
tags for browsing. Per-user aggregation drives carb-equivalent
predictions on fresh meals. See `BACKLOG.md §5` for full design,
risks, and phasing.

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

## 4. Verification path

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
