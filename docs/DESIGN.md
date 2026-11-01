# Design principles

These guide Purrch's interface. Each comes from published UX work. The sources make general arguments and don't discuss Purrch's panel, so how they apply here is our own reading.

## Keep navigation visible

Hiding important sections lowers how often people use them. Luke Wroblewski collects cases of this in [Obvious Always Wins](https://www.lukew.com/ff/entry.asp?1945), where products lost engagement after moving visible tabs behind menus, and gained it after moving them back. The cases are reported without numbers, so treat them as a pattern rather than a measurement.

**In Purrch:** every widget is on screen as a tab whenever the panel is open. Only very large collections scroll.

## Label things

People recognize options more easily than they recall them, which is [Nielsen's sixth heuristic](https://www.nngroup.com/articles/recognition-and-recall/). Most icons have no standard meaning, so [Icon Usability](https://www.nngroup.com/articles/icon-usability/) recommends text labels that are always visible, not revealed on hover.

**In Purrch:** tabs show an icon and a name. Agent-built widgets get arbitrary icons, which makes the name even more important.

## Make targets big, and keep them close

[Fitts's Law](https://www.nngroup.com/articles/fitts-law/) says the time to reach a target depends on its size and distance. An icon with a label also makes a bigger target than an icon alone.

**In Purrch:** tabs are about 100 × 28 points, and they sit at the top of the panel, right where the pointer arrives from the notch.

## Don't move controls

This one is our own rule, and it follows from Fitts's Law: a target that moves has to be found again. Panel height varies by widget, so anything anchored to the bottom edge jumps on every switch.

**In Purrch:** the tabs and tools are anchored to the top. Widget content changes below them. Tabs keep their order, so position can become habit, and ⌘1 to ⌘9 follow that order.

## Offer shortcuts as well as the obvious path

Clicking a tab always works. ⌘1 to ⌘9, ⌘← and ⌘→, and swipes make it faster once you know them, but nothing depends on discovering them.

**In Purrch:** panel keys work without taking keyboard focus from your work, and they're only claimed while the panel is open.

## Checking a change

- Can someone see everything they can do here without hovering, or remembering a shortcut?
- Does each control stay in the same place as content changes?
- Could a new agent-built widget, with an unfamiliar icon, still be identified?
