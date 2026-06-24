# Upstream sync (Zack-Trio-Copy ← nightscout/Trio v0.8.3) — remaining work

Status: 10 of 14 conflicts resolved on Windows and pushed. This file is a working
note — **delete it before merging Zack-Trio-Copy back into Zack-Trio.**

## Already resolved & pushed (Windows)
- Gemfile, .github/workflows/build_trio.yml, Info.plist (config)
- DecimalPickerSettings.swift, Router/Screen.swift (additive)
- History module adopted from upstream; DataTable module removed
- Garmin watchface (GarminWatchState + GarminManager) adopted from upstream
  (your Firestore Garmin services + SmartSense are separate and preserved)
- CarbRatioEditor + ISFEditor DI (kept your profileManager + upstream's tidepool/broadcaster)

## Remaining — do on macOS with Xcode

### A. project.pbxproj  ← do this FIRST (Xcode won't open until it's marker-free)
Strategy: take upstream's project file, then re-add your custom files in Xcode.

```bash
git checkout upstream/main -- Trio.xcodeproj/project.pbxproj
```
Then open Trio.xcworkspace in Xcode and drag these folders/files into the matching
groups (File ▸ Add Files, "Create groups", target = Trio; tests → TrioTests):

RE-ADD (genuine your-features):
- Modules/AIInsightsConfig/            (11 files — Claude AI features)
- Services/SmartSense/                 + Models/SmartSenseModels.swift, MealDecisionLog.swift
                                       + Modules/Treatments/View/SmartSenseSummaryView.swift
                                       + Modules/Settings/View/Subviews/SmartSenseSettingsView.swift
- Services/Garmin/                     + Models/GarminContextSnapshot.swift
                                       + Modules/Settings/View/Subviews/GarminFirestoreStatusView.swift
- Services/ProfileManager/             + Models/TherapyProfile.swift, ProfileSwitchEvent.swift
                                       + Views/ProfileSwitchBannerView.swift
- Modules/TherapyProfileEditor/  Modules/TherapyProfileList/
- Modules/PhysioTesting/               + APS/Storage/PhysioTestStorage.swift
                                       + Models/PhysioGlucoseReading.swift
                                       + Modules/Home/HomeStateModel+Setup/PhysioTestSetup.swift
                                       + Modules/Home/View/Chart/ChartElements/PhysioTestOverlayView.swift
- APS/SignalProcessing/                (10 files — your Kalman/oref pipeline)
- Services/HealthKit/                  + Models/HealthMetrics.swift, NutritionSnapshot.swift
- Models/Weekday.swift                 + Views/WeekdayPickerView.swift

DO NOT re-add (upstream deleted these on purpose — verify your code doesn't need them,
then leave them out / delete from working tree):
- APS/CGM/DexcomSourceG5.swift, DexcomSourceG6.swift, LibreTransmitterSource.swift
  (replaced by upstream's plugin CGM architecture)
- Models/Autotune.swift, Models/FetchedProfile.swift
- Helpers/SavitzkyGolayFilter.swift   (check: does your SignalProcessing still use it?)

### B. Three Swift conflicts (let the compiler verify each)

**TrioSettings.swift** — keep BOTH (your SmartSense settings + upstream's Garmin display settings):
- Property block (~line 88): keep both sides (your `smartSenseSettings` + upstream's
  garmin properties and `garminSettings`). Just delete the 3 conflict-marker lines.
- decode(from:) block (~line 416): keep both, but your smartSense `if let` needs its
  own closing brace. Result should read:
  ```swift
  if let smartSenseSettings = try? container.decode(SmartSenseSettings.self, forKey: .smartSenseSettings) {
      settings.smartSenseSettings = smartSenseSettings
  }
  // ...then all of upstream's requireAdjustmentsConfirmation / garmin* if-let blocks...
  ```

**TreatmentsStateModel.swift** — keep BOTH (delete markers):
- ~line 195: keep `bolusProgressCancellable?.cancel()` + `cronometerMealDetector?.stopObserving()`
  AND `lifetime = Lifetime()`
- ~line 226: call both `await self.setupSmartSense()` AND `self.setupLastBolus()`

**TreatmentsRootView.swift**:
- ~line 27: keep both — your photo-carb `@State` vars + `aiInsightsState` AND upstream's
  `showFatProteinOrderBanner` (delete markers).
- ~line 113: keep YOUR Protein TextField + toughMeal block (upstream's side is empty here).
  Build and eyeball the meal-entry screen for any duplicate protein UI from upstream's banner.

### C. Submodules
```bash
rm -rf OmniBLE OmniKit                 # orphaned dirs from submodules upstream removed
git submodule sync --recursive
git submodule update --init --recursive
```
If submodule init complains, check .gitmodules for duplicate entries (TidepoolService.branch,
DanaKit.path/url, MedtrumKit.branch/url) and remove the dupes. Upstream's pump submodules
are OmnipodKit / MedtrumKit / MinimedKit.

### D. Build, fix, test
Build in Xcode. Expect compile errors where your custom features call upstream APIs that
changed (SignalProcessing/oref hooks, ProfileManager wiring in ServiceAssembly, SmartSense).
Fix iteratively. Run the app.

### E. Adopt (only when it builds & runs)
```bash
git rm MERGE_NOTES.md && git commit -m "Remove merge notes"
git checkout Zack-Trio
git merge Zack-Trio-Copy
git push origin Zack-Trio
```
Zack-Trio is untouched until this final step. zack-trio-backup is your fallback.
