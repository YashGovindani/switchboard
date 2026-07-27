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
./scripts/bundle.sh --install        # builds Switchboard.app → /Applications
open /Applications/Switchboard.app

# The CLI (optional companion)
swift build -c release
cp .build/release/switchboard ~/.local/bin/   # or anywhere on your PATH
```

## Usage

### App

Switchboard runs in the background — no Dock icon, just a menu-bar icon.

- Press **⌥ Space** anywhere to toggle the switcher panel (it also appears over fullscreen apps).
- **Click an environment** (or its → button) to open it: the panel dismisses and the actions run in the background (the menu-bar icon shows an hourglass while working).
- **New Environment**: type a name and press Enter — the environment is created immediately (no Save button anywhere; everything persists as you go).
- **Add action** opens a chat pane with your local Claude: describe what the action should do in plain English, watch the reply stream in, refine it ("use port 5175", "also open the staging URL"), then click **Create action** on the proposed steps. The agreed commands are cached at that moment, so opening the environment later runs exactly what you approved — instantly, with no re-translation.
- **Edit** (✏️) an environment to manage its actions, or an action to revise it — the chat reopens pre-loaded with the action's current intent and commands.
- **Delete** (🗑) an environment or action with an inline confirm: first click shows "Sure?", second click deletes.
- **Escape** (or clicking elsewhere) dismisses the panel.
- Menu-bar menu: show the panel, open the config file, quit.

### CLI

```bash
switchboard list                     # list configured environments
switchboard open <env>               # open an environment (generates & caches commands on first run)
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
- [ ] **Phase 3 — Window switching**: track each environment's windows; focus on switch, fullscreen/Spaces aware
- [ ] **Phase 4 — Lifecycle**: create/finish tasks with user-defined init & cleanup actions
- [ ] **Phase 5 — UI iterations & settings**: keyboard navigation, environment rename, configurable shortcut
