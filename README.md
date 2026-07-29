# switchboard

Create window based environments and easily switch between them in MacOS.

Define an environment in plain English — which browser windows, editor, and terminal it needs — and switchboard uses the local [Claude Code CLI](https://claude.com/claude-code) to translate that intent into real shell commands, caches them, and runs them on demand. No hardcoded integrations: if you can describe it, it's an action.

## How it works

```
config.json (intent)  ──▶  claude -p (translate once)  ──▶  cache.json (commands)  ──▶  zsh (execute)
```

- Each environment is a named list of **actions**; an action is just a `name` and a natural-language `prompt`.
- The first time an action runs, the prompt is translated into shell commands by your local `claude` CLI and cached.
- Every later run executes straight from cache — instant, deterministic, zero tokens.
- Editing a prompt automatically invalidates its cached commands.

## Requirements

- macOS (Apple Silicon or Intel)
- Swift toolchain (Xcode Command Line Tools are enough: `xcode-select --install`)
- [Claude Code CLI](https://claude.com/claude-code) (`claude`) installed and authenticated
- Whatever apps your prompts reference (Chrome, VS Code + `code` CLI, iTerm, Docker, …)

## Install

```bash
git clone git@github.com:YashGovindani/switchboard.git
cd switchboard

# The menu-bar app (recommended)
./scripts/setup-signing.sh           # one-time: stable signing identity, so the
                                     # Accessibility grant survives rebuilds
./scripts/bundle.sh --install        # builds Switchboard.app → /Applications
open /Applications/Switchboard.app

# The CLI (optional companion)
swift build -c release
cp .build/release/switchboard ~/.local/bin/   # or anywhere on your PATH
```

## Usage

### App

Switchboard runs in the background — no Dock icon, just a menu-bar icon.

- Press **⌥ Space** anywhere to toggle the switcher panel (it also appears over fullscreen apps). Change the shortcut from the menu-bar icon → **Change Shortcut…**; enable **Start at Login** there too.
- **Type to filter** environments, **↑/↓** to select, **Enter** to open — or just click.
- **Click an environment** (or its → button) to open it: the panel dismisses and the actions run in the background (the menu-bar icon shows an hourglass while working). Every window the actions create is recorded as belonging to that environment and taken **fullscreen onto its own Space**.
- **Open it again → it switches, not duplicates.** If the environment's windows are still alive, Switchboard focuses them (macOS jumps to their Spaces) instead of re-running the actions; the previous environment's non-fullscreen windows are minimized out of the way. Actions only re-run when nothing of the environment survives (e.g. after a reboot).
- Window control needs the **Accessibility permission** — macOS prompts once on first switch (grant in System Settings → Privacy & Security → Accessibility). Run `scripts/setup-signing.sh` before installing so the grant persists across rebuilds.
- **New Environment**: type a name and press Enter — the environment is created immediately (no Save button anywhere; everything persists as you go).
- **Add action** opens a chat pane with your local Claude: describe what the action should do in plain English, watch the reply stream in, refine it ("use port 5175", "also open the staging URL"), then click **Create action** on the proposed steps. The agreed commands are cached at that moment, so opening the environment later runs exactly what you approved — instantly, with no re-translation.
- **Edit** (✏️) an environment to manage its actions, or an action to revise it — the chat reopens pre-loaded with the action's current intent and commands. The header shows the environment you're editing (click the ✏️ beside it to **rename**), with **Add action** beside it.
- **Templates** — the ⧉ button in the builder header saves the environment's actions + cleanup as a template (saving again overwrites it). The new-environment screen then offers **"start from a template"**: pick one and the environment is pre-filled — cached commands included, so nothing is re-translated. Clicking a template with the name field empty names the environment after the template.
- **Cleanup actions** — each environment has a second list, designed in the same chat via **Add cleanup**: teardown steps (stop servers, remove worktrees, …) for when the task is done.
- **Finish task** (⏹ on an environment row, or `switchboard finish <env>`): runs the cleanup actions, closes the environment's tracked windows, and clears its tracking. The environment definition stays for next time.
- **Copy** (⧉) an action's description, **delete** (🗑) an environment or action with an inline confirm: first click shows "Sure?", second click deletes.
- **Escape** (or clicking elsewhere) dismisses the panel.
- Menu-bar menu: show the panel, open the config file, quit.

### CLI

```bash
switchboard list                     # list configured environments
switchboard open <env>               # open an environment (generates & caches commands on first run)
switchboard finish <env>             # run an environment's cleanup actions
switchboard show <env>               # show each action's prompt and its cached commands
switchboard refresh <env> [action]   # force re-translation of prompts (all actions, or one)
```

## Configuration

`~/.config/switchboard/config.json` (a sample is created on first run):

```json
{
  "environments": [
    {
      "name": "myproject-featureX",
      "actions": [
        { "name": "browser",  "prompt": "Open a new Chrome window with localhost:5174" },
        { "name": "editor",   "prompt": "Open VS Code at ~/work/myproject" },
        { "name": "terminal", "prompt": "Open an iTerm window in ~/work/myproject and run npm run dev" }
      ]
    }
  ]
}
```

Generated commands are cached in `~/.config/switchboard/cache.json`, keyed by a hash of each prompt. Inspect them any time with `switchboard show <env>` — you always get to see exactly what will run.

## Features

- **⌥Space, anywhere** — a global hotkey summons a Spotlight-style floating panel, even over fullscreen apps.
- **Real switching, not relaunching** — each environment's windows are tracked by their window-server IDs (persisted in `~/.config/switchboard/state.json`); reopening focuses what's already there, switching minimizes what you left, and every action is generated to open a fresh window so environments never share them.
- **Fullscreen-first** — newly opened environment windows are pushed into native fullscreen, one Space per window, so switching environments is a clean jump between Spaces.
- **Chat-designed actions** — actions are agreed in a conversation with your local Claude, not typed as config. The panel expands into a split view (environment on the left, chat on the right), replies stream in live, and each conversation runs on a persistent `claude` stream-json session — later turns are fast and cheap, and no transcript is resent.
- **Approve before it ever runs** — Claude proposes concrete numbered steps; nothing becomes an action until you click Create. The approved commands go straight into the cache.
- **Generate once, cache forever** — opening an environment executes the cached commands instantly; Claude is only consulted when designing or editing an action (or on CLI `refresh`).
- **Live editing** — environments and actions are created, edited, and deleted in place with immediate persistence; no Save buttons, inline delete confirmation.
- **Auditable** — cached commands are plain JSON on disk; inspect them with `switchboard show`.
- **Unopinionated** — no built-in app integrations; browsers, editors, terminals, containers, and anything else are all just prompts.
- **No Xcode required** — builds with the plain Swift toolchain; `scripts/bundle.sh` assembles the .app bundle (icon generated by `scripts/make-icon.sh`).

## Roadmap

- [x] **Phase 1 — CLI engine**: prompt → command translation, caching, environment opener
- [x] **Phase 2 — Background app**: menu-bar agent, global ⌥Space hotkey, floating panel to open/create environments
- [x] **Phase 2.5 — Chat-designed actions**: streaming chat with local Claude to design/edit actions; live-saving builder; edit/delete for environments and actions
- [x] **Phase 3 — Window switching**: per-environment window tracking, focus-instead-of-duplicate, minimize on switch, auto-fullscreen, Accessibility flow with stable code signing
- [x] **Phase 4 — Lifecycle**: per-environment cleanup actions and "Finish task" (cleanup + close windows) in app and CLI
- [x] **Phase 5 — Settings & polish**: type-to-filter with keyboard navigation, environment rename, recordable global shortcut, start at login
- [x] **Phase 6 — Templates**: save an environment's init/cleanup behaviour, create pre-filled environments from it
