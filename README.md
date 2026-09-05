<div align="center">

# MacTools

### I kept paying for tiny Mac utilities. So I started building my own.

**One native Mac app. The small tools I use every day. No subscriptions.**

`Swift` · `SwiftUI` · `AppKit` · `EventKit` · `macOS`

</div>

---

MacTools is my personal macOS toolbox: a native app where I keep turning small recurring annoyances into software.

It wasn't designed from a startup thesis or a market map. It grew from a much simpler loop:

```text
something annoys me
        ↓
can I build it myself?
        ↓
build the smallest useful version
        ↓
use it every day
        ↓
notice the next annoyance
        ↺
```

## What's inside

| Tool | What it does |
| --- | --- |
| **Clipboard** | Watches clipboard changes, keeps useful history and lets me paste previous items quickly. |
| **Calendar** | Pulls calendar context and meeting links into the workflow instead of making me hunt for them. |
| **Battery** | Monitors battery state from inside the same utility surface. |
| **Media** | Gives the app awareness and control of currently playing media. |
| **Voice ingest** | Accepts voice input as another fast path into the app. |
| **Global hotkeys** | Makes the tools available without navigating through windows. |
| **Quick Add** | Captures tasks quickly and turns lightweight text into actionable items. |
| **Shelf** | Keeps temporary things close at hand instead of forcing them into permanent storage. |
| **Notch UI** | Uses the physical MacBook notch area as part of the interaction surface. |

The point isn't that each feature is novel. The point is that I wanted them to work **together, exactly the way I use my Mac**.

## A native app, not a bundle of scripts

MacTools is built in Swift and mixes SwiftUI with lower-level macOS APIs where the interaction requires it.

```text
Sources/Pila/
├── ClipboardWatcher.swift
├── HistoryModel.swift
├── CalendarManager.swift
├── BatteryMonitor.swift
├── MediaController.swift
├── FluidVoiceIngestor.swift
├── GlobalHotKey.swift
├── QuickAddController.swift
├── TaskParser.swift
├── ShelfStore.swift
├── NotchController.swift
├── PanelController.swift
└── main.swift
```

Some of the interesting work lives at the boundaries between a normal app and the operating system: global input, clipboard observation, calendar permissions, floating UI, notch geometry, media state and coordinating multiple small utilities without making the app feel like a dashboard.

## Why I built it

I like software that removes tiny amounts of friction repeatedly.

A clipboard manager, a quick task capture flow or a meeting shortcut may only save a few seconds at a time. But if I use it dozens of times a day, I start caring a lot about those seconds — and even more about whether the tool behaves exactly the way I expect.

At some point I realized I was paying separate subscriptions for utilities that were individually small and personally opinionated.

So I started replacing them.

Not because rebuilding everything is always rational. Mostly because **building the thing is often more interesting than accepting the default**.

## Things I got to learn by building it

MacTools pushed me outside the web/AI stack I spend most of my time in:

- native Swift and SwiftUI;
- AppKit-style macOS window and panel behavior;
- global keyboard interaction;
- clipboard observation and history state;
- EventKit/calendar integration;
- menu-bar and floating interfaces;
- geometry around the MacBook notch;
- coordinating OS permissions and app lifecycle;
- building software for a user whose workflow I know extremely well: me.

## Build

The project uses Swift Package Manager.

```bash
swift build
```

There is also a local build script for assembling the macOS app:

```bash
./build.sh
```

## Philosophy

I don't want MacTools to become an everything-app.

The bar for adding something is simple: **does this remove a recurring annoyance from my own day?**

If yes, I try it. If it earns its place, it stays.

---

<div align="center">

**Notice friction → build the tool → keep moving.**

</div>
