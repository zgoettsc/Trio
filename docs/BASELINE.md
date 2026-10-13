# Baseline freeze (plan step S0.1)

The baseline is the dosing behaviour that every later change is compared
against. It is defined by three things: the commit the phone is running, the
settings on the phone, and the JavaScript bundle that commit ships.

## 1. Code

| Item | Value |
|---|---|
| Baseline commit (assumed) | `6e3277848` "Telemetry: emit tagNames on carbEntry + rescueCarbsLogged events" — the tip of the default branch before the algorithm-redesign work began |
| Tag | `baseline-live-2026-10` (to be pushed once the owner confirms the installed build's commit from Settings → Build Details) |
| oref provenance | `oref0_source_version.txt`: trio-oref dev @ 8282ce7 |

If the installed build is a different commit, move the tag before anything
else uses it and update this table.

## 2. JavaScript bundle hashes at the baseline commit

SHA-256 of `Trio/Resources/javascript/bundle/*.js` (identical at `6e3277848`
and on this branch; the redesign work does not touch the bundle):

| `autosens.js` | `353f8c146397130237db235a3329a75c98e23f8d0d1315d17c63ce9c2029c654` |
| `autotune-core.js` | `62ea9705a0f3e137bcc5ae3e1df0f4a568740be372666261c1d78a3a7995cf10` |
| `autotune-prep.js` | `646c0d7f76c937062523cdef9c27f903c8409e9b50a8b87da2e7f1593f729f82` |
| `basal-set-temp.js` | `4805465be5042267f4c9bf67516e08ff5878bed056d2f3c9bb927d2f436ed4a8` |
| `determine-basal.js` | `b683580a605c914d165c77814127b3ceb2dec021568bfdf4dd18368ccc97f09b` |
| `glucose-get-last.js` | `6a5dad61a1d3a46d6f56f786bb38293f583d14dd995d9580f971da4db5087994` |
| `iob.js` | `b141ea4dce5042c45882d776d754d3eb9ebd9b99a418d774c024f4d84613762b` |
| `meal.js` | `29eea6cbf68621352b966b62b29eb3e16d13a75fe900bfc5d48b001d861fa6d8` |
| `profile.js` | `486871b53b7f2977d87415ded73094c1575dab0ac7d7f4c267b2aceb657944d8` |

The prepare wrappers (`Trio/Resources/javascript/prepare/*.js`) are loaded as
source, not bundled. Their hashes at the baseline commit:

| `prepare/autosens.js` | `55cb6f8c4e343400d525e4463e2e7053a2e0e36ebcdd15376f3a519b07534f56` |
| `prepare/determine-basal.js` | `47719c3632265ff249d82db883fbe93dd0b8986c7df1c7ea9f4f5f0692ecdd35` |
| `prepare/iob.js` | `c5d68501a9305d46869b664da798d145bce38aaa93909c869fbf72738d5d0177` |
| `prepare/meal.js` | `1268f3d5c088e28302753da9e2cbc128acfdaf2139dd81c69999ed5f73f84f0c` |
| `prepare/profile.js` | `53b25623a6a980ae4be1410c87b3bf62112ab29abdda67ca2030c4d0921df9a2` |
| `prepare/log.js` | `f4acd5a559591031bd600754e14ced13dddc7596410ad770072f1b8ebe15e2ef` |

`scripts/check-bundle-parity.sh` (added in S0.2) recomputes these and fails if
the app's copy and the AlgorithmKit package's copy of the bundle differ.

## 3. Settings snapshot (owner action, not yet done)

Export from the phone and store under `~/TrioLab/baseline/` (not in the
repository, see `docs/PRIVACY.md`), with a `MANIFEST.sha256`:

- Settings → Settings Export (share sheet) → `trio-settings-export.json`
- The FileStorage documents listed in plan 0(d): `preferences.json`,
  `settings/profile.json`, `settings/pumpprofile.json`,
  `settings/basal_profile.json`, `settings/insulin_sensitivities.json`,
  `settings/carb_ratios.json`, `settings/bg_targets.json`,
  `freeaps/freeaps_settings.json`, `settings/therapy_profiles.json`.

A partial, dated reference exists in the `telemetry` branch
(`telemetry/<YYYY-MM>/<DD>/settings.json`, schedules + algorithm preferences
as of that day). It is not a substitute for the export because it omits the
preferences the JS reads (`max_iob`, curve, dynamic ISF settings, thresholds).

## 4. Baseline behaviour definition

`JSOrefCore` evaluating the bundle above, with the settings snapshot, and with
`trio_custom_oref_variables` exactly as recorded per loop. Any run of the
replay harness that reports a difference from a recorded loop's output at this
commit is a harness bug until proven otherwise.
