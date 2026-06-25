# Joystick 🕹️

**English** · [한국어](README.ko.md)

A tiny macOS panel that does one thing: **boot a simulator and Hot Reload your Flutter app.**
No need to fire up VSCode or Xcode — one small window does it all.

![Joystick](docs/joystick.png)

A slim one-row window that floats on top. Buttons, left → right:
📦 Project · 📱 Simulator · ▶ Run · ■ Stop · ⚡ Hot Reload · ↻ Hot Restart · ☰ Log · ✕ Quit

## Why

Every time I tweaked a line of code and wanted a Hot Reload, I had to open a heavy IDE like
VSCode, then open Xcode or the Simulator app just to boot a device… annoying, when the buttons
I actually press are just a handful.

So I pulled those buttons into a small always-on-top window. **Booting a simulator (📱),
running the app (▶), and Hot Reload (⚡) — all from this one window.** No IDE, no Xcode, no terminal.

## Install

### With Claude Code (easiest)
Give the repo link to Claude and ask:

> "Clone this repo and install Joystick: `<repo-url>`"

It reads [`CLAUDE.md`](./CLAUDE.md) and handles requirements → build → launch on its own.

### Manual
```bash
git clone <repo-url> joystick
cd joystick
./build.sh
open Joystick.app
```

## Requirements

- macOS 13+
- Xcode Command Line Tools — `xcode-select --install`
- Flutter — **the app finds its path automatically** (just needs to be installed)

## How to use

1. 📦 Pick a project (the most recently touched one is auto-selected on launch)
2. 📱 Pick a simulator → **it boots automatically** (no need to open Simulator.app)
3. ▶ Run → builds and launches
4. Edit code, then ⚡ Hot Reload (or ↻ Hot Restart)

Hitting 📱 lists installed iOS simulators grouped by version (running ones get a ✓), and it
boots the one you pick right there — no hunting for the Simulator app:

<img src="docs/joystick-devices.png" width="380" alt="Simulator picker — grouped by iOS version">

If there's an `.env.local` (`KEY=VALUE`) in the project root, it's injected into the app automatically.

## Highlights

- One small window — boot simulator, run, and Hot Reload all in one place
- **No IDE, Xcode, or terminal needed**
- Auto-selects your most recent Flutter project on launch
- Finds flutter automatically (just needs to be installed)
- Single file, zero external dependencies

iOS Simulator only · macOS only
