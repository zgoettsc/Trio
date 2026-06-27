# Meal Intelligence — Design Spec

**Status:** discussion / design — no code yet.
**Owner:** zgoettsc
**Last updated:** 2026-06-27

This document captures the agreed shape of an evolution of the eating-mode
feature. It builds on Rounds 1–9 of the FINDINGS.md telemetry log,
particularly Round 9 (Indian-food overnight) which exposed the structural
gap the design closes.

The user's north star is **zero carb entry**: the existing "I'm eating"
quick action stays the only required input on a normal meal. Everything
else — duration, aggressiveness, phantom-COB injection — is inferred from
BG pattern. Optional features (saved meals, macro entry) are *additive* for
users who want better priors, not required.

---

## 1. Goals & non-goals

### Goals

1. **Catch the late-fat phase** that the current fixed-duration window
   misses (Indian, pizza, Chinese-takeout, heavy creamy meals).
   Round 9 documented BG plateauing 220–240 for 3h after the meal window
   expired because the loop lost its boost right when fat absorption peaked.
2. **Stay one-tap on the input side.** The "I'm eating" quick action is
   the canonical entry point. No prompts, no required macro entry, no
   required carb-amount picker.
3. **Learn from history.** When a user does name a meal once
   ("Indian"), the app remembers the curve shape and uses it to seed
   smarter defaults next time, including pre-emptively scheduling phantom
   COB at the fat-onset time observed in past instances.
4. **Surface analytics.** Per-meal composite curves, key timing markers,
   insulin burden, classification history, outcome scores — all visible
   in-app and pushed to telemetry for retrospective analysis.

### Non-goals

- Not a meal-suggestion or food-recommendation engine.
- Not auto-bolusing without user opt-in. The existing bolus flow stays.
- Not ML or training. The classifier is a rule. The history table is a
  simple ring buffer. Both are explainable line-by-line.
- Not a replacement for entering macros when the user wants tight control.
  The flow is additive — macros, if entered, get richer storage and
  better predictions; if not, the curve alone is enough to learn from.

---

## 2. User flows

### 2.1 "I'm eating" — the default flow (no saved meals)

1. User taps the iPhone Action Button quick action.
2. Existing `mealWindowActivated` event fires; window opens at default
   duration (90 min, extends to 240 if a carb entry follows — current
   behavior, unchanged).
3. Live classifier starts running on every loop pass, may upgrade
   classification mid-window if a fat-onset pattern emerges.
4. Window closes at its current (possibly extended) duration. Existing
   `mealWindowExpired` / `mealWindowCancelled` summary writes.

No UI surface beyond the current eating-mode pill + Home banner.

### 2.2 "I'm eating" — with at least one saved meal

When `SavedMeal.count >= 1`, tapping the quick action presents a modal:

```
┌─────────────────────────────────────────┐
│  I'm Eating                             │
│                                         │
│   Quick (auto-classify)         [→]    │  ← default highlighted
│                                         │
│  Saved meals:                           │
│   🍛 Indian          12 ×        [→]   │
│   🍕 Pizza            5 ×        [→]   │
│   🥗 Salad            3 ×        [→]   │
│   🍣 Sushi            8 ×        [→]   │
│                                         │
│   + New meal                            │
└─────────────────────────────────────────┘
```

- **Quick:** identical to flow 2.1.
- **Saved meal pick:** window opens with that meal's seeded classification
  (e.g. Indian → Complex), extended duration, and phantom-COB schedule
  derived from history. SavedMealInstance row is started and linked to
  the new window.
- **+ New meal:** opens the meal-edit screen (flow 2.3); on save, returns
  to picker with the new meal selected.

The "skip" option (`Quick`) is always present and is the default
selection — confirms the user's "zero entry" path is preserved.

### 2.3 Create / edit / delete / duplicate meals

Settings → Meals lists all saved meals.

- **Tap [+ Add]:** form with name, icon (emoji), default macros (optional),
  default classification (optional — auto if blank).
- **Tap a meal row:** opens the **detail view** (flow 2.4).
- **Detail view header:** `[Edit] [Duplicate] [Delete]` actions.
  - Edit: same form as Add, prefilled.
  - Duplicate: copy with " (copy)" appended to name; no history.
  - Delete: confirm dialog; history rows are also deleted locally (but
    NOT from the telemetry branch — that's an immutable append-only log).

### 2.4 Meal detail view

```
🍛 Indian                          [Edit] [Duplicate] [Delete]
12 instances · last eaten 18h ago
─────────────────────────────────────────────

[All | Small (<40g) | Medium (40-80g) | Large (>80g)]   ← carb stratifier

╭─ COMPOSITE BG CURVE ─────────────────────╮
│ Overlay of 20 most recent instances      │
│ Bold = median, band = 25-75 percentile   │
│ X-axis: hours since meal start (0–10)    │
│ Y-axis: BG mg/dL                         │
│ Vertical markers: avg peak, avg trough,  │
│   avg late peak                          │
╰──────────────────────────────────────────╯

KEY TIMINGS (median)
  Initial peak:       +45 min @ 168 mg/dL
  Trough after peak:  +2h 10m @ 102 mg/dL
  Late peak (fat):    +5h 30m @ 220 mg/dL
  Return to baseline: +9h

BG AT CHECKPOINTS (median, range)
  +1h:   165  (148–180)
  +3h:   118  (95–155)
  +6h:   215  (180–245)
  +8h:   178  (140–210)
  +10h:  142  (125–160)

INSULIN BURDEN (per instance)
  Total delivered in window:    avg 8.2U  (range 5.1–11.0)
  SMBs fired:                   avg 32    (range 20–48)
  Floor activations:            avg 4     (range 1–9)

CLASSIFICATION HISTORY
  Auto-upgraded mid-window:     10 of 12 (83%)
  Avg upgrade time:             +2h 20m
  Recommended default:          Complex

OUTCOME (median)
  Time in range during window:  62%
  Peak BG:                      232
  Lows during window:           0
  Avg window duration used:     7h 15m

[Tap instance row →]                       last 20 instances:
  Jun 27  50c 30f   Medium→Complex@2h15m  TIR 65%  peak 240
  Jun 24  80c 60f   Complex (seeded)      TIR 58%  peak 248
  Jun 22  40c 25f   Medium                TIR 78%  peak 195
  ...
```

Stratifier defaults to "All" until ≥3 instances exist in a bucket. The
composite curve and stats then split per bucket.

Tapping an instance row opens its full BG trace + SMB/floor markers
(reuses existing Trio history viewer if possible).

---

## 3. Data model

All client-side storage is CoreData under the existing
`CoreDataStack.shared` context.

```swift
// CoreData entity — new
struct SavedMeal {
    let id: UUID
    let name: String                            // user-visible
    let icon: String                            // emoji, default "🍽️"
    let createdAt: Date
    let updatedAt: Date

    // Optional defaults — used when user picks this meal at quick-action
    // time. Each one can be nil → "let the classifier figure it out".
    let defaultCarbs: Decimal?
    let defaultFat: Decimal?
    let defaultProtein: Decimal?
    let defaultClassification: MealClassification?  // .simple/.medium/.complex
    let defaultExtendedDurationMinutes: Int?         // overrides global setting
    let defaultPhantomCOBEnabled: Bool?              // overrides global setting
    let defaultPhantomCOBGrams: Decimal?

    // Computed (re-derived on read from instances; cached here for picker speed)
    let cachedInstanceCount: Int
    let cachedRecommendedClassification: MealClassification?
}

struct SavedMealInstance {
    let id: UUID
    let savedMealId: UUID                       // FK to SavedMeal
    let windowId: String                        // FK to mealWindow row
    let startedAt: Date
    let closedAt: Date?

    // What the user told us at activation time
    let macrosAtActivation: MealMacros?         // carbs/fat/protein if entered

    // What the classifier did
    let initialClassification: MealClassification
    let finalClassification: MealClassification
    let classifierUpgrades: [ClassifierUpgrade]  // every Simple→Medium→Complex

    // BG trace + dose markers — captured from the per-loop telemetry stream
    let bgCurve: [BGSample]                     // 5-min resolution
    let smbsDuring: [SMBEvent]
    let floorActivations: [FloorEvent]

    // Computed outcome (filled after window close)
    let outcomeScore: Int?                      // 0–100, see §6
    let metrics: WindowMetrics?                 // TIR, peak, lowsCount, etc.
}

struct ClassifierUpgrade {
    let at: Date
    let from: MealClassification
    let to: MealClassification
    let trigger: String                         // "lateRiseDetected" etc.
    let bgAtTrigger: Double
    let minutesSinceActivation: Double
}

enum MealClassification: String, Codable {
    case simple, medium, complex
}
```

`SavedMeal` is small; `SavedMealInstance` is the row that grows. Cap
each meal at **20** most-recent instances locally (per user's choice).
Older ones are deleted from CoreData but already-pushed telemetry rows
remain on the remote branch — that's the long-term record.

### Lookup paths

- Meals list: `SavedMeal` sorted by `cachedInstanceCount` descending,
  then `updatedAt` descending.
- Picker: same as list, top 4–5 shown, rest behind "More".
- Detail view: join `SavedMeal` ← `SavedMealInstance` where
  `savedMealId == id`, last 20.
- Window-to-meal join: `SavedMealInstance.windowId` ↔
  `mealWindow.windowId`.

---

## 4. Classification system

### 4.1 The three-phase live classifier

Runs every loop pass while `mealWindowActive == true`. Reads from
`AlgorithmTelemetryLoopSample` history for the current window plus the
live oref output. Can **only upgrade** the classification, never
downgrade.

```
Phase 1 (carb absorption)
  Definition: BG has risen ≥ 15 mg/dL above activation BG within
              the first 60 min, OR sustained Δ > +2 for 3 readings.
  Effect:     Classification = Medium (if not already higher).

Phase 2 (carb-phase recovery — required gateway to Phase 3)
  Definition: Following a Phase 1 event, BG returns within ±20 mg/dL
              of activation BG AND remains there for ≥ 30 min.
  Effect:     No change to classification, but unlocks Phase 3 check.

Phase 3 (late fat/protein onset)
  Definition: After Phase 2 has been satisfied, BG begins rising
              again — sustained Δ > +2 for ≥ 15 min, no carb entry
              in the last 30 min (otherwise it's just a snack).
  Effect:     Upgrade to Complex.
              Extend window end-time by `complexExtensionMinutes`
              from the trigger point (default 240 min from trigger,
              capped at 600 min total since activation).
              Enable phantom-COB injection for the remainder of the
              window (default 20g, configurable).
              Log a `mealWindowClassifierUpgraded` event.
```

### 4.2 Defaults seeded from Round 9 / F-18

| Setting                                  | Default | Range allowed |
|------------------------------------------|---------|---------------|
| Phase 1 Δ-threshold                      | +2      | +1 to +4      |
| Phase 1 sustained reading count          | 3       | 2 to 5        |
| Phase 1 absolute-rise check (mg/dL)      | 15      | 10 to 30      |
| Phase 2 BG range from activation         | ±20     | ±10 to ±40    |
| Phase 2 minimum duration                 | 30 min  | 15 to 60      |
| Phase 3 Δ-threshold                      | +2      | +1 to +4      |
| Phase 3 sustained duration               | 15 min  | 10 to 30      |
| Phase 3 carb-entry exclusion window      | 30 min  | 15 to 60      |
| Complex extension after upgrade trigger  | 240 min | 120 to 360    |
| Maximum total window duration            | 600 min | 360 to 720    |
| Phantom COB injection on upgrade         | 20g     | 0 to 40       |

All exposed in **Settings → Meals → Classification Rules**, individually
tunable with the same Reset-to-Defaults pattern used by the existing
Eating Mode Tuning screen.

### 4.3 Walking the Round 9 Indian-food data through this rule

```
20:27 CT  Window activated, BG 137                  → Medium
20:36     BG 148, climbing +6                       → Phase 1 confirmed
21:21     BG 114, IOB drained                       → bottom
21:51     BG 87                                     → recovery
21:51     BG within ±20 of activation (137±20=117–157)? No, 87 < 117
                ↑ activation BG was 137 due to pre-meal climb; in this
                  case Phase 2 wants the post-bolus baseline.
                  → Tweak: Phase 2 baseline should be MIN of activation BG
                    and post-Phase-1 trough, not activation alone.
22:21     BG 98 (close to trough of 87, within range) ✓
22:21     30 min of stable around 87–98             → Phase 2 confirmed
22:41     BG 134, climbing                          → Phase 3 trigger
                ↑ UPGRADE TO COMPLEX at 22:41
                  → extend window from 23:30 → 02:41 next morning
                  → enable phantom COB
00:36     BG 220                                    → during extended boost
03:30     BG plateau ~240
                ↑ With original spec, window would expire at 02:41 — still
                  not far enough. The fat peak hits at ~5h. Spec needs:
                  → Phase 3 upgrade should set extension = max(240,
                    historical avg fat-peak time + 60 min) if a saved meal
                    is selected. For unnamed meals, default to 360 min
                    extension which covers most fat curves.
                  → Or always extend to maxTotalWindowDuration (600 min)
                    on Complex upgrade. Safer; user can cancel anytime.
```

**Open decision needed:** does Complex upgrade extend by a fixed amount or
push to max? See §10 Q1.

### 4.4 Saved-meal interaction with classifier

A saved meal with `defaultClassification = .complex` **seeds** the window
at Complex from the moment of activation — no need to wait for Phase 3.
The live classifier still runs but is effectively a no-op (already at
Complex, can only upgrade-not-downgrade).

For Phantom COB: a saved meal with `defaultPhantomCOBEnabled = true`
also enables it at activation, with `defaultPhantomCOBGrams` controlling
the dose. The dose can be derived from the saved meal's historical
late-peak magnitude in a future iteration.

---

## 5. Settings screen

### 5.1 New: `Settings → Meals` root

```
Meals
─────────────────────────────────────
Saved Meals                            [+ Add]
  🍛 Indian            12 ×           →
  🍕 Pizza              5 ×           →
  🥗 Salad              3 ×           →
  🍣 Sushi              8 ×           →

Classification Rules                   →    ← opens §5.2

Picker Behavior
  Show meal picker when ≥ 1 saved      ◉
  Always go straight to Quick           ○

Telemetry
  Upload meal instances to GitHub      ✓    ← opt-in; default ON
                                            ← writes to /meals/ subfolder
```

### 5.2 `Settings → Meals → Classification Rules`

Renders the 11 sliders from §4.2 with inline help and trade-off text.
Reset-to-Defaults button restores all to the seed values from F-18 data.

---

## 6. Outcome scoring

Each `SavedMealInstance` gets an auto-computed score 0–100 after the
window closes. No user rating required.

```
score = clamp(0, 100,
  100
  - (peakBG > 180 ? (peakBG - 180) * 0.3 : 0)        // every mg over 180 = -0.3
  - (lowsCount > 0 ? lowsCount * 20 : 0)             // each low = -20
  - (timeAboveRange > 30min ? overMinutes * 0.2 : 0) // every min over 30 = -0.2
  - (timeBelowRange > 0     ? underMinutes * 1.0 : 0)// every min under = -1.0
  + (timeToBaselineMin < 240 ? +5 : 0)               // fast recovery bonus
)
```

Tunable later. The scoring formula itself is checked into the codebase
(not a CoreData migration) so changes to the formula can be applied
retroactively to all stored instances on next open.

---

## 7. Telemetry pipeline (the asked-for full upload)

Per user request: every `SavedMealInstance` is pushed to the GitHub
telemetry branch, in addition to the existing event/loop/summary streams.

### 7.1 New paths

```
telemetry/YYYY-MM/DD/
  ├─ events.jsonl              (existing)
  ├─ loop.jsonl                (existing)
  ├─ summary.jsonl             (existing)
  ├─ settings.json             (existing — now includes savedMealCount)
  └─ meals.jsonl               ← NEW (one row per SavedMealInstance close)

telemetry/meals/
  ├─ definitions.json          ← NEW (snapshot of all SavedMeal rows;
  │                              rewritten on every meal create/edit/delete)
  └─ history/
      └─ <mealId>.jsonl        ← NEW (append-only per-meal instance log;
                                 mirrors meals.jsonl but indexed by meal
                                 for retrospective queries by meal name)
```

`meals.jsonl` in the daily folder uses the user's local-date partitioning
(consistent with the existing folder layout per round 8).

### 7.2 `meals.jsonl` row schema

```json
{
  "kind": "savedMealInstance",
  "instanceId": "uuid",
  "savedMealId": "uuid",
  "savedMealName": "Indian",
  "savedMealNamePrivate": false,
  "windowId": "uuid-of-the-meal-window",
  "startedAt": "2026-06-26T20:27:00-05:00",
  "closedAt": "2026-06-27T04:28:00-05:00",
  "deviceTimeZone": "America/Chicago",
  "macros": {"carbs": 50, "fat": 30, "protein": 0},
  "carbBucket": "medium",
  "initialClassification": "medium",
  "finalClassification": "complex",
  "classifierUpgrades": [
    {
      "at": "2026-06-26T22:41:00-05:00",
      "from": "medium",
      "to": "complex",
      "trigger": "lateRiseDetected",
      "bgAtTrigger": 134,
      "minutesSinceActivation": 134.0
    }
  ],
  "bgCurve": [
    {"t": 0,   "bg": 137},
    {"t": 5,   "bg": 137},
    {"t": 10,  "bg": 142},
    ...
    {"t": 480, "bg": 163}
  ],
  "smbsDuring": [
    {"t": 9,  "units": 0.75},
    {"t": 14, "units": 0.20},
    ...
  ],
  "floorActivations": [
    {"t": 14, "prior": 0.04, "floored": 0.152, "factor": 0.2}
  ],
  "outcomeScore": 65,
  "metrics": {
    "peakBG": 240,
    "timeInRangeMinutes": 297,
    "timeAboveRangeMinutes": 183,
    "timeBelowRangeMinutes": 0,
    "lowsCount": 0,
    "timeToBaselineMinutes": null,
    "totalInsulinDeliveredU": 8.2,
    "smbCount": 32,
    "floorActivationCount": 4
  },
  "buildSchema": 6
}
```

`bgCurve` rows use minutes-from-activation (`t`) for compactness and
sortability. Full BG resolution from the loop telemetry stream — every
5 min for the window's duration.

Estimated payload: 480-min window × ~140 bytes per BG sample + per-event
records ≈ 18 KB per meal instance. 10 meals/day = 180 KB/day. Acceptable.

### 7.3 `meals/definitions.json` schema

Rewritten in full whenever any saved meal is created, edited, or deleted.
Single JSON object keyed by mealId:

```json
{
  "lastUpdated": "2026-06-27T08:42:00-05:00",
  "deviceTimeZone": "America/Chicago",
  "meals": {
    "<mealId>": {
      "id": "...",
      "name": "Indian",
      "icon": "🍛",
      "createdAt": "...",
      "updatedAt": "...",
      "defaults": {
        "carbs": null,
        "fat": null,
        "protein": null,
        "classification": "complex",
        "extendedDurationMinutes": 480,
        "phantomCOBEnabled": true,
        "phantomCOBGrams": 20
      },
      "stats": {
        "instanceCount": 12,
        "recommendedClassification": "complex",
        "medianPeakBG": 232,
        "medianTimeInRangePercent": 62
      }
    },
    ...
  }
}
```

### 7.4 `meals/history/<mealId>.jsonl` schema

Append-only. Each row is identical to `meals.jsonl` rows but grouped by
meal for retrospective query convenience. Lets you `jq` all your Indian
meals across months without scanning every day's `meals.jsonl`.

### 7.5 Privacy controls

Meal names default to plaintext (they're your own labels). Setting:
`Settings → Meals → Telemetry → Anonymize meal names` → uploads them as
`"complex meal #1"`, `"complex meal #2"`, etc. instead. The mealId UUID
is always preserved so cross-day join still works.

### 7.6 Retention

Same as existing telemetry — 30-day local CoreData retention for
instances (matching the 20-instances-per-meal cap, whichever is more
restrictive). Remote branch is append-only; the existing 30-day remote
cleanup pass leaves `summary.jsonl` and `meals/` untouched (same rule
that already protects per-window summaries).

---

## 8. Outcome metrics deep-dive

`WindowMetrics`:

| Field                      | Definition                                     |
|----------------------------|------------------------------------------------|
| `peakBG`                   | max BG during window                           |
| `timeInRangeMinutes`       | minutes in 70–180 during window                |
| `timeAboveRangeMinutes`    | minutes > 180 during window                    |
| `timeBelowRangeMinutes`    | minutes < 70 during window                     |
| `lowsCount`                | count of distinct sub-70 episodes              |
| `timeToBaselineMinutes`    | minutes from peak back to within 20 of start   |
| `totalInsulinDeliveredU`   | sum of SMBs + basal-temp delta during window   |
| `smbCount`                 | count of `smbDelivered` events in window       |
| `floorActivationCount`     | count of `insulinReqFloorActivated` in window  |

Computed at window close from the existing loop-sample stream + events.
No new instrumentation needed — these are aggregates of data we already
log.

---

## 9. Size stratification implementation

Carb buckets:
- **Small:** total carbs < 40g
- **Medium:** 40–80g (inclusive lower, exclusive upper)
- **Large:** ≥ 80g

For an instance with no macros entered (zero-entry flow), the bucket is
inferred from estimated COB at the meal window's first 60 min — derived
from the BG response and existing oref COB calculation. Field marked
`carbBucketSource: "macros" | "inferred"` in the telemetry row.

Detail view's stratifier control:
- Shows `[All]` only if any bucket has fewer than 3 instances.
- Shows `[All | Small | Medium | Large]` once each bucket has ≥ 3.
- Defaults to the bucket matching the user's most recent instance.

---

## 10. Open questions

### Q1 — Extension policy on Complex upgrade

Two options for what happens when the classifier upgrades to Complex
mid-window:

- **A) Fixed extension from trigger point.** `extendedDurationMinutes`
  from the upgrade timestamp, capped at total window duration.
  Predictable, conservative.
- **B) Push to max total.** Always extend to `maxTotalWindowDuration`
  (600 min default) from activation. More aggressive coverage of the
  tail; user can cancel anytime via existing flow.

Round 9 data suggests B would have caught the full overnight curve
(fat peak hit at ~5h 30m, but BG plateaued through ~7h). A would have
left a 2h gap at the end.

**Recommendation:** B (push to max) for unnamed meals on Complex upgrade.
For saved meals, use `defaults.extendedDurationMinutes` if set, else B.
The user always has Cancel as the safety release.

### Q2 — When does classification get "locked"?

Right now spec is "upgrade-only". But what if user manually re-classifies
via the Live Activity pill? Should manual changes:
- Override the classifier (lock the manual choice; classifier no-ops)?
- Just set a new floor (classifier can still upgrade if user picked
  Simple but evidence shows Complex)?

**Recommendation:** manual choice sets a new floor for the classifier
(same upgrade-only rule applies, just starting from the user's pick).
User can always cancel to fully exit.

### Q3 — Phantom COB dose for Complex upgrade

Currently spec says 20g default at upgrade. Should:
- Stay 20g flat for all Complex upgrades?
- Scale with the magnitude of the late rise (bigger Δ → more phantom)?
- For saved meals, derive from historical late-peak data per meal?

**Recommendation:** flat 20g for v1, configurable per saved meal in v1
via `defaultPhantomCOBGrams`. Historical-derived in v2 once we have
enough instance data per meal.

### Q4 — Backfill of existing data into saved meals

User has been logging carb entries for months pre-feature. Should the
"create new meal" flow offer to backfill historical instances by matching
on a heuristic (e.g., similar carb/fat/protein within ±20%)?

**Recommendation:** v2 feature. v1 starts each saved meal at 0 instances;
history accumulates going forward.

### Q5 — Live Activity surface for classification

Currently the Live Activity shows the eating-mode pill. New design adds
classification awareness. Should the pill show:
- Just the classification ("Complex • 5h 12m left")?
- Classification + meal name when seeded ("Indian • Complex • 5h 12m")?
- Upgrade indicator briefly when classifier just upgraded ("⬆ Complex
  detected — extending")?

**Recommendation:** show meal name (if any) + classification + remaining
time. Briefly flash an upgrade banner for 30s when classifier upgrades.

---

## 11. Implementation order (when we get there)

Suggested sequencing — each phase usable on its own.

**Phase A: Live classifier on the existing flow.**
- Implement the 3-phase rule in APSManager / classifier service
- Add `Settings → Meals → Classification Rules` settings screen
- Add `mealWindowClassifierUpgraded` event to telemetry stream
- Hook into existing eating-mode window extension logic
- NO saved meals yet — just smarter behavior on the existing one-tap flow

This phase alone fixes the Indian-food problem documented in Round 9.

**Phase B: Saved meal CRUD + picker.**
- New CoreData entities `SavedMeal`, `SavedMealInstance`
- `Settings → Meals` list + add/edit/delete/duplicate
- Quick-action picker modal (appears when count ≥ 1)
- Link active window to a `SavedMealInstance` row
- Seed classification from `SavedMeal.defaultClassification`

**Phase C: Meal detail view + analytics.**
- Composite curve renderer
- Key timings + checkpoint table
- Outcome scoring computation at window close
- Stratification UI

**Phase D: Telemetry upload of meals.**
- `meals.jsonl` daily writer
- `meals/definitions.json` rewriter
- `meals/history/<mealId>.jsonl` append
- Settings toggle for anonymized meal names

Phase A is the highest-leverage shipping target — most of Round 9's
problem disappears with just that.

---

## Glossary

- **Meal window**: existing concept; the time period after "I'm eating"
  during which eating-mode aggression (items 1–6 from PLAN.md) is active.
- **Saved meal**: a named entity (e.g., "Indian") with defaults and history.
- **Saved meal instance**: one occurrence of eating a saved meal; linked
  to a meal window 1:1.
- **Classification**: simple / medium / complex — drives window
  duration and Phantom COB enablement.
- **Classifier upgrade**: in-window transition between classifications,
  upgrade-only.
- **Phase 1/2/3**: the three-phase rule for detecting late-fat onset.
- **Carb bucket**: small/medium/large bin used for size-stratified
  analytics in the detail view.
- **Phantom COB**: virtual carbs injected into oref's mealCOB to keep
  the loop dosing through fat absorption; previously gated behind the
  PLAN.md item 5 toggle.
