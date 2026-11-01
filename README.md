# Purrch

Mac widgets that sit under your notch and get written by your coding agent. Purrch also keeps a private, local log of how you work, and can suggest widgets from what you repeat.

Purrch is free and open source. This is an early release, so expect rough edges.

![Purrch switching between widgets under the notch, then searching](docs/demo.gif)

## Install

Requires macOS 15 or later and the Xcode Command Line Tools.

```bash
git clone https://github.com/pranspach/purrch
cd purrch
scripts/build-app.sh
open build/Purrch.app
```

`scripts/make-dmg.sh` packages the app as a DMG. Builds are ad-hoc signed, not notarized, so macOS warns about a downloaded copy, and it may ask for permissions again after a rebuild.

## Using it

- **Hover over the notch** to open the current widget. On a Mac without a notch, hover over the small bar at the top of the screen.
- **Switch widgets** by clicking a tab along the top of the panel, or with ⌘1 to ⌘9, ⌘← and ⌘→, or a two-finger swipe.
- **Press ⌥Space** or click the notch to search. Search finds widgets and apps, does math (`2^10 / (3+5)`, `15% of 80`), and runs commands (`kill port 3000`, `weather in Berlin`). Press Tab to have your agent build what you typed.
- **Press ⌘,** on an open widget to edit its name, icon, height and shortcut, or ask your agent to change it.
- **Pin a widget** to keep it showing until you unpin it.
- **The main window** opens from the paw icon in the menu bar, and holds ideas, activity, shortcuts, privacy and settings.

## Starter widgets

AI Usage, Caffeinate, Clipboard, Focus, Now Playing, Ports, System, Timer, Today and Website.

## Writing widgets

A widget is a folder in `~/Library/Application Support/Purrch/widgets/` with a `manifest.json` and an `index.html`.

```json
{"name": "Timer", "icon": "timer", "height": 130}
```

`icon` is an SF Symbol name. To show a website instead of local files, add `"url": "https://example.com"` and leave out `index.html`. Website widgets never get the bridge.

Local pages can call `window.purrch`, where every call returns a Promise:

| Call | Result |
|---|---|
| `purrch.exec(command)` | Runs a shell command and returns `{stdout, stderr, code}` |
| `purrch.activity()` | Today's activity stats |
| `purrch.clipboard()` | Recent copies as `[{id, kind, text, thumbnail}]` |
| `purrch.copy(text)` | Puts text on the clipboard |
| `purrch.copyItem(id)` | Copies an earlier item again |
| `purrch.pasteItem(id)` | Pastes an earlier item into the app in front, if Accessibility is on |

### Widget security

The bridge can run commands as you, so Purrch asks before a widget first uses it, and asks again whenever the widget's code changes. Unmodified starter widgets don't ask. A widget you approve can do anything your user account can, so only approve widgets you trust.

## Agents

Purrch runs the coding agent CLI you already have, so it needs no extra subscription. It looks for Claude Code, Codex, Gemini CLI, Cursor (`cursor-agent`), GitHub Copilot (`copilot`) and OpenCode.

## Privacy

Purrch has no accounts, analytics or servers. Activity stays in `~/Library/Application Support/Purrch/activity.sqlite`.

| Data | When it's recorded | Kept for |
|---|---|---|
| Frontmost app and time spent | Always | Until you delete it |
| Hourly keystroke count, never the keys | With Input Monitoring | Until you delete it |
| Window titles | If you turn it on and grant Accessibility | 30 days |
| Full web addresses | If you turn it on and allow browser control | 30 days |
| Text on screen, never images | If you turn it on and grant Screen Recording | 30 days |
| Copied text | If you turn it on | 30 days |

Clipboard History is separate. It holds your last 40 copies in memory only, and skips items marked as concealed.

Data leaves your Mac in three cases:

- **Agents:** what you send your agent goes to its provider under its own policy. Ideas send app names, app switches, window titles and website hostnames, but never screen text or copied text.
- **Weather:** a `weather in …` search sends the place name to [wttr.in](https://wttr.in).
- **Widgets:** a widget you approve, or a website widget, can reach the network like any other program.

You can see everything recorded, and delete it, on the Privacy page.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
