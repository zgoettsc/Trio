# Companion features: plan and reasoning

Working notes for the features being built around this Trio fork: the Garmin
watch face and watch app, low alerts, one-tap logging, check-in prompts,
meal sizes, reason-aware overrides and personal insights.

- `WATCH_PLAN.md`: the watch face and watch app. This is the backbone and
  comes first.
- `COMPANION_FEATURES.md`: every feature idea, the problem it solves, the
  design, what was learned from testing, and the build order.

## Ground rules

- **This repository is public.** No health data here: no glucose, insulin
  or carb records, no personal statistics, no site addresses, no tokens or
  keys. The measurements behind these designs are kept in a private
  research repository; this folder describes designs and conclusions only.
- Work happens on branches with pull requests. The owner reviews, merges
  and builds. Nothing reaches a phone or watch until he builds it.
- Display, alerts and logging first. Anything that changes dosing needs the
  owner's separate go-ahead each time, with limits he has confirmed.
- Each feature is written as a self-contained piece (logic in one place,
  thin connection to Trio around it) so it can move to a separate app later.
- Negative results are recorded, not dropped.
