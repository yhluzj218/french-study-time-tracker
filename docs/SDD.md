# Software Design: French Study Time Tracker

## Components

- `App.swift`: menu bar lifecycle, SwiftUI popover, foreground app and window-title recognition, local persistence, optional HTTPS sync, and user actions.
- `Core.swift`: time slices, draft timer, confirmed ledger, timezone-aware daily splitting, and deterministic core checks.
- `build.sh`: compiles and ad-hoc signs the macOS app.
- `install.py` and `restart.py`: install into the current user's Applications folder and register a login launch agent.

## State model

- `DraftTimer` holds confirmed-but-not-yet-recorded activity and intervals awaiting idle classification.
- `Ledger` holds confirmed seconds by local date and internal category.
- A snapshot stores draft and ledger together. Reset writes a local pre-reset snapshot, clears only the draft, and pauses.
- The user selects Self-study or Tutoring when adding a draft. Individual detected categories are grouped into those two display totals.

## Tick and idle behavior

The main run loop evaluates activity once per second. Short gaps may be accumulated; long scheduling gaps are not backfilled. Idle self-study is confirmed only through the last activity boundary; at the 15-minute threshold the unresolved tail is dropped. Recognized lesson windows use the Tutoring category and ignore mouse idle. Manual pause and system sleep/lock take priority.

## Local storage and privacy

Data is stored in the current user's Application Support directory with restrictive file permissions and atomic writes. Window titles are used in memory and are not persisted. Pending time is local-only. Keychain holds optional sync credentials; source files contain no account tokens or personal service URL.

## Optional cloud sync

When configured, the client sends confirmed daily category totals over HTTPS using the endpoint and token supplied by the user. Retries send totals (idempotent upsert expected) rather than increments. The repository does not ship or operate the endpoint.

## Constraints

- Accessibility permission is required for window-title detection and may need to be granted again after ad-hoc signed updates.
- Anki detection expects AnkiConnect at `127.0.0.1:8765`.
- Zoom detection is based on localized meeting window titles and can miss unrecognized variants.
- There is no signed/notarized release pipeline in this repository yet.
