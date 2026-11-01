# French Study Time Tracker

A small macOS menu bar app for tracking French study time. It can recognize selected study apps and lesson windows, pause self-study after inactivity, and keep time in a local draft until you choose to add it to your totals.

## What it does

- Shows pending time, today's total, and this week's total.
- Separates totals into **Self-study** and **Tutoring**.
- Lets you pause, resume, manually start or end, reset pending time, and edit daily totals inline.
- Automatically recognizes supported Anki reviews, selected dictionary and textbook windows, French-related ChatGPT/Codex titles, and Zoom meeting windows.
- Pauses self-study after 15 minutes of inactivity. Recognized tutoring meetings ignore mouse inactivity; sleep and screen lock still stop the timer.
- Keeps pending time local. Only **Add to records** changes the confirmed ledger.
- Works without cloud sync. An optional HTTPS sync endpoint can be configured by the user.

Recognition is based on foreground app names and accessible window titles. It does not inspect browser page contents, record keystrokes, or upload window titles. Detection depends on macOS Accessibility permission and on the titles used by each app version.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (Swift compiler)
- Accessibility permission for window-title recognition

## Build and install

```sh
zsh build.sh
python3 install.py --restart
```

The installer places the app in `~/Applications` and registers it to launch at login. The locally built app is ad-hoc signed, so macOS may require you to grant Accessibility permission again after rebuilding. For personal testing, remove the old Accessibility entry and add the newly installed app.

## Cloud sync

Cloud sync is optional. The app sends confirmed daily totals over HTTPS to a compatible endpoint; pending time, page titles, and study content are not sent. Configure the endpoint and access token using the app's `--configure` interface. Keep tokens in macOS Keychain and never commit them.

Without cloud configuration, local timing and totals remain available. The app does not include a hosted backend or any account-specific cloud configuration.

## Project documents

- [Product requirements (PRD)](docs/PRD.md)
- [Software design (SDD)](docs/SDD.md)
- [Contributing](CONTRIBUTING.md)
- [License](LICENSE)

## Known limitations

- Automatic detection depends on app and window titles; unsupported or localized titles may be missed.
- Anki review detection requires AnkiConnect on its default local endpoint.
- Ad-hoc signing can cause macOS permission prompts after updates.
- Cloud sync is one-way and optional; this repository does not ship a backend.
