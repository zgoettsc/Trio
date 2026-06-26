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

## 2026-06-26 (initial — first 3 hours of live data)

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
