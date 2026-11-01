# Product Requirements: French Study Time Tracker

## Purpose

Help a French learner understand daily and weekly study time with minimal interaction. Automatic detection stages time locally; the learner decides when it becomes part of the confirmed totals.

## Product rules

- The menu bar popover shows pending time, today's and this week's confirmed totals, and two editable totals: Self-study and Tutoring.
- Pending time is never automatically added to the ledger or uploaded.
- The learner can pause, resume, manually start or end, reset pending time, and add all pending time to either category.
- Reset clears only pending time and pauses the timer. Confirmed totals remain unchanged.
- Editing a category replaces that day's category total in whole minutes.
- Study dates use the configured local timezone; intervals crossing midnight are split by date.
- Self-study pauses after 15 minutes without input. A recognized tutoring meeting ignores mouse inactivity. Sleep and screen lock stop timing.
- Cloud sync is optional. Without it, local timing and totals continue to work.

## Recognition

Recognition uses foreground app names, accessibility window titles, and AnkiConnect for the current review card. It does not inspect webpage contents or save window titles. The supported title patterns are implementation details and may need configuration for other languages or app releases.

## Acceptance criteria

1. Detecting study changes only pending time.
2. Explicit Add to records updates confirmed totals once and clears the recorded draft.
3. Reset clears the draft, pauses, and preserves the ledger.
4. A Zoom meeting that begins after manual start switches to tutoring behavior.
5. Manual pause, sleep, and screen lock still stop timing.
6. Inline edits set category totals and enforce non-negative whole minutes and a 24-hour daily maximum.

## Out of scope

- Capturing screens, keystrokes, browser history, or study content.
- A bundled hosted backend or multi-device merge service.
- Recognition of every learning website or video service.
