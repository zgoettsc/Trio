# Trio Telemetry — Running Findings

A living log of patterns observed in the telemetry data, organized newest-first.
Each entry records what was looked at, what's new, and what's confirmed or
contradicted from prior entries. Lets analysis accumulate over time without
re-deriving the same observations each visit.

**Update protocol:** when adding a new section, scan prior `Active findings` and
mark each as still-true (✓), no-longer-present (✗), modified (~), or
insufficient-data-this-round (—). Move any clearly-stale items to `Retired
findings` at the bottom.

---

## 2026-06-26 round 4 (CRITICAL retrospective — JS never shipped before now)

**Discovery while reviewing round 3 data:** the `effectiveSmbDeliveryRatio`,
`floorBehavior`, and other per-loop "applied" fields were nil on EVERY loop
pass — even during active meal windows. Investigation found that the app's
algorithm loads from `Trio/Resources/javascript/bundle/determine-basal.js`
(a minified webpack bundle), NOT from `trio-oref/lib/determine-basal/`
where I had been editing. Per `trio-oref/oref_source_file_info.txt`:

> *"These source files are copied from upstream and are for information
> purposes only. The algorithm is run based on minimised files in
> Trio/Resources/javascript/bundle."*

**What this means for prior findings:** every JS-side claim I made from
rounds 1–3 was running on STOCK upstream oref. No floor was ever in the
bundle. No SMB ratio boost. No enableSMB meal-window branch.

The only meal-window behavior the user actually experienced was the
**Swift-side toughMealActive auto-engage** from OpenAPS.swift, which
fires the existing tough-meal cap multipliers (1.5×/2×/2.5×) in stock
oref. Plus the UI plumbing — Action Button, meal window state, Live
Activity pill, Home banner. Those all worked.

### Findings that need to be re-assessed once the rebuilt bundle ships

- **F-1** (floor dormant during well-bolused meals): **tautological** in
  retrospect. The floor wasn't in the bundle. Re-assess after round 5.
- **F-2** (rising guard suppressing at delta≈0): **moot** until round 5.
- **F-5** (215 peak from late bolus): was running stock oref, not the
  loop with meal-window enhancements. Re-evaluate after the rebuilt
  bundle is deployed.
- **F-6** (insReq healthy but throttled by 0.5 ratio): stock oref's
  behavior. Item 1 (boost to 0.8) was never live. Re-evaluate.
- **F-7** (~30 min COB-registration lag): stock oref's behavior. Phantom
  COB (item 5) was never live either.

### What this round shipped

Commit `59d7fd11f` on the working branch: re-ran the webpack build from
trio-oref/lib via `scripts/webpack.config.js`, copied
`dist/determineBasal.js` into
`Trio/Resources/javascript/bundle/determine-basal.js`. The bundle now
contains all the meal-window code from the past three rounds.

### Process improvement

Going forward, any JS change must be followed by:

```
cd trio-oref && npm install     # one-time
npx webpack --config ../scripts/webpack.config.js
cp dist/determineBasal.js ../Trio/Resources/javascript/bundle/determine-basal.js
```

Worth adding an Xcode build phase or CI step to do this automatically.
Until that's in place I'll do it manually on every JS-touching commit.

### What to watch in round 5

Once the rebuilt bundle deploys:
- Loop sample's `effectiveSmbDeliveryRatio`, `effectiveMaxSMBBasalMinutes`,
  `floorBehavior`, etc. should populate on every loop pass during active
  meal windows. If they're still nil, the bundle didn't deploy or
  decoding is broken.
- A meal during an active window should show genuinely different
  behavior than rounds 1–3. Specifically: more aggressive SMBs.
- `rT.mealWindowFloor` should populate when the floor activates.

If a meal that previously hit peak 215 now hits e.g. 180, that's the
ship working. If it's still 215, we have a different problem (e.g.,
the current tuning settings aren't aggressive enough; revisit item 3 or
item 5 opt-in).

---

## 2026-06-26 round 3 (PLAN.md items 1-6 ship)

**Data window:** code change only — no new telemetry data analyzed this
round. Ships the eating-mode aggression package described in PLAN.md.

### Shipped this round

Implementation of the six aggression items (commit `8a66c0ae7` on the
working branch). Each item is independently toggleable from the new
**AI Insights → Eating Mode Tuning** screen. Default behavior:

- **Item 1 (default ON)** SMB delivery ratio bumps from 0.5 to 0.8
  whenever the meal window is active, not just when the floor rescued.
- **Item 2 (default ON)** Floor's rising guard relaxed from `delta > 0`
  to `delta > -2`. Should catch the 17:56-18:06 round-1 scenario
  (F-2/F-6) where BG hovered near zero delta.
- **Item 4 (default ON)** `enableUAM` forced true during window.
- **Item 6 (default ON)** `maxSMBBasalMinutes` and
  `maxUAMSMBBasalMinutes` doubled (45→90) inside the window.
- **Item 3 (default OFF)** Additive floor mode plumbed; opt-in.
- **Item 5 (default OFF)** Phantom COB plumbed; opt-in. Requires the
  user enables it AND mealCOB < 15 AND BG positive-delta-and-rising
  before injecting.
- **75% tough-meal cap (default 75 unchanged)** now configurable via
  the same screen — exposed so we can raise to 90% if item 1's effect
  is being clipped by the cap.

### Telemetry additions

New per-loop columns in `loop.jsonl` capturing what was *actually
applied* this pass (from oref's `rT.mealWindowApplied`):
`effectiveSmbDeliveryRatio`, `effectiveMaxSMBBasalMinutes`,
`effectiveMaxUAMSMBBasalMinutes`, `effectiveToughMealCapPercent`,
`floorBehavior` (`"off"` / `"replacement"` / `"additive"`),
`forcedUAM`, `phantomCOBGrams` (0 if not injected),
`relaxedRisingGuard`.

New fields in daily `settings.json`: the 9 tuning settings'
current configured values.

New event kind in `events.jsonl`: `mealWindowTuningChanged` —
emitted per-field when any of the 9 settings change, with
`{field, oldValue, newValue}`.

### Hypothesis status

- **H-1** (floor will fire on poorly-bolused meals): **— still no
  data**. Need a meal where the user under-doses to test.
- **H-2** (relax rising guard to `delta > -2`): **shipped as item 2,
  default on.** Effectively closed unless we observe regressions.
- **H-3** (bump smb_delivery_ratio whenever window active, not just
  when floor fires): **shipped as item 1, default on, value 0.8.**
  Closed pending validation. Watch for the round-2 215-peak scenario
  to be improved.
- **H-4** (detect late-bolus shape): **— deferred**. Not addressed by
  this round's changes. Still relevant.

### What to watch on the next data round

- **Compare to round 2's 215 peak.** A similar meal with the new
  ratio + multiplier active should peak lower. Item 1 + 6 are the
  load-bearing ones for that scenario.
- **Floor activation rate.** With item 2 active, expect more
  activations in flat-delta moments. Look at `floorBehavior` column
  in loop.jsonl to count.
- **Item 5 / phantom COB** stays off until we see a few weeks of
  outcomes with items 1+2+4+6 active.
- **Tuning-change events** — verify the screen actually flips
  settings and the events fire as expected.

### Status of prior findings

- **F-1** (floor dormant during well-bolused meals): **✓ still
  expected**. Item 1's ratio boost may surface more SMBs even when
  the floor stays off; F-1's "floor doesn't fire" observation still
  holds, but the loop's behavior in well-bolused meals should be more
  active overall.
- **F-2** (rising guard suppresses at delta≈0): **addressed by item 2.**
  Hypothesis closed pending validation.
- **F-3** (manual-bolus + window = happy path): **upgraded** — should
  now extend to "manual-bolus + window + new tuning" being even
  happier.
- **F-4** (carbEntry `enteredBy: "Trio"`): **✓ unchanged**.
- **F-5** (late-bolus 30min gap → peak 215): **partially addressed by
  items 1, 6.** The bolus delay itself remains a user-behavior issue,
  but the loop will react faster within the window now.
- **F-6** (loop's insReq healthy but throttled by 0.5 ratio):
  **directly addressed by item 1.** Plus the cap is now tunable if
  the 75% ceiling clips the boost.
- **F-7** (~30 min COB-registration lag): **addressable by item 5
  (phantom COB), but item 5 ships default off.** Watch this lag in
  more data; if it's the dominant blocker for late-bolus scenarios,
  consider turning item 5 on.

---

## 2026-06-26 round 2 (snack-during-window through ~3h post-bolus)

**Data window:** 26 events (10 new), 73 loop rows (32 new), through 20:56Z.
First meal-window from round 1 still active (extended 4h post-carbsConfirmed
expires 21:21Z). One additional snack happened inside that window, with a
late bolus. No outcome row yet.

### New findings

#### F-5 — Late-bolus pattern: 40g entered at 18:49, 3.15U bolused 30 min later → peak 215

**Observation:** Second carb entry at 18:49 (40g) without a co-timed bolus.
The 3.15U manual bolus didn't land until 19:19, ~30 min after the carbs.
Result: BG climbed 153 → **215** between 19:11 and 20:21 (peak ~60 min after
late bolus, peak time-above-180 ≈ 30+ min).

During the rise (19:46–20:11), the loop *did* fire SMBs (0.30 + 0.10 + 0.50
+ 0.30 + 0.20 = 1.40U), but the rise outran them.

#### F-6 — Loop's insulinReq was technically "correct" but insufficient — floor wouldn't have helped

**Observation:** At every loop pass during the 19:46–20:11 climb, the
loop's own `insulinReq` was already ≥ what the floor would have computed.
Example at 19:46: existing insReq=0.61 vs. computed floor at
`(172-95)/75 × 0.3 = 0.31`. So `floor < insReq` → floor stays dormant
(correct by its own rules), but the existing 0.61 × 0.5 ratio = 0.30U SMB
wasn't enough to blunt a +10 mg/dL/5min rise.

**Implication:** The floor rescue solves one failure mode (insReq→0
collapse). It does NOT address the late-bolus / under-dosed-meal mode
where insulinReq is healthy but `smb_delivery_ratio = 0.5` halves it and
`maxSMBBasalMinutes = 45` caps the absolute size. New hypothesis below.

#### F-7 — Apparent COB-registration lag (~30 min) between carb entry and oref's COB reflecting it

**Observation:** Carb entry at 18:49 (40g). Loop pass at 18:51 (2 min later)
showed COB=38, insReq=-0.18. Through 19:16 (27 min later), COB hovered at
30–32 (still draining from meal 1). Only at 19:19 (when the bolus event
landed) did COB jump to 69 — and that's the SUM of both meals' undrained
COB.

**Interpretation:** Either (a) oref's COB drain logic doesn't immediately
reset when new carbs are entered, or (b) the bolus event triggers a
re-evaluation of COB. Worth investigating in the oref JS path. If (a),
this is a meaningful gap: 30 minutes where the loop didn't know there were
40g of fresh carbs.

### Active hypotheses (open or updated)

- **H-1** (floor will fire on poorly-bolused meals): **— insufficient data still**.
  Both meals had front-loaded boluses where insReq stayed positive. Need a
  meal where the user skips/under-doses the bolus to test.
- **H-2** (relax floor's rising guard to delta > -2): **— not the right
  intervention based on F-6**. The floor's rising guard wasn't the blocker
  this round — `insReq > floor` was. Need to rethink: relaxing the guard
  would let floor fire more, but at insReq=0.61 the floor adds nothing.
- **H-3** (bump smb_delivery_ratio during meal windows): **upgraded to a
  priority hypothesis based on F-5/F-6**. If smb_delivery_ratio had been
  0.8 during the 19:46–20:11 climb, SMBs would have been 0.49+0.21+0.80+
  0.52+0.35 ≈ 2.37U vs the actual 1.40U. That extra ~1U over 25 min could
  have meaningfully blunted the rise. The change is: bump
  `smb_delivery_ratio` to 0.8 *whenever* the meal window is active, not
  just when the floor itself is rescuing. Currently the bump only happens
  inside the floor-active branch.
- **H-4 (NEW)** — Detect "late-bolus shape" (rapid carb entry without a
  bolus within X minutes) and apply stronger SMB treatment. Need carb-to-
  bolus latency stats from more meals.

### Status of prior findings

- **F-1** (floor dormant during well-bolused meals): **✓ confirmed** — also
  true for the second meal/snack. Floor never fired in 47 loop passes across
  two meals, both of which had front-loaded boluses keeping `insReq > floor`.
- **F-2** (floor's rising guard suppressing at delta≈0): **— not retested**.
  Round 2's failure mode was different (F-6); the rising-guard concern from
  round 1 (17:56–18:06 segment) didn't reproduce because BG was being
  actively driven down by the prior bolus.
- **F-3** (manual bolus + window flag as happy path): **~ modified** — works
  great for the first meal but the snack-during-window pattern (no Action
  Button re-press, no second bolus until 30 min after the carbs) is a worse
  outcome. The window being already active didn't help when the bolus was
  late. Suggests the window's bigger value is the carb-entry → loop-knows
  signal, less than the floor itself.
- **F-4** (carbEntry `enteredBy: "Trio"`): **✓ confirmed** — both carb
  entries this round also have `enteredBy: "Trio"`.

### What to watch on the next round

- A meal where you DON'T manually bolus (or under-bolus) — that's the regime
  the floor was built for and we haven't seen it yet.
- Carb-to-bolus latency stats across more snacks (validate F-7 + H-4).
- The outcome-summary row for the first meal will be written ~6h after the
  21:21Z window expiry, so look for it around 03:21Z tomorrow.
- The override/temp-target columns will appear in loop.jsonl once the build
  with commit 106b1a110 is deployed.

---

## 2026-06-26 round 1 (initial — first 3 hours of live data)

**Data window:** 8 pushes between 15:35Z and 18:25Z. 41 loop rows. 16 events.
1 meal-window activation with full lifecycle (activate → carbsConfirmed → close).
No outcome row yet (waiting on +6h tail).

**Settings context:** target 95 flat. ISF schedule 60/75/58. CR flat 13.
Basal schedule: 1.0 → 0.85 @ 5am → 1.4 @ 6am → 0.8 @ 8am → 1.4 @ 6:30pm.
maxIOB 10, smbDeliveryRatio 0.5 (default), maxSMBBasalMinutes 45.

### New findings

#### F-1 — Floor doesn't fire during well-bolused meals (intended behavior, confirmed)

**Observation:** Single observed meal (17:22Z, 70g carbs + 4.15U manual bolus,
peak BG 163, well below 180). `floorActivated: false` on all 14 loop passes
during the active window. `insulinReq` stayed between 0.10 and 0.85 throughout
the rise — never collapsed to 0. Loop fired modest SMBs (~1.35U total on top
of the manual bolus).

**Why it matters:** The floor is by design a safety net — it only kicks in
when `insulinReq` would otherwise collapse to 0 (the bayesian-COB-drain
failure mode from the original analysis). A front-loaded manual bolus gives
oref a healthy context where its own math works fine; the floor correctly
stays dormant. ✓ working as designed.

**Watch for:** Will the floor fire on meals where you don't manually bolus, or
under-bolus? That's the regime it was built for. Need 5+ examples of that
pattern to validate.

#### F-2 — Floor's "rising" guard may be too strict at delta=0

**Observation:** At 17:56–18:06 (post-bolus, mid-rise), BG was 150 → 158 →
157 → 162 but `delta5m` swung negative-to-flat-to-positive (-1, +1, +4) and
`eventualBG` dropped to 76–85 (the bayesian-COB-drain pattern). `insulinReq`
went negative (-0.25 to -0.13). Floor did NOT fire because the JS requires
`glucose_status.delta > 0 OR short_avgdelta > 0`. With delta hovering near 0,
the guard suppressed activation.

**In this meal it didn't matter** — total dose was 5.5U front-loaded and BG
peaked at 163. But in a less-well-bolused scenario, this is where the floor
would matter most and it'd still be suppressed.

**Hypothesis to test:** Relax to `delta > -2 OR short_avgdelta > 0`. Or use
the Kalman `velocity` (which was +0.7 mg/dL/min at 17:56) instead of oref's
discrete delta. Need to see more meals (especially poorly-controlled ones)
before deciding.

#### F-3 — Manual bolus + window flag is the current happy-path pattern

**Observation:** User's working pattern in this session: press Action Button
→ enter real carbs in-app → tap manual bolus → loop adds SMBs as needed. End
state: well-controlled meal.

**What this tells us about the feature's value:** The meal-window's main
benefit so far is the *plumbing* (the loop knows a meal is happening,
toughMealActive auto-engages, SMBs can fire even without enableSMB conditions
met). The floor's insulinReq-rescue is a secondary safety net that hasn't
been exercised yet. Both are wins, but the floor's specific value needs more
data to quantify.

#### F-4 — One unexpected `carbEntry` event from `enteredBy: "Trio"`

**Observation:** The 70g carbEntry has `"enteredBy": "Trio"` (not user
identity). Worth confirming this is the expected attribution string for
in-app carb entries vs. AI Insights / external sources. Not a problem, just
something to know for filtering later.

### Active hypotheses (open)

- **H-1:** Floor will fire on poorly-bolused meals — needs ≥3 examples.
- **H-2:** Relaxing the floor's rising guard to `delta > -2` would catch
  more genuine meal-rise scenarios. Test by counting "missed activations"
  in the data (BG rising slowly during active windows without floor firing).
- **H-3:** smbDeliveryRatio 0.5 is conservative — bumping during meal
  windows might shorten time-above-target. Currently only the floor-active
  branch bumps to 0.8. Worth measuring.

### Status of prior findings

(none — first entry)

---

## Retired findings

(none yet)

---

## Findings index by feature area

- **Floor activation rules:** F-1, F-2, H-1, H-2
- **SMB delivery ratio:** H-3
- **Carb entry attribution:** F-4
- **Meal-window UX:** F-3
