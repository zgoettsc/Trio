'use strict';
// Synthetic, generic loop inputs for the Node harness and for AlgorithmKit golden tests.
// Deliberately NOT the owner's settings: a flat, ordinary adult profile.
// Every scenario is a pure function of (clockMs, options) so fixtures are reproducible.

const fs = require('fs');
const path = require('path');

const DEFAULTS_DIR = path.resolve(__dirname, '../../Trio/Resources/json/defaults');

function readJSON(rel) {
  return JSON.parse(fs.readFileSync(path.join(DEFAULTS_DIR, rel), 'utf8'));
}

const iso = (ms) => new Date(ms).toISOString();

function settingsDocuments(overrides = {}) {
  const preferences = Object.assign(readJSON('preferences.json'), {
    max_iob: 6,
    enableSMB_always: true,
    enableUAM: true,
    maxSMBBasalMinutes: 30,
    maxUAMSMBBasalMinutes: 30,
    smb_delivery_ratio: 0.5,
    threshold_setting: 60,
  }, overrides.preferences || {});

  const pumpSettings = { insulin_action_curve: 6, maxBolus: 10, maxBasal: 4 };
  const bgTargets = { units: 'mg/dL', user_preferred_units: 'mg/dL', targets: [{ low: 100, high: 100, start: '00:00:00', offset: 0 }] };
  const isf = { units: 'mg/dL', user_preferred_units: 'mg/dL', sensitivities: [{ sensitivity: 50, offset: 0, start: '00:00:00' }] };
  const carbRatio = { units: 'grams', schedule: [{ start: '00:00:00', offset: 0, ratio: 10 }] };
  const basalProfile = overrides.basalProfile || [{ start: '00:00:00', minutes: 0, rate: 1.0 }];
  const tempTargets = [];
  const model = '722';
  const trioData = readJSON('freeaps/freeaps_settings.json');
  return { preferences, pumpSettings, bgTargets, isf, carbRatio, basalProfile, tempTargets, model, trioData };
}

// 72 readings, 5 minutes apart, newest first (the order the app sends).
function glucoseSeries(clockMs, shape = 'flat', { ageOfNewestMin = 2 } = {}) {
  const out = [];
  for (let i = 0; i < 72; i++) {
    const t = clockMs - (ageOfNewestMin + 5 * i) * 60000;
    const minutesAgo = ageOfNewestMin + 5 * i;
    let bg;
    switch (shape) {
      case 'flat': bg = 110; break;
      case 'rising': // 100 → ~190 over the last 90 min, flat before
        bg = minutesAgo >= 90 ? 100 : Math.round(100 + (90 - minutesAgo));
        break;
      case 'steepRise': // +12 mg/dL per 5 min over the last 30 min: trips the 20%-of-BG delta lockout at ~BG 120
        bg = minutesAgo >= 30 ? 100 : Math.round(100 + (30 - minutesAgo) * 2.4);
        break;
      case 'falling': // 140 → 70 over the last 60 min
        bg = minutesAgo >= 60 ? 140 : Math.round(140 - (60 - minutesAgo) * (70 / 60));
        break;
      case 'high': bg = 220; break;
      default: throw new Error('unknown shape ' + shape);
    }
    out.push({
      date: t,
      dateString: iso(t),
      sgv: bg,
      direction: 'Flat',
      type: 'sgv',
      id: `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`,
    });
  }
  return out;
}

// Pump history newest first, as the app sends it (24h window).
function pumpHistory(clockMs, { bolusUnitsAgoMin = null, tempBasals = [] } = {}) {
  const events = [];
  if (bolusUnitsAgoMin) {
    const [units, minAgo] = bolusUnitsAgoMin;
    const t = clockMs - minAgo * 60000;
    events.push({ _type: 'Bolus', id: 'bolus-1', timestamp: iso(t), amount: units, isExternal: false, isSMB: false, duration: 0 });
  }
  for (const [rate, durationMin, startMinAgo] of tempBasals) {
    const t = clockMs - startMinAgo * 60000;
    events.push({ _type: 'TempBasalDuration', id: `tbd-${startMinAgo}`, timestamp: iso(t), 'duration (min)': durationMin });
    events.push({ _type: 'TempBasal', id: `_tb-${startMinAgo}`, timestamp: iso(t), temp: 'absolute', rate });
  }
  events.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));
  return events;
}

function carbs(clockMs, { gramsAgoMin = null } = {}) {
  if (!gramsAgoMin) return [];
  const [grams, minAgo] = gramsAgoMin;
  const t = iso(clockMs - minAgo * 60000);
  return [{ carbs: grams, actualDate: t, created_at: t, id: 'carb-1', note: null, protein: 0, fat: 0, isFPU: false, enteredBy: 'Trio' }];
}

function currentTemp(clockMs, { rate = 0, duration = 0, minAgo = 0 } = {}) {
  return { duration, rate, temp: 'absolute', timestamp: iso(clockMs - minAgo * 60000) };
}

function trioCustomOrefVariables(clockMs, overrides = {}) {
  return Object.assign({
    average_total_data: 0,
    currentTDD: 0,
    weightedAverage: 1,
    past2hoursAverage: 0,
    date: iso(clockMs),
    overridePercentage: 100,
    useOverride: false,
    duration: 0,
    unlimited: true,
    overrideTarget: 0,
    smbIsOff: false,
    advancedSettings: false,
    isfAndCr: false,
    isf: false,
    cr: false,
    smbIsScheduledOff: false,
    start: 0,
    end: 0,
    smbMinutes: 30,
    uamMinutes: 30,
    toughMealActive: false,
    toughMealMinutesRemaining: 0,
    toughMealStartingBG: 0,
    toughMealIOBAtDose: 0,
    toughMealFatPlusProtein: 0,
    toughMealAutoDetected: false,
    mealWindowActive: false,
    mealWindowMinutesRemaining: 0,
    mealWindowEstimatedCarbs: 0,
    mealWindowCarbsConfirmed: false,
    mealWindowBoostSMBRatio: true,
    mealWindowSMBRatioValue: 0.8,
    mealWindowRelaxRisingGuard: true,
    mealWindowAdditiveFloor: false,
    mealWindowForceUAM: true,
    mealWindowPhantomCOB: false,
    mealWindowPhantomCOBGrams: 20,
    mealWindowSMBMinutesMultiplier: 2,
    mealWindowToughMealCapPercent: 75,
    mealWindowCOBDecayMultiplier: 1,
    mealWindowAutoPhantomCOBLevel: 0,
  }, overrides);
}

module.exports = { settingsDocuments, glucoseSeries, pumpHistory, carbs, currentTemp, trioCustomOrefVariables, iso };
