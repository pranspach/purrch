# Contributing

Issues and pull requests are welcome.

## Setup

You only need macOS 15 or later and the Xcode Command Line Tools.

```bash
swift test
scripts/build-app.sh
open build/Purrch.app
```

With only the Command Line Tools, repeating `swift test` with no changes can fail with `plugin for module 'TestingMacros' not found`. Run `swift package clean` and try again.

## Checking UI changes

`--self-test` drives the real interface, saves screenshots and page text to a folder, and quits. It doesn't need Screen Recording.

```bash
build/Purrch.app/Contents/MacOS/Purrch --self-test /tmp/purrch-self-test
```

To refresh the README's GIF, which only opens widgets that show no personal data:

```bash
build/Purrch.app/Contents/MacOS/Purrch --record-demo "$PWD/docs/demo.gif"
```

## Guidelines

- Read [the design principles](docs/DESIGN.md) before changing the interface.
- Put logic that doesn't need AppKit in `Sources/PurrchCore`, with tests.
- Avoid `@State` and `@Observable`. Their macros need Xcode's plugins, and Purrch has to build with only the Command Line Tools. Use `ViewState` or an `ObservableObject`.
- Privacy is a feature. New kinds of recorded data must be off by default, stay on the Mac, show up in the Privacy page's log, and have a retention limit.
- Anything that widens what a widget can do goes through the bridge in `WidgetWebView.swift`, behind the existing approval prompt.

## Adding an agent

Add an entry to `Agent.known` in `AgentRunner.swift`. It needs two sets of arguments: one that lets the agent edit files in its working directory, and one that answers without changing anything.
