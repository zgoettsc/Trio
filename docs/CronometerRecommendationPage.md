# Cronometer Meal Recommendation Page — Full Reference

This document describes every section and interactive element on the Cronometer Meal Recommendation page in Trio. This page appears when a Cronometer meal is detected via Apple Health delta tracking.

---

## 1. Late Meal Warning Banner (Conditional)

**When it appears:** Only when you select a past meal from the meal picker (i.e., you're dosing late).

| Element | Description |
|---------|-------------|
| Time ago | "Late Dose — 25 min ago" |
| Warning severity | Mild (15–30 min), Moderate (30–45 min), Severe (45+ min) |
| Absorbed % | How much of the carbs have already been absorbed (exponential decay model) |
| Carbs remaining | Adjusted for decay |
| Fat/protein % | Shows 100% if within 60 min (fat/protein hasn't started yet) |

---

## 2. BG Prediction Chart

A real-time glucose chart showing the predicted effect of the recommended dosing.

| Element | Description |
|---------|-------------|
| Green band | Target range (70–180 mg/dL) |
| Colored dots | Last ~2 hours of CGM readings. Red < 70, Green 70–180, Orange > 180 |
| Dashed blue line | Predicted BG curve from oref simulation (5-min intervals, 3h forward) |
| Large dot | Current BG with value label |
| Diamond marker | Eventual BG prediction with color coding |
| Bottom row | "Eventual: X mg/dL" and "Min: X mg/dL" labels |

---

## 3. Actual Nutrition (Cronometer) — Orange Section

Raw values from Cronometer via Apple Health delta detection. These are unmodified nutrition values.

| Element | Description |
|---------|-------------|
| Carbs card | Total carbohydrates (g) |
| Fat card | Total fat (g) |
| Protein card | Total protein (g) |
| Calories card | Total calories |
| Detection time | When the meal was detected |

---

## 4. Recommended Entry — Green Section (Interactive)

What Trio recommends entering into the bolus calculator. Macro values are scaled from raw Cronometer values.

| Element | Description |
|---------|-------------|
| Three macro cards | Scaled carbs/fat/protein, showing "of X" if reduced from raw |
| Factor button | Top-right. Tapping reveals the factor editor |

### Factor Editor (Toggle Open/Close)

| Element | Description |
|---------|-------------|
| Lock/Unlock toggle | Locks the factor so auto-learning stops. When locked, slider changes persist. When unlocked, the system adjusts the factor from meal outcomes |
| Factor slider | Range 0.20 to 1.50, step 0.05. Controls what fraction of Cronometer carbs to enter. Lower = less insulin. Default ~0.5 means "enter half of what Cronometer says" because Cronometer tracks total nutrition but not all of it raises BG equally for your body |
| "Apply New Factor" button | Appears when you've changed the slider from its current value |

---

## 5. V2 Split Dosing — Cyan Section (V2 Only, Interactive)

Only appears when V2 Macro Absorption Engine is enabled in settings. Controls how the meal bolus is split between upfront delivery and delayed SMBs.

| Element | Description |
|---------|-------------|
| High-fat warning (orange) | When fat > 5g, shows the fat-modified tau value |
| Curve explanation | What % the gamma CDF calculated and the safe window duration |
| Upfront % slider | 0–100% with 5% steps. White reference mark at curve-suggested value |
| Real-time preview | "X% (Yg = Z.ZU)" updates as you slide |
| High-fat warning (red) | Appears when slider exceeds 1.5x the curve suggestion |
| Split summary | "Xg Bolus now → Yg Via SMBs" |

### How Split Dosing Works

The V2 engine uses a Gamma(2, tau) CDF to determine what fraction of carbs will be absorbed within the "safe window" (30 min for ultra-rapid insulin, 45 min for rapid-acting). This fraction becomes the upfront bolus; the rest is delivered via SMBs as future carb entries for oref.

Fat slows gastric emptying: each gram of fat adds 0.8 minutes to the base tau. The base tau is tunable in V2 settings (default 35 min). A 30g fat meal with default tau shifts from 35 to 59 min, reducing the upfront % and spreading more carbs into the future.

---

## 6. Fat/Protein Units — Purple Section

Shows the FPU (Fat-Protein Unit) calculation summary for the delayed macronutrient effects.

| Element | Description |
|---------|-------------|
| Total carb-equivalents | Combined glucose-equivalent from fat + protein |
| Duration | How many hours the loop will deliver via SMBs |
| Equation | "Xg fat + Yg protein = Zg carb-equiv over Nh" |
| Total coverage | "Xg upfront + Yg delayed = Zg equivalent" |

### The Three-Curve Model (V2)

The V2 engine models three distinct physiological pathways:

**Curve 1 — Carbohydrate Absorption (Gamma-shaped):**
- Gamma(2, tau) distribution where tau is fat-modified
- Base tau tunable via **Carb Tau** slider (default 35 min, range 20–60)
- Duration: tau * 4.74 minutes to 95% absorption
- Entries generated every 10 minutes after the safe window

**Curve 2 — Protein Gluconeogenesis (Delayed Sigmoid):**
- Onset at ~3 hours (sigmoid center), peak at ~5 hours, decay after
- Smooth ramp: 0% conversion at ≤threshold, linear to max factor at plateau
- All three parameters tunable via sliders:
  - **Protein Factor**: peak conversion rate (default 0.35, range 0.10–0.80)
  - **Protein Threshold**: minimum grams for effect (default 15g, range 5–30g)
  - **Protein Plateau**: grams at which conversion maxes out (default 40g, range 20–80g)
- Entries generated every 15 minutes from 90–480 min (1.5–8h)

**Curve 3 — Fat Insulin Resistance (Normalized Gaussian):**
- Gaussian centered at 6 hours, sigma = 90 minutes
- No effect before 2 hours (FFA elevation hasn't started)
- **Fat Coefficient** tunable via slider (default 0.69, range 0.30–2.00 g-carb-equiv per g-fat)
- Entries generated every 15 minutes from 120–540 min (2–9h)

### Protein and Fat Coefficients — Literature Basis

The default coefficients are based on published research:

| Parameter | Default | Source | Notes |
|-----------|---------|--------|-------|
| Fat coefficient | 0.69 g-equiv/g-fat | Wolpert 2013 | 42% more insulin for 50g fat on 65g carb meal. Range: 17–124% across individuals |
| Protein factor | 0.35 max conversion | Gluconeogenesis pathway | 35% of protein grams converted to glucose. Does not account for glucagon-driven glycogenolysis |
| Protein threshold | 15g | Clinical observation | Below this, gluconeogenesis effect is negligible |
| Protein plateau | 40g | Saturation kinetics | Above this, conversion rate plateaus at max factor |

**Important:** These are population medians. Individual variation is large. The V2 settings page provides sliders to tune all four protein/fat parameters, plus the carb tau, to match your personal physiology.

---

## 7. Similar Meal Insights — Teal Section (Conditional)

Only shows when you have past meal outcomes with similar macros. Powered by the outcome learning system.

| Element | Description |
|---------|-------------|
| Match count | "Based on N similar past meals" |
| Confidence badge | High / Medium / Low / None |
| Expected BG trajectory | Predicted BG at 1h, 2h, 3h, 4h, 6h from past similar meals |
| Peak BG and Rise | Expected peak and total BG increase |
| Suggested dosing | Effective ICR from similar meals, suggested bolus in units |
| Learned macro entry factors | Carb/fat/protein as % |
| FPU equivalent | From suggested entry |
| Top Matches | Up to 3 most similar past meals with date, carbs, peak BG, and similarity % |

---

## 8. Learning History — Indigo Section (Conditional)

Shows your overall track record with Cronometer recommendations.

| Element | Description |
|---------|-------------|
| Tracked | Total meals tracked |
| In Range | How many had BG in range at checkpoints |
| Clean | Meals with no lows or highs in the observation window |
| Avg Peak | Average peak BG across all tracked meals |
| Explanation | "Factor adjusts automatically based on BG outcomes at +2h, +4h, +6h, +8h, +10h..." |

---

## 9. Action Buttons

| Element | Description |
|---------|-------------|
| "Apply to Bolus Calculator" (green) | Populates the bolus calculator with the recommended carbs (upfront only for V2), fat, and protein |
| Summary text | V2 shows split dosing breakdown, V1 shows FPU summary |

---

## V2 Settings — Curve Parameter Tuning

The V2 Macro Dosing settings page (Settings → V2 Macro Dosing) provides direct sliders for the five core curve parameters. These parameters are also learned automatically by the outcome learning system when enabled.

| Setting | Default | Range | What It Controls |
|---------|---------|-------|-----------------|
| Fat Coefficient | 0.69 | 0.30 – 2.00 | g-carb-equivalent per g-fat. Higher = more delayed insulin for fat |
| Protein Factor | 0.35 | 0.10 – 0.80 | Peak fraction of protein converted to glucose |
| Protein Threshold | 15g | 5 – 30g | Minimum protein grams before gluconeogenesis kicks in |
| Protein Plateau | 40g | 20 – 80g | Protein grams at which conversion plateaus at max factor |
| Carb Tau | 35 min | 20 – 60 min | Base time constant for carb absorption curve. Higher = slower absorption |

When outcome learning is enabled, these values are refined automatically from your meal BG outcomes:
- **Early error (0–2h)** adjusts carb tau
- **Mid error (2–5h)** adjusts protein factor
- **Late error (4–9h)** adjusts fat coefficient

Manual slider adjustments set a starting point; the learning system fine-tunes from there.

The settings page also includes a **live example calculation** section that shows how the current slider values would process a reference meal (65g carbs, 28g fat, 35g protein). This updates in real-time as you adjust sliders, showing protein glucose-equivalent, fat carb-equivalent, total delayed impact, and fat-modified tau.

A **Reset Curve Parameters to Defaults** button clears all learned/manual values back to the research defaults.

---

## Key Design Decisions

### Why V2 Does Not Use `individualAdjustmentFactor` for Protein/Fat

The V1 Warsaw Method uses `individualAdjustmentFactor` (default 0.5) to scale all FPU carb-equivalents. In V2, this factor is **not applied** to the protein and fat physiological coefficients because:

1. The V2 coefficients (0.35 protein factor, 0.69 fat coefficient) are already calibrated from research
2. Applying a 0.5 multiplier on top would halve the already-conservative values (effective protein = 0.175, fat = 0.345), producing entries too small to matter
3. V2 has its own tuning mechanism — the five curve parameters — which can be adjusted via sliders or outcome learning
4. The `individualAdjustmentFactor` continues to scale the Cronometer → recommended entry mapping (the "Factor" in the green section), which is the correct place for personal carb scaling

### References

- Wolpert et al. 2013 — *Dietary Fat Acutely Increases Glucose Concentrations and Insulin Requirements in Patients With Type 1 Diabetes*
- Smart et al. 2013 — *Both Dietary Protein and Fat Increase Postprandial Glucose Excursions in Children With Type 1 Diabetes*
- Bell et al. 2016 — *Optimized Mealtime Insulin Dosing for Fat and Protein in Type 1 Diabetes*
- Bell et al. 2020 — *Amount and Type of Dietary Fat, Postprandial Glycemia, and Insulin Requirements in Type 1 Diabetes*
- Paterson et al. 2016 — *Influence of Pure Protein on Postprandial Blood Glucose Levels in Individuals With Type 1 Diabetes Mellitus*
