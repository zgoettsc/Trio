# Watch face and watch app plan

The watch is the backbone: every alert, prompt and one-tap log depends on
data reaching the watch reliably and on button input getting back to the
phone. It has to run consistently before anything else is built on it.

Target watch: Garmin Enduro 2 (Connect IQ 5.2, buttons only, touchscreen
off). Watch code lives in the separate `Garmin-Watch-Trio` repository.

## Where things stand

- The owner's custom face polls Nightscout every 5 minutes from a
  background service. It does not use the phone-to-watch messages this fork
  sends from `GarminManager.swift`.
- Symptom: data hours stale, sometimes catching up, fixed by re-selecting
  the face.
- Likely cause, found by reading the code: the face deleted its own
  5-minute timer in `onStop()`, which also runs each time the background
  fetch ends. Fix, token support and an on-face failure code are in
  `Garmin-Watch-Trio` pull request 21. Compiles; not yet run on a watch.

## What the platform allows

| Need | Watch face | Watch app | iPhone notification mirrored to the watch |
|---|---|---|---|
| Show glucose, IOB, COB | yes | yes | no |
| Show an alert level | yes | yes | yes, as text |
| Vibrate or beep by level | no | yes, while open | yes, one pattern |
| Button input (log, answer) | no | yes | no (view and dismiss only) |

A watch face cannot take input, so logging and answering need a companion
watch app. Garmin's own notification API (needs 5.1; the Enduro 2 has 5.2)
can show action buttons, but developers report it failing on real watches
when sent from the background: unproven until tested on this watch.

## Stages

1. **Face refreshes reliably.** Build and load pull request 21. Pass: the
   data-age line stays under about 10 minutes for a full day with the phone
   in range, and no failure code shows.
2. **Phone-push path.** Polling through Nightscout cannot go below 5 minutes
   and adds a second hop. Alerts need a direct phone-to-watch message.
   Decide between (a) registering the custom face with `GarminManager` and
   receiving phone messages in its background service, keeping the poll as
   a fallback, and (b) a companion app that carries the live link. Fix the
   phone-side weaknesses listed below first.
3. **Companion test app (side-loaded).** Answers three questions on the
   real watch: does an action-button notification appear when the app is
   not open; can vibration differ by level in the background; how fast does
   a button answer reach the phone when Trio is in the background.
4. **Face shows alert state.** One extra field in the watch payload and a
   level indicator on the face.
5. **Input.** Button-driven menu in the companion app: rescue carbs, ate
   (size, speed), did not eat, override reasons. Assignable to a button
   hold.

## Phone-side weaknesses found in `GarminManager.swift` (not yet changed)

These affect any face or data field that uses the phone-push path:

1. Data is marked as sent before the send succeeds, including when the
   watch was not ready or the app-status check failed; an identical payload
   is then skipped as unchanged.
2. On reconnect a resend is requested but is usually discarded as a
   duplicate because of point 1.
3. A failed send is retried once after 2 seconds and then dropped until the
   next glucose reading.
4. The per-device "ready" flag is cleared on disconnect and only set again
   by a characteristics-discovered callback; if that does not arrive, every
   send is skipped until the app restarts.

## Open questions

- Latency of the phone-push path to a watch face in practice.
- Whether iOS suspends Garmin Connect often enough to matter for the
  Nightscout poll.
- Battery cost of each option.
