# Companion features: ideas, reasoning and status

Each entry gives the problem, the design, and what testing showed. The
tests were run on the owner's own record in a private research repository;
this public file states conclusions without personal figures. "Replay"
means re-running history with a different rule; replay results are not
evidence of real-world performance.

Status key: **idea**, **measured** (tested on the record), **agreed**
(direction settled with the owner), **built**.

## Build order

1. Watch face and watch app running reliably (see `WATCH_PLAN.md`).
2. One-tap rescue logging (2).
3. Leveled low alert (1).
4. Hold-off countdown after a rescue (3).
5. Check-in prompt (9, 13) with meal entry by size and speed as labels (10).
6. Reason-aware overrides, starting with "cautious overnight" (12).
7. Personal insights, starting with a fixed report (6).
8. Dosing-side changes (4, 11, the dosing parts of 12 and 13): only after
   the research algorithm's clean test, each with the owner's go-ahead.

---

## 1. Leveled low alert (replaces "carbs required") — measured

**Problem.** The carbs-required notification reasons from a worst case: all
active insulin acts in full, with absorbing food and the current trend
ignored. On the record it was false most of the time, fired mainly after
meal boluses, and gave advance notice of only a minority of real lows.

**Requirements (owner).** No gram figure: a severity level instead. Stay
quiet when the loop will recover the situation by itself. A budget of two
to three alerts a day. A different level of annoyance per level.

**Design.**
- Level 1, heads up: falling, may go low in 15 to 30 minutes. Silent
  banner or watch tap.
- Level 2, recommend eating: a low is more likely than not. Sound.
- Level 3, eat now: a fast fall at an already lowish level (for example,
  down more than 20 in one reading at around 90). Fires on a single
  reading. Worded as a fall, not as a prediction of a severe low.
- One episode escalates through the levels and does not repeat. Quiet once
  recovering or once a rescue is logged.
- Time to low is shown as a range.
- Settings: glucose ceiling, projection target, readings in a row, sound
  per level.

**Why it should work.** Tuning the alert on what actually happened with
the loop running teaches it to stay quiet where zero temps are enough:
every low in the record is one the loop did not prevent.

**Findings.** Within the alert budget, the first level reaches most lows
with useful notice and the second is rarely a wasted alert. In replay with
the user eating when warned, low episodes fell substantially at about two
warnings a day. Insulin on board added nothing over glucose level and trend
for levels 1 and 2. "Deceleration" (change of the drop between readings)
and "growing drops in a row" never improved any rule; drop size, readings
in a row and a short projection carry the information.

**Blind spot.** Lows the user prevents by eating look like false alarms.
Feature 2 fixes that.

## 2. One-tap rescue-carb logging, on the watch — idea

**Problem.** Carbs eaten to treat a low are not logged: too much effort.
Without that log a treated drop cannot be told from a false alarm, and a
rebound cannot be told from an unannounced meal.

**Design.** One tap on the watch or phone logs a rescue with a preset.
Rescue carbs are never counted or dosed for. This fork already has
phone-side rescue presets hidden from the dosing model
(`RescuePreset.swift`); the missing piece is making it effortless and
watch-based.

**Why first.** Features 1, 3, 4 and 6 all need it.

## 3. "Carbs are working" hold-off after a rescue — idea

**Problem.** Treating on the way down, seeing no response, eating more,
then spiking. On the record the first 15 minutes after the bottom of a low
are typically slow, which is when it feels as if nothing is working, and a
meaningful share of lows are followed by a high.

**Design.** After a rescue is logged, a countdown: when it was eaten, when
to expect the turn, and the condition for eating more (still dropping fast,
or below a set level, after the window). A clear "eat more" signal if the
fall has not slowed, so the hold never leaves the user stuck. Later: learn
the user's own rescue response by food.

## 4. Rebound-aware dosing — idea (dosing; after the clean test)

**Problem.** A sharp rise after a treated low looks like an unannounced
meal. Dosing it early and hard turns one low into two. On the record a
noticeable share of the sharpest rises started shortly after a low, and a
second low was much more common after those than after other spikes.

**Design.** Treat a sharp rise that starts soon after a low, or after a
logged rescue, as a probable rebound and withhold the early, aggressive
dosing.

## 5. Confirmed-rise trigger and what glucose alone can do — measured

Wait for a confirmed rise before dosing harder; allow more when glucose is
higher; ease off once a meal looks half absorbed. From glucose alone,
catching most sharp unannounced rises takes several triggers a day, about
half of them for rises that fizzle, and nothing fires before glucose is
already clearly up. Acceleration terms added nothing. An earlier signal has
to come from outside the sensor trace: a label from the user (9, 13) or
another sensor (7).

## 6. Personal insights — idea

**Request (owner).** The analysis of his own patterns was the most useful
information he has had; the app should do it. It should be able to look at
any time range, find near-term and long-term patterns, and give guidance.

**Examples of the kind of statement.** How lows typically go and recover;
what share of spikes follow a treated low; how variable meal absorption is;
how overrides are actually used and what they cost; how an alert has
performed; before-and-after for a settings change.

**Principles.** Every statement shows its numbers, the period and how many
events it rests on, with small samples labelled. It reports patterns and
options and does not change dosing or settings. Findings that fail a check
are shown as such. Health data stays where the user keeps it.

## 7. Earlier meal signal from outside the sensor — idea, parked

Wrist motion at the first bites, or a second sensor. Parked.

## 8. Overnight protection without an override — measured

A protective override is set on most nights. In replay the research
algorithm matched the overnight low rate without one. To be confirmed on
fresh data.

## 9. Rise check-in on the watch: "did you eat?" — measured; a labelling feature

**Idea.** When a rise is detected with nothing logged, prompt on the watch
with one-tap answers.

**Findings.** On a sizeable share of meals the prompt would have fired well
before the carbs were entered. But moving the bolus to the prompt time gave
no meaningful average gain in closed-loop replay, under either the research
algorithm or this fork's settings: the loop is already dosing the rise.
**Negative result for dosing.** The prompt's value is the label, in the
cases where the loop is not free to react (13). Budget: up to five prompts
a day if they are real and answerable on the watch; one prompt per episode.

## 10. Meal entry by size and speed, no numbers — agreed

**Idea (owner).** People classify meals better than they count carbs.

**Findings.** Almost all his entries were already round numbers, and a
handful of amounts made up most of them. Three size classes explained the
insulin a meal turned out to need at least as well as the entered grams;
four classes added nothing. Meal size, however entered, explains only a
small part of the need.

**Design: two taps.**
1. Size: small / medium / large.
2. Speed: fast (simple carbs such as candy) / normal / slow (pizza, Indian
   food, a sub).

Nine combinations is the ceiling; no further options on the meal screen.

## 11. Up-front dose per meal size, with guardrails — measured (dosing; needs go-ahead)

**Idea (owner).** Tapping a size gives an up-front dose inside a fixed range
per size that the app can never leave; within the range the dose may be
shaped by glucose level, trend and insulin on board.

**Findings.** A simple dose per size sits where an up-front dose should: an
amount that most meals of that size go on to need anyway, with the rest
added as the rise shows what the meal was. In replay, size doses recovered
most of the benefit of the owner's own boluses; adjusting for level and
trend inside the ranges was slightly better than fixed doses. Small meals
carried the most lows afterwards, so the small dose stays small.

**What speed changes.** Fast: most of the dose now, ease off early. Slow: a
smaller share up front, the rest held until the rise shows, keep expecting
the meal for two to three hours. Any speed entered while low or falling:
log now, dose when it shows.

**Guardrails.** A minimum and maximum per size set by the owner, on top of
the global limits. Only he changes them.

## 12. Reason-aware overrides — agreed (direction)

**Idea (owner).** Say why the override is being set; get a plan that steps
over the expected period; approve it; extend, step down or stop by
check-ins tied to glucose.

**Design.**
- A short fixed reason list, with "other" typed once and then joining the
  list: cautious overnight; exercise or active day; illness; steroid or
  other medication; stress or poor sleep; alcohol; other.
- A proposed schedule of steps with the expected end and the basis for each
  step. The user's own labelled history outranks the general pattern.
- Nothing starts without approval; any step can be edited first.
- The app may step down or end early by itself; it may never step up or
  extend without the user. No indefinite option above 100%. Bounds on the
  highest percentage and the longest stretch without a check-in.
- The proposal shows its uncertainty and starts conservatively. Medical
  situations also prompt "check with your care team".

**"Cautious overnight".** One tap before bed; a milder protective setting;
returns to normal settings by itself once glucose has levelled off (flat,
not falling, little insulin on board). On the record the protection matters
for roughly the first two hours while the override usually runs most of the
night; lows cluster before glucose settles. The low alert comes first,
because ending early gives up some protection on a minority of nights.

## 13. Context-aware check-in: one prompt, the right actions — idea

**From a real day.** Food eaten while low and entered hours later; a quick
first rise that was dosed; a fall back toward low; the main rise much later
with insulin on board negative and a protective override just tightened.
Absorption and insulin were out of step in both directions.

**Design.** One prompt, each answer one tap:
- "Ate": size and speed (10); up-front dose inside the guardrails (11), or
  "log now, dose when it shows" if low or falling.
- "Rescue carbs": hold-off countdown (3), gentle handling (4).
- "Didn't eat": label only.
- "Turn off override?": shown when a reducing override is active while
  glucose is rising fast. Needs the tap, because ending it increases
  delivery.
- After a recent low the prompt says so and asks: rescue or a meal?
- While a logged meal is still expected, warn before the user makes an
  override more protective.

**Why it matters.** The gain from a prompt is in the cases where the loop
is held back or should hold back: after a low, under a reducing override,
on a rebound. Those are label problems, and one tap supplies the label.
