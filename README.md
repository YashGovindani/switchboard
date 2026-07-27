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
swift build -c release
cp .build/release/switchboard ~/.local/bin/   # or anywhere on your PATH
```

## Usage

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

- **Plain-English configuration** — no command syntax to learn; describe the setup you want.
- **Generate once, cache forever** — Claude is only consulted the first time (or on `refresh`), so opening an environment is instant.
- **Auditable** — cached commands are plain JSON on disk and printed before execution.
- **Unopinionated** — no built-in app integrations; browsers, editors, terminals, containers, and anything else are all just prompts.

## Roadmap

- [x] **Phase 1 — CLI engine**: prompt → command translation, caching, environment opener
- [ ] **Phase 2 — Background app**: menu-bar agent, global ⌥Space hotkey, Spotlight-style overlay to pick environments
- [ ] **Phase 3 — Window switching**: track each environment's windows; focus on switch, fullscreen/Spaces aware
- [ ] **Phase 4 — Lifecycle**: create/finish tasks with user-defined init & cleanup actions
- [ ] **Phase 5 — Settings UI**: manage environments and the shortcut without editing JSON
