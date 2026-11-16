# ~/anaiis-dotfiles/bash/shared.bash
#
# Tracked shell preferences, sourced by ~/.bashrc. Edit here, sync with git pull.
# Machine-local overrides (GCP project, API keys) go in ~/.bashrc.local.
#
# Chapters
#   1 Locale             8 Git aliases
#   2 Platform           9 Python aliases
#   3 Homebrew          10 Google Cloud aliases
#   4 PATH and tools    11 Claude aliases
#   5 Claude env        12 CodeRabbit
#   6 Prompt            13 Functions
#   7 Shell aliases     14 Secrets

# ── 1. Locale ─────────────────────────────────────────────────────────────────
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# ── 2. Platform ───────────────────────────────────────────────────────────────
# _os is unset in chapter 7 after the last use.
_os="$(uname -s)"

if [ "$_os" = "Darwin" ]; then
	export BASH_SILENCE_DEPRECATION_WARNING=1
	export CLICOLOR=1
	export LSCOLORS=GxFxCxDxBxegedabagaced
fi

# ── 3. Homebrew ───────────────────────────────────────────────────────────────
# First prefix found wins: Apple Silicon, Intel, Linuxbrew (user, then system).
for _brew_prefix in \
	/opt/homebrew \
	/usr/local \
	"$HOME/.linuxbrew" \
	/home/linuxbrew/.linuxbrew; do
	if [ -x "${_brew_prefix}/bin/brew" ]; then
		eval "$("${_brew_prefix}/bin/brew" shellenv)"
		break
	fi
done
unset _brew_prefix

# Add installed packages to the Brewfile: additive, background, once per day.
# Commit the result from a dotfiles session. Cross-profile prefix access is an
# ACL, see claude/scripts/brew-share.sh.
[ -f "$HOME/anaiis-dotfiles/claude/scripts/brew-sync.sh" ] \
	&& (bash "$HOME/anaiis-dotfiles/claude/scripts/brew-sync.sh" refresh &)

# ── 4. PATH and tool init ─────────────────────────────────────────────────────
# bash-completion: interactive shells only.
if [[ $- == *i* ]] && [ -n "$HOMEBREW_PREFIX" ] && [ -r "$HOMEBREW_PREFIX/etc/profile.d/bash_completion.sh" ]; then
	. "$HOMEBREW_PREFIX/etc/profile.d/bash_completion.sh"
fi

# uv and pipx install tools here.
[ -d "$HOME/.local/bin" ] && export PATH="$PATH:$HOME/.local/bin"

# Google Cloud SDK: PATH always, completion interactive only.
if [ -f "$HOME/google-cloud-sdk/path.bash.inc" ]; then
	. "$HOME/google-cloud-sdk/path.bash.inc"
fi
if [[ $- == *i* ]] && [ -f "$HOME/google-cloud-sdk/completion.bash.inc" ]; then
	. "$HOME/google-cloud-sdk/completion.bash.inc"
fi

if command -v direnv >/dev/null 2>&1; then
	eval "$(direnv hook bash)"
fi

# ── 5. Claude Code environment ────────────────────────────────────────────────
# Plain exports, so a re-source picks up changed defaults. ~/.bashrc.local loads
# after this file and wins. A name here never appears in settings.json "env".

# Models. --model beats ANTHROPIC_MODEL. Each class pins one snapshot.
export ANTHROPIC_MODEL="opusplan"
export ANTHROPIC_DEFAULT_FABLE_MODEL="claude-fable-5-2"
export ANTHROPIC_DEFAULT_OPUS_MODEL="claude-opus-5-5"
export ANTHROPIC_DEFAULT_SONNET_MODEL="claude-sonnet-5-5"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="claude-haiku-4-5"

# Ponytail level. Hook order: this variable, ~/.config/ponytail/config.json, "full".
export PONYTAIL_DEFAULT_MODE="lite"
# pi harness only, Claude Code ignores both (plugin 5.3.2). Non-empty, not 0/false/no, is on.
# export PONYTAIL_HIDE_STATUS=1
# export PONYTAIL_QUIET_STARTUP=1

# Effort and output size. Overrides settings.json "effortLevel".
export CLAUDE_CODE_EFFORT_LEVEL="medium"
export CLAUDE_CODE_MAX_OUTPUT_TOKENS="32000"
export CLAUDE_CODE_DISABLE_MOUSE_CLICKS="0"

# Auto-compact at 60% of context (see rules/session.md). Leave the window unset:
# Claude Code uses the active model's max (967K on Sonnet 5, Opus 5, Fable 5.2;
# 200K on Haiku 4.5).
export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="60"

# cost-guard.sh cap on general-purpose Agent spawns per session. Hooks inherit
# the shell env. The settings.json "env" block does not reach them.
export COST_GUARD_GP_LIMIT="75"

# Privacy and traffic.
# export DISABLE_TELEMETRY="1"
export DISABLE_FEEDBACK_COMMAND="1"
export CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY="1"
export CLAUDE_CODE_SEND_FEEDBACK="0"
export DISABLE_ERROR_REPORTING="1"
export DISABLE_AUTOUPDATER="1"

# Timeouts. Raise BASH_MAX_TIMEOUT_MS in ~/.bashrc.local for long R or DuckDB runs.
export BASH_DEFAULT_TIMEOUT_MS="120000"
export BASH_MAX_TIMEOUT_MS="600000"
export API_TIMEOUT_MS="600000"

# ── 6. Prompt ─────────────────────────────────────────────────────────────────
git_branch() {
	local dir_name branch_name
	dir_name=$(basename "$(pwd)")
	if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
		branch_name=$(git symbolic-ref --short -q HEAD)
		PS1="\[\e[1;32m\]\h\e[0m\]:\[\e[1;34m\][${dir_name}]\[\e[0m\]:\[\e[1;33m\]{${branch_name}}\[\e[0m\] "
	else
		PS1="\[\e[1;32m\]\h\e[0m\]:\[\e[1;34m\][${dir_name}]\[\e[0m\] "
	fi
}
PROMPT_COMMAND="git_branch${PROMPT_COMMAND:+;$PROMPT_COMMAND}"

# ── 7. Shell aliases ──────────────────────────────────────────────────────────
# ls
if [ "$_os" = "Darwin" ]; then
	alias ls='ls -GFhp'
	alias ll='ls -lAGFhp'
	alias lt='ls -lAGFhtr'
	alias l.='ls -dAGFhp .* 2>/dev/null'
else
	alias ls='ls --color=auto -Fhp'
	alias ll='ls --color=auto -lAFhp'
	alias lt='ls --color=auto -lAFhtr'
	alias l.='ls --color=auto -dAFhp .* 2>/dev/null'
fi
unset _os

# Navigation
alias ~='cd ~'
alias cd..='cd ../'
alias ..='cd ../'
alias ...='cd ../../'
alias .3='cd ../../../'
alias .4='cd ../../../../'
alias .5='cd ../../../../../'
alias .6='cd ../../../../../../'

# Utilities. No cp or mv alias: -i prompts, and agent shells answer "n" and skip the copy.
alias mkdir='mkdir -pv'
alias rsync='rsync -hvrP'
alias pwd='pwd -P'
alias du='du -sh'
alias c='clear'
alias bashconfig='vim ~/.bashrc'
alias bashsrc='source ~/.bashrc'

# ── 8. Git aliases ────────────────────────────────────────────────────────────
alias gst='git status'
alias gco='git checkout'
alias gcam='git commit -a'
alias gl='git pull --rebase'
alias gp='git push'
alias gd='git diff'
alias grb='git rebase'
alias gcp='git cherry-pick'
alias gsta='git stash push'
alias gstl='git stash list'
alias gaa='git add --all'
alias grh='git reset --hard'
alias gclean='git clean -fd'
alias glog="git log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset'"

# ── 9. Python aliases ─────────────────────────────────────────────────────────
alias wipe_pip='pip freeze | cut -d "@" -f1 | xargs pip uninstall -y'

# ── 10. Google Cloud aliases ──────────────────────────────────────────────────
alias gc-update='gcloud components update'
alias gc-auth='gcloud auth login; gcloud auth application-default login'
alias gc-authMobile='gcloud auth login --no-launch-browser; gcloud auth application-default login --no-launch-browser'
alias gc-authList='gcloud auth list'

# ── 11. Claude aliases ────────────────────────────────────────────────────────
# bypassPermissions drops the prompt safety net. Protection then rests on
# permissions.deny and the bash-guard and block-sensitive-writes hooks.
# Deliberate tradeoff for a trusted personal workflow.
#
# Each alias carries --model, because --model beats the exported ANTHROPIC_MODEL.
# The family name (fable, opus) resolves through ANTHROPIC_DEFAULT_<FAMILY>_MODEL
# in chapter 5, so a model bump edits that export only. Never use a bare
# claude-opus or claude-fable: Claude Code rejects both.
#
# Tier names differ by family: turbo is high on Fable, xhigh on Opusplan and Opus.

# 11.1 Opusplan (claude-fast uses the exported effort)
alias claude-fast='claude --model opusplan --permission-mode bypassPermissions'
alias claude-turbo='CLAUDE_CODE_EFFORT_LEVEL=xhigh claude --model opusplan --permission-mode bypassPermissions'

# 11.2 Fable
alias claude-fable-fast='CLAUDE_CODE_EFFORT_LEVEL=medium claude --model fable --permission-mode bypassPermissions'
alias claude-fable-turbo='CLAUDE_CODE_EFFORT_LEVEL=high claude --model fable --permission-mode bypassPermissions'
alias claude-fable-hyper='CLAUDE_CODE_EFFORT_LEVEL=xhigh claude --model fable --permission-mode bypassPermissions'
alias claude-fable-max='CLAUDE_CODE_EFFORT_LEVEL=max claude --model fable --permission-mode bypassPermissions'

# 11.3 Opus
alias claude-opus='CLAUDE_CODE_EFFORT_LEVEL=high claude --model opus --permission-mode bypassPermissions'
alias claude-opus-turbo='CLAUDE_CODE_EFFORT_LEVEL=xhigh claude --model opus --permission-mode bypassPermissions'
alias claude-opus-max='CLAUDE_CODE_EFFORT_LEVEL=max claude --model opus --permission-mode bypassPermissions'

# ── 12. CodeRabbit ────────────────────────────────────────────────────────────
alias cr='coderabbit'
alias cr-status='coderabbit auth status'

# cr-login: API-key login, then set the org id in the CLI config.
# Needs CODERABBIT_API_KEY and CODERABBIT_ORG_ID from ~/.bashrc.local.
cr-login() {
	if [ -z "$CODERABBIT_API_KEY" ]; then
		echo "cr-login: CODERABBIT_API_KEY is not set in ~/.bashrc.local" >&2
		return 1
	fi
	if [ -z "$CODERABBIT_ORG_ID" ]; then
		echo "cr-login: CODERABBIT_ORG_ID is not set in ~/.bashrc.local" >&2
		return 1
	fi
	if ! command -v jq >/dev/null 2>&1; then
		echo "cr-login: jq is required but not installed" >&2
		return 1
	fi
	if ! coderabbit auth login --api-key "$CODERABBIT_API_KEY"; then
		echo "cr-login: API key authentication failed" >&2
		return 1
	fi
	local cfg
	if [ -d "$HOME/Library/Application Support/coderabbit" ]; then
		cfg="$HOME/Library/Application Support/coderabbit/user-data.json"
	else
		cfg="${XDG_CONFIG_HOME:-$HOME/.config}/coderabbit/user-data.json"
	fi
	if [ ! -f "$cfg" ]; then
		echo "cr-login: config file not found at $cfg" >&2
		return 1
	fi
	if ! jq --arg id "$CODERABBIT_ORG_ID" '.orgId = $id' "$cfg" >"$cfg.tmp"; then
		echo "cr-login: failed to update orgId in $cfg" >&2
		rm -f "$cfg.tmp"
		return 1
	fi
	mv "$cfg.tmp" "$cfg"
	echo "cr-login: authenticated and org set"
}

# ── 13. Functions ─────────────────────────────────────────────────────────────
mcd() { mkdir -p "$1" && cd "$1"; }

# ── 14. Secrets ───────────────────────────────────────────────────────────────
# Never in shell config (see rules/environment.md). Three tiers:
#   1 CLI-native auth: gh auth login, coderabbit auth login, postman login --with-api-key
#   2 Cross-project vars: ~/.config/secrets/global.env (chmod 600), loaded per
#     project with `dotenv ~/.config/secrets/global.env` in .envrc
#     (QUALTRICS_*, TWILIO_*, CLOUDRESEARCH_*)
#   3 Project vars: that project's .envrc
