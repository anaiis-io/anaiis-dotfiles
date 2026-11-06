# anaiis-dotfiles

One installer sets up a machine for Claude Code. It links a tracked policy stack (rules, hooks, scripts, and commands) into `~/.claude/` and wires the shell. Git tracks every file. macOS is the supported platform.

## What you get

- Rules that Claude Code loads in every session (`claude/rules/`).
- Hooks that guard tool calls, deliver memory to Claude, and lint each edit (`claude/hooks/`).
- Git hooks for pre-commit lint, pre-push tests, and commit message lint.
- Shell config (`bash/shared.bash`), a `Brewfile`, and the `web-verify` CLI.
- A doctor that checks the setup and names the fix for each gap.

Skills come from plugin marketplaces that `claude/settings.json` registers. This repo holds no copy of them.

## Requirements

- macOS on Apple Silicon, with Homebrew in `/opt/homebrew`.
- Homebrew bash 5. The harness runs on it.
- `git`, `gh`, `jq`, and Claude Code. The `Brewfile` lists the other tools.

## Install

Warning: install Homebrew bash before you start Claude Code. `claude/settings.json` pins `/opt/homebrew/bin/bash`. Without that file, every guarded tool call blocks. That includes the call that installs bash. Run `brew install bash` in a terminal outside Claude Code.

1. Clone the repo and run the installer. It is safe to run again.

```bash
git clone git@github.com:anaiis-io/anaiis-dotfiles.git ~/anaiis-dotfiles
bash ~/anaiis-dotfiles/install.sh
```

2. Open a new terminal. The shell reads the new `~/.bashrc` lines at start.
3. Start Claude Code once in a trusted folder. Run `/reload-plugins`.
4. Set your git identity. The repo sets none.

```bash
git config --global user.name "<name>"
git config --global user.email "<id>+<login>@users.noreply.github.com"
```

`<id>` is the numeric id of your GitHub account. `<login>` is its login. This repo rejects a commit whose email is not a GitHub noreply address.

The installer links `claude/` into `~/.claude/`, adds two lines to `~/.bashrc`, and adds the GitHub host keys when SSH is in use. It keeps `~/.claude/memory` as a local folder. It does not overwrite a real file where a link belongs.

## Verify

```bash
bash ~/.claude/scripts/bootstrap-doctor.sh
```

The doctor only reads. It prints `ok` or `MISSING <what>: <fix>` for each check. The last line is `doctor: <n> missing`. The doctor exits 1 when `n` is above 0. A `WARN` line does not count.

The checks cover the shell wiring, the `~/.claude` links, the plugins, the GitHub host key, the Claude Code version, the bash pin, and `sqlfmt`. A plugin shows MISSING until Claude Code fetches it, so run the doctor after step 3.

## How it is organized

| Path | Holds |
|---|---|
| `claude/` | Rules, hooks, scripts, commands, and `settings.json`. The installer links it into `~/.claude/`. |
| `bash/` | `shared.bash`: PATH, aliases, and prompt. `~/.bashrc` sources it. |
| `bin/` | The `web-verify` CLI. |
| `templates/` | Dashboard and Playwright templates that plugins use. |
| `tests/` | The test suites. `tests/run-all.sh` runs all of them. |
| `evals/`, `reports/` | Plugin evals and their results. |
| `Brewfile`, `install.sh` | The package list and the installer. |

`claude/rules/context.md` explains how the rule files fit together.

## Daily use

- **Update.** Run `git pull`. The `~/.claude` links point into the clone, so a pull changes the live config.
- **Packages.** `bash ~/anaiis-dotfiles/claude/scripts/brew-sync.sh install` installs the `Brewfile`. The `check` verb reports drift. The `dump` verb adds new entries. No verb removes one.
- **Models.** The aliases `claude-fast`, `claude-fable`, and `claude-opus` start one model. The suffixes `-turbo` and `-max` raise the effort. `bash/shared.bash` defines them.
- **Machine-local settings.** Put secrets and overrides in `~/.bashrc.local`. The installer does not source it. Add a line that sources it after the `shared.bash` line.
- **Git hooks.** Claude Code installs the three hooks in a repo on the first prompt. Outside Claude Code, run `bash ~/.claude/scripts/install-repo-hooks.sh` once in the repo.
- **Other shells.** The installer edits only bash config. For zsh or fish, add `~/anaiis-dotfiles/bin` to PATH by hand.

## Memory

Two local folders hold memory. Git tracks neither.

- `~/.claude/memory/` holds facts for every project.
- `~/.claude/projects/<key>/memory/` holds facts for one project.

A `SessionStart` hook delivers the global folder to Claude. Claude Code loads the project index by itself. Before compaction, a hook saves a handoff file. After compaction, a hook restores it. Compaction starts at 60% of the context window. Run `bash ~/.claude/scripts/seed-memory.sh` in a project to create its memory files.

## Contribute

1. Make a worktree under `tmp/worktrees/<id>`. The `~/.claude` links point at the main checkout, so a change reaches the live config only after it merges.
2. Write the test first. Run `bash tests/run-all.sh`. The `pre-push` hook and CI run the same command.
3. Name the commit `<type>(<scope>): <description>`. The `commit-msg` hook checks it. `claude/rules/git.md` holds the rubric.
4. Open a pull request. `main` needs a pull request and a passing `tests` check.

`install.sh`, `bootstrap-doctor.sh`, and `bash/shared.bash` run on bash 3.2, the macOS default. All other scripts run on bash 5.

Keep the tree public. A test fails when a tracked file holds a private email address. To guard employer names, list one term per line in `~/.config/anaiis-dotfiles/employer-terms.txt`. The doctor warns when that file is absent.

## Troubleshooting

- **Every tool call blocks.** The bash pin is absent. Run `brew install bash` in a terminal outside Claude Code.
- **A plugin does not load.** Read the Errors tab of `/plugin`. A plugin clone over SSH needs the GitHub host key: run `bash ~/anaiis-dotfiles/install.sh --hostkeys-only`.
- **The installer prints `SKIP`.** A real file blocks a link. Back it up, remove it, and run the installer again.
- **The doctor prints `MISSING`.** Run the fix command on that line.
- **One installer part.** Use `--symlinks-only`, `--bashrc-only`, or `--hostkeys-only`.

## License

Anaiis LLC licenses this repo under the Apache License 2.0. The full text is in `LICENSE`. If you redistribute this work, keep the attribution notice in `NOTICE`.

The plugin marketplaces that this repo registers, such as `anaiis-plugins`, are not part of this repo. Each has its own license.
