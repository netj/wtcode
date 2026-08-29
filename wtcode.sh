#!/usr/bin/env bash
# wtcode -- launch a code tool in a git worktree for a given branch
# https://github.com/netj/wtcode
# Author: Jaeho Shin <netj@sparcs.org>
# Created: 2026-02-03
set -eu
shopt -s extglob
${WTCODE_DEBUG:+set -x}

--msg() { echo "wtcode: $*" >&2; }
@q() {
  local quoted=$({ set +x; } 2>/dev/null; exec 2>&1; PS4=; set -x; : "$@")
  echo "${quoted:2}"  # lstrip the ': ' prefix to get the compact bash-quoted form
}
--sanitize-branch-name() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |   # lowercase
    sed 's/[^a-z0-9/_-]/-/g' |     # replace non-alnum to hyphens
    sed 's/--*/-/g' |              # collapse consecutive hyphens
    sed 's/^-//; s/-$//'           # trim leading/trailing hyphens
}

WTCODE_VERSION=0.4.0
--version() { echo "wtcode $WTCODE_VERSION"; }
--help() {
  cat <<USAGE
wtcode $WTCODE_VERSION -- launch a code tool in a git worktree

Usage: wtcode [BRANCH] [CMD [CMD-ARGS...]]
       wtcode --exec CMD [CMD-ARGS...]

  BRANCH     Git branch or worktree name to switch to.
             If omitted and fzf is available, interactively select one.
             Surround with ':' to force creating a new branch
             (use multiple colons to avoid fzf matching, e.g., :::my-branch
             or my-branch:::).

  CMD        Command to launch in the worktree (default: \$WTCODE_CMD,
             or first available of: ${WTCODE_CMDS_TO_TRY[*]}, \$SHELL).

  --exec     Skip branch argument; select interactively, then launch CMD.

Environment variables:
  WTCODE_CMD             Default tool to launch (e.g., claude, lazygit, vim)
  WTCODE_TMUX_MODE       When in tmux, control how the tool is launched:
                           send-keys    - send command to current pane (default in tmux)
                           split-window - create split pane with send-keys
                           new-window   - create new window with send-keys
                           exec         - exec the tool directly (opt out of send-keys)
  WTCODE_TERMINAL_MODE   Outside tmux, control how the tool is launched:
                           send-keys    - reuse the current tab/window via AppleScript
                                          (default; macOS only). Terminal.app and Ghostty
                                          1.3+ use their own scripting support; any other
                                          terminal falls back to simulated keystrokes
                           exec         - exec the tool directly (opt out of send-keys)
  WTCODE_DEBUG           Enable debug tracing when set
  GIT_WORKTREE_ROOT      Override the directory where worktrees are created

Examples:
  wtcode feature-x                  # select/create worktree, launch default tool
  wtcode feature-x lazygit          # launch lazygit in the worktree
  wtcode feature-x claude --resume  # launch claude with --resume
  wtcode --exec claude --resume     # select interactively, launch claude --resume
  wtcode :new-feature               # create new branch and worktree
  WTCODE_CMD=cursor wtcode feature  # use cursor as the default tool
USAGE
}

# commands to try as default, in order of preference
WTCODE_CMDS_TO_TRY=(
    ${WTCODE_CMD:-}
    claude
    aider
    codex
)

###############################################################################
## --enter-git-worktree -- select branch and create/switch worktree
###############################################################################
--enter-git-worktree() {
  local branch_name=
  WTCODE_WORKTREE_EXISTED=false

  # 1. determine which branch/worktree to use
  if [[ $# -gt 0 ]]; then
    branch_name=$1; shift
  elif type fzf &>/dev/null; then
    # if branch name unspecified, use fzf to select one or enter a new name
    # format: branch_name<TAB>indicator branch_name date hash [upstream] subject
    branch_name=$(
      { set +x; } &>/dev/null
      # NOTE: git branch --format uses ref-filter syntax which doesn't support
      # pretty-format's %<(N,trunc) truncation. Using bash to handle truncation,
      # alignment, and coloring instead.
      c_reset=$'\e[0m' c_green=$'\e[32m' c_cyan=$'\e[36m' c_blue=$'\e[34m' c_yellow=$'\e[33m' c_red=$'\e[31m' c_dim=$'\e[2m'
      {
      git branch --sort=-committerdate \
          --format=$'x%(refname:lstrip=2)\tx%(HEAD)\tx%(worktreepath)\tx%(committerdate:relative)\tx%(objectname:short)\tx%(upstream:track)\tx%(contents:subject)'
      # also include remote-tracking branches that don't have a local counterpart
      local_branches=$(git branch --format='%(refname:lstrip=2)')
      git branch -r --sort=-committerdate \
          --format=$'x%(refname:lstrip=2)\tx>\tx\tx%(committerdate:relative)\tx%(objectname:short)\tx\tx%(contents:subject)' |
      while IFS=$'\t' read -r remote_ref rest; do
        remote_ref=${remote_ref#x}
        [[ $remote_ref == */HEAD ]] && continue
        local_name=${remote_ref#*/}
        grep -qxF "$local_name" <<< "$local_branches" && continue
        printf 'x%s\t%s\n' "$remote_ref" "$rest"
      done
      } |
      while IFS=$'\t' read -r branch head worktree date hash upstream subject; do
        # strip the x prefix from all fields
        branch=${branch#x} head=${head#x} worktree=${worktree#x} date=${date#x} hash=${hash#x} upstream=${upstream#x} subject=${subject#x}
        # determine indicator and color: HEAD (*) takes precedence, then worktree (+)
        if [[ $head == '*' ]]; then ind='*'; c=$c_green
        elif [[ -n $worktree ]]; then ind='+'; c=$c_cyan
        elif [[ $head == '>' ]]; then ind=' '; c=$c_dim
        else ind=' '; c=$c_reset
        fi
        # truncate then pad branch name, right-pad date (before adding colors)
        if (( ${#branch} > 50 )); then name="${branch:0:48}.."; else name=$branch; fi
        printf -v name '%-50s' "$name"
        printf -v date '%14s' "$date"
        # build display fields with colors embedded
        name_shown="${c}${name}${c_reset}"
        date_shown="${c_blue}${date}${c_reset}"
        hash_shown="${c_yellow}${hash}${c_reset}"
        if [[ -n $upstream ]]; then upstream_shown="${c_red}${upstream}${c_reset} "; else upstream_shown=''; fi
        printf '%s\t%s %s\t%s  %s %s%s\n' \
          "$branch" "$ind" "$name_shown" "$date_shown" "$hash_shown" "$upstream_shown" "$subject"
      done |
      fzf --ansi --color --tmux --print-query --delimiter=$'\t' --with-nth=2 --nth=1 \
          --preview 'echo {3}' --preview-window 'down:2:wrap' \
          --prompt 'wtcode: select worktree/branch (prefix : to create new) > ' |
      cut -f1 |
      tail -1
    )
  else  # abort if fzf not available
    branch_name=${1:?Need a worktree/branch name as first argument}; shift
  fi

  if [[ -z ${branch_name-} ]]; then
    --msg "no branch selected"
    exit 1
  fi

  # leading or trailing ':' forces new branch creation
  # multiple colons (e.g., :::my-branch or my-branch:::) help avoid fzf matching
  local force_new_branch=false
  if [[ $branch_name == :* || $branch_name == *: ]]; then
    force_new_branch=true
    branch_name=${branch_name##+(:)}
    branch_name=${branch_name%%+(:)}
    : ${branch_name:?non-empty branch name required around ':'}
  fi

  # sanitize free-form text into a valid git branch name
  # (skip if it already matches an existing branch/ref to preserve case)
  if $force_new_branch || ! git rev-parse --verify "$branch_name" &>/dev/null; then
    branch_name=$(--sanitize-branch-name "$branch_name")
    : ${branch_name:?branch name is empty after sanitization}
  fi

  # check if branch_name refers to a remote branch (e.g., origin/feature-x)
  local remote_branch=
  if ! $force_new_branch; then
    for remote in $(git remote); do
      if [[ $branch_name == "$remote/"* ]]; then
        remote_branch=$branch_name
        branch_name=${branch_name#"$remote/"}
        break
      fi
    done
  fi

  # if the branch is already checked out on a worktree, use that worktree
  # regardless of its directory name — avoids "already checked out" failures
  # when branches and worktree directories have drifted apart (e.g., after
  # something like claude ran `git checkout` inside a worktree)
  if ! $force_new_branch && [[ -z ${remote_branch-} ]]; then
    local existing_worktree
    existing_worktree=$(git for-each-ref --format='%(worktreepath)' "refs/heads/$branch_name" 2>/dev/null)
    if [[ -n $existing_worktree ]]; then
      --msg "branch '$branch_name' is checked out at: $existing_worktree"
      cd "$existing_worktree"
      WTCODE_WORKTREE_EXISTED=true
      return 0
    fi
  fi

  # 2. create or switch to the worktree
  cd "$(git rev-parse --show-toplevel)"
  : ${GIT_WORKTREE_ROOT:=$(
    git_common_dir=$(git rev-parse --git-common-dir)
    cd "$git_common_dir"
    cd ..
    repo_name=$(basename "$PWD")
    echo "$PWD"/../"$repo_name".worktrees
  )}

  local worktree_path="$GIT_WORKTREE_ROOT"/"$branch_name"

  # if the default worktree directory exists but holds a different branch
  # (e.g., something like claude swapped branches with `git checkout`), pick
  # a fresh numbered suffix instead of stealing it. branch-is-checked-out
  # case is already handled above, so we only need to check the default path.
  if [[ -e "$worktree_path"/.git ]]; then
    local existing_branch
    existing_branch=$(git -C "$worktree_path" branch --show-current 2>/dev/null)
    if [[ -n $existing_branch && $existing_branch != "$branch_name" ]]; then
      --msg "$worktree_path holds branch '$existing_branch'; picking a new path for '$branch_name'"
      local n=2
      while [[ -e "$GIT_WORKTREE_ROOT/$branch_name-$n" ]]; do
        n=$((n+1))
      done
      worktree_path="$GIT_WORKTREE_ROOT/$branch_name-$n"
    fi
  fi

  if [[ -e "$worktree_path"/.git ]]; then
    --msg "using existing worktree: $worktree_path"
    WTCODE_WORKTREE_EXISTED=true
  elif [[ -n ${remote_branch-} ]] && ! git rev-parse --verify "refs/heads/$branch_name" &>/dev/null; then
    # remote branch: create local tracking branch in a new worktree
    --msg "creating worktree for remote branch: $remote_branch"
    git worktree add -b "$branch_name" "$worktree_path" "$remote_branch"
    git -C "$worktree_path" branch --set-upstream-to="$remote_branch" "$branch_name"
  elif git rev-parse "$branch_name" &>/dev/null; then
    # branch exists, just check it out in a new worktree with the same name
    --msg "creating worktree for branch: $branch_name"
    git worktree add -B "$branch_name" "$worktree_path" "$(git rev-parse "$branch_name")"
  else
    # fork the current HEAD and create the new worktree
    --msg "creating worktree with new branch: $branch_name"
    git worktree add -b "$branch_name" "$worktree_path" "$(git rev-parse HEAD)"
  fi
  cd "$worktree_path"

  # ensure the branch is checked out on the worktree
  [[ $(git branch --show-current) = $branch_name ]] ||
    git checkout "$branch_name" --
}

###############################################################################
## --provision-claude-settings -- Claude Code setup, only when launching claude
###############################################################################
# Everything Claude-Code-specific lives here so it runs once, synchronously,
# before dispatch -- regardless of tmux mode -- and only when the resolved
# tool is actually `claude`. See the call site in --launch-code-tool.
--provision-claude-settings() {
  # auto-trust this worktree in Claude Code's global config. Newer Claude
  # Code versions also gate a separate "pre-approves N tool permissions"
  # onboarding screen (shown when .claude/settings.local.json grants
  # auto-approve rules) that hasTrustDialogAccepted alone doesn't suppress --
  # hasCompletedProjectOnboarding is needed too.
  if type jq &>/dev/null && [[ -f ~/.claude.json ]]; then
    (
      export worktree_path="$PWD"
      jq -e '.projects[env.worktree_path]' ~/.claude.json &>/dev/null || {
        jq '.projects[env.worktree_path] = ({} | .hasTrustDialogAccepted = true | .hasCompletedProjectOnboarding = true)' \
          ~/.claude.json >~/.claude.json.wtcode.$$
        mv -f ~/.claude.json.wtcode.$$ ~/.claude.json
      }
    )
  fi

  # symlink project-local settings from the main worktree, if not already
  # present here -- never clobber a file that's git-tracked, hook-provisioned,
  # or already customized in this worktree (including from a prior run: a
  # dangling/previously-created symlink also counts as "already present").
  local main_root
  main_root=$(
    git_common_dir=$(git rev-parse --git-common-dir)
    cd "$git_common_dir"
    cd ..
    pwd
  )
  [[ -d "$main_root/.claude" ]] || return 0   # nothing to provision from
  [[ "$main_root" == "$PWD" ]] && return 0    # already in the main worktree

  local name created_names=()
  for name in settings.json settings.local.json; do
    local src="$main_root/.claude/$name" dst="$PWD/.claude/$name"
    [[ -e "$src" ]] || continue                 # nothing to link
    [[ -e "$dst" || -L "$dst" ]] && continue    # don't clobber existing/broken link
    mkdir -p "$PWD/.claude"                     # safe no-op if .claude/ (with other content) already exists
    ln -s "$src" "$dst"
    --msg "symlinked .claude/$name from main worktree"
    created_names+=("$name")
  done

  (( ${#created_names[@]} > 0 )) || return 0

  local gi="$PWD/.claude/.gitignore"
  [[ -e $gi ]] && return 0   # respect a pre-existing, possibly customized file

  local already_ignored=true
  for name in "${created_names[@]}"; do
    git check-ignore -q ".claude/$name" || already_ignored=false
  done
  $already_ignored && return 0

  {
    echo '# wtcode: symlinked from the main worktree; never commit these here'
    echo 'settings.json'
    echo 'settings.local.json'
  } >"$gi"
  --msg "created .claude/.gitignore"
}

###############################################################################
## --terminal-send-keys -- tmux-like send-keys for GUI terminal apps
###############################################################################
# Reuses the current tab/window in the surrounding terminal app, outside
# tmux. cd_cmd/run_cmd are sent as two separate lines rather than one
# `cd X && cmd` line, since the shell's PROMPT_COMMAND (what updates the
# tab/window title via OSC 7/6) only fires between commands, at the next
# prompt -- a single `&&` line never shows one, so the title would stay
# stale for as long as cmd runs.
#
# macOS-only: dispatches on $TERM_PROGRAM by looking for a matching
# --terminal-send-keys--macos--$TERM_PROGRAM function -- add support for
# another terminal app by just defining one, named to match its
# $TERM_PROGRAM value exactly. `type osascript` fails (and this returns 1)
# on any other platform, so this whole mechanism is a no-op there and
# callers just fall back to exec. Also returns 1 if there's no terminal
# emulator signal (TERM_PROGRAM/TERMINAL_EMULATOR, as in ~/.zprofile) at all.
--terminal-send-keys() {
  local worktree_path="$PWD"
  local cd_cmd="cd $(@q "$worktree_path")"
  local run_cmd="$(@q "$@")"

  # TODO: support Linux/general-unix terminals (and SSH sessions) too --
  # e.g. terminals with OSC 7/6 + a way to inject text (wezterm cli,
  # kitty @ send-text, iterm2's escape sequences, etc). For now this whole
  # mechanism is macOS-only and returns 1 (falls back to exec) elsewhere.
  type osascript &>/dev/null || return 1

  local termprog=${TERM_PROGRAM-${TERMINAL_EMULATOR-}}
  [[ -n $termprog ]] || return 1
  if type -- "--terminal-send-keys--macos--$termprog" &>/dev/null; then
    "--terminal-send-keys--macos--$termprog" "$cd_cmd" "$run_cmd"
  else
    --terminal-send-keys--macos--system-events "$cd_cmd" "$run_cmd"
  fi
}

# `do script ... in front window`: reuses Terminal's front window via a real
# Apple Event, not a keystroke. `osascript -` reads the script from stdin;
# without it, osascript treats argv[0] as a script *file* path.
--terminal-send-keys--macos--Apple_Terminal() {
  local result
  result=$(osascript - "$@" <<'APPLESCRIPT'
on run argv
  tell application "Terminal"
    try
      repeat with line_cmd in argv
        do script (line_cmd as text) in front window
      end repeat
      set frontmost of front window to true
      return "OK"
    on error
      return "NOTFOUND"
    end try
  end tell
end run
APPLESCRIPT
  ) || return 1
  [[ $result == OK ]]
}

# Ghostty 1.3+ ships a real AppleScript dictionary: `input text ... to
# term` targets the terminal focused in the front window's selected tab.
# Falls back to --macos--system-events since this is still a young feature.
--terminal-send-keys--macos--ghostty() {
  local result rc
  result=$(osascript - "$@" <<'APPLESCRIPT'
on run argv
  tell application "Ghostty"
    try
      set term to focused terminal of selected tab of front window
      repeat with line_cmd in argv
        input text ((line_cmd as text) & "\n") to term
      end repeat
      return "OK"
    on error
      return "NOTFOUND"
    end try
  end tell
end run
APPLESCRIPT
  ); rc=$?
  [[ $rc -eq 0 && $result == OK ]] || --terminal-send-keys--macos--system-events "$@"
}

# Last resort: fake keystrokes via System Events (needs Accessibility
# permission). No `activate` call -- $TERM_PROGRAM isn't always a real app
# name, so this relies on the calling terminal still being frontmost.
--terminal-send-keys--macos--system-events() {
  local result
  result=$(osascript - "$@" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    try
      repeat with line_cmd in argv
        keystroke (line_cmd as text)
        key code 36 -- Return
        delay 0.05
      end repeat
      return "OK"
    on error
      return "NOTFOUND"
    end try
  end tell
end run
APPLESCRIPT
  ) || return 1
  [[ $result == OK ]]
}

###############################################################################
## --launch-code-tool -- resolve and exec the tool in the worktree
###############################################################################
--launch-code-tool() {
  # resolve the command to launch if not specified
  if [[ $# -eq 0 ]]; then
    for _cmd in "${WTCODE_CMDS_TO_TRY[@]}"; do
      [[ -n "$_cmd" ]] && type "$_cmd" &>/dev/null && set -- "$_cmd" && break
    done
    # fall back to an interactive shell
    [[ $# -gt 0 ]] || set -- "${SHELL:-bash}"
  fi

  # default to resuming the last session when relaunching claude in a
  # worktree that already existed; press Esc in the picker to start fresh
  # instead. only kicks in when no CMD-ARGS were given, so explicit flags
  # (e.g. `claude --resume`) are never overridden.
  if [[ $1 == claude && $# -eq 1 && ${WTCODE_WORKTREE_EXISTED:-false} == true ]]; then
    set -- "$1" /resume
  fi

  [[ $1 == claude ]] && --provision-claude-settings

  --msg "launching: $*"

  # when inside tmux, default to send-keys for command history access
  # set WTCODE_TMUX_MODE=exec to opt out and exec directly
  if [[ -n ${TMUX:-} ]] && type tmux &>/dev/null; then
    local mode=${WTCODE_TMUX_MODE:-send-keys}

    case $mode in
      send-keys|split-window|new-window)
        local worktree_path="$PWD"
        local cmd="cd $(@q "$worktree_path") && $(@q "$@")"

        case $mode in
          send-keys)
            # send to current pane
            tmux send-keys "$cmd" Enter
            return 0
            ;;
          split-window)
            # create split, send there
            tmux split-window -v -c "$worktree_path"
            tmux send-keys "$cmd" Enter
            return 0
            ;;
          new-window)
            # create window, send there
            tmux new-window -c "$worktree_path"
            tmux send-keys "$cmd" Enter
            return 0
            ;;
        esac
        ;;
      exec)
        # explicitly opt out of send-keys, fall through to exec
        ;;
      *)
        --msg "unknown WTCODE_TMUX_MODE: $mode (expected: send-keys, split-window, new-window, exec)"
        ;;
    esac
  fi

  # outside tmux: reuse the current tab/window if the terminal app supports
  # it (see --terminal-send-keys). set WTCODE_TERMINAL_MODE=exec to opt out
  if [[ -z ${TMUX:-} ]]; then
    local mode=${WTCODE_TERMINAL_MODE:-send-keys}
    case $mode in
      send-keys)
        if --terminal-send-keys "$@"; then
          return 0
        fi
        --msg "could not reuse the current tab/window; falling back to exec"
        ;;
      exec)
        # explicitly opt out of send-keys, fall through to exec
        ;;
      *)
        --msg "unknown WTCODE_TERMINAL_MODE: $mode (expected: send-keys, exec)"
        ;;
    esac
  fi

  # outside tmux, WTCODE_TMUX_MODE=exec, unsupported terminal, or unknown mode: exec directly
  exec "$@"
}

###############################################################################
## main
###############################################################################

-h() { --help "$@"; }

--exec() {
  --enter-git-worktree
  --launch-code-tool "$@"
}

--() {
  if [[ $# -gt 0 ]]; then
    --enter-git-worktree "$1"; shift
  else
    --enter-git-worktree
  fi
  --launch-code-tool "$@"
}

# dispatch $1 as a function when it starts with -
[[ ${1-} == -* ]] || set -- -- "$@"
"$@"
