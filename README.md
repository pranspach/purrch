# Purrch

Mac widgets that sit under your notch and get written by your coding agent. Purrch also keeps a private, local log of how you work.

## Build and run

Requires macOS 15 or later and the Xcode Command Line Tools.

```bash
scripts/build-app.sh
open build/Purrch.app
```

- Hover over the notch to open the current widget. Use ⌘← and ⌘→ to switch.
- Press ⌥Space to search widgets and apps. Type a description and press Tab to have your agent build it.
- Manage widgets and see today's activity in the main window, which opens from the paw icon in the menu bar.

## Widgets

A widget is a folder in `~/Library/Application Support/Purrch/widgets/` with a `manifest.json` and an `index.html`.

```json
{"name": "Timer", "icon": "timer", "height": 130}
```

`icon` is an SF Symbol name. Pages can call `window.purrch`, where every call returns a Promise:

| Call | Result |
|---|---|
| `purrch.exec(command)` | Runs a shell command and returns `{stdout, stderr, code}` |
| `purrch.activity()` | Today's activity stats |
| `purrch.clipboard()` | Recent copied text, newest first |
| `purrch.copy(text)` | Puts text on the clipboard |

`exec` runs with your user's permissions, so only keep widgets you trust.

## Agents

Purrch runs the coding agent CLI you already have, in the widget's folder. It looks for Claude Code, Codex, Gemini CLI and OpenCode.

## Privacy

Activity stays in `~/Library/Application Support/Purrch/activity.sqlite`. Purrch records which app is in front and an hourly keystroke count, but never which keys you press, window titles or screen contents. The keystroke count needs Input Monitoring and stays off without it. Clipboard history is held in memory only and skips items marked as concealed.
