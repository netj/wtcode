#!/usr/bin/env bash
# wtcode -- launch a code tool in a git worktree for a given branch
# https://github.com/netj/wtcode
# Author: Jaeho Shin <netj@sparcs.org>
# Created: 2026-02-03
set -eu
shopt -s extglob

# detect well-known AI coding agents via the env vars they set on their own
# subprocesses -- send-keys/AppleScript fire into whatever pane/tab/window
# happens to be current, which is unsafe to do behind an agent's back while
# it's working (it may be a pane/window the user is watching, or one running
# an unrelated task). exec is always safe: it just replaces the agent's own
# child process.
--running-under-coding-agent() {
  [[ -n ${CLAUDECODE:-} || -n ${CURSOR_AGENT:-} || -n ${GEMINI_CLI:-} ||
     -n ${CODEX_SANDBOX:-} || -n ${CODEX_SANDBOX_NETWORK_DISABLED:-} ]]
}

# declare all WTCODE_* env vars and their defaults in one place
: ${WTCODE_CMD:=}
: ${WTCODE_USE_CURRENT_BRANCH:=false}
: ${WTCODE_BASE_REF:=}          # ref to fork new branches from (also: --base REF)
: ${WTCODE_BRANCH_SCOPE:=}      # initial picker scope: all|worktree|local|remote
: ${WTCODE_BRANCH_ORDER:=}      # initial picker order: recent|name|type
# where the picker remembers its last state; set to empty to disable
: ${WTCODE_STATE_FILE=${XDG_STATE_HOME:-$HOME/.local/state}/wtcode/state}
if --running-under-coding-agent; then
  : ${WTCODE_TMUX_MODE:=exec}
  : ${WTCODE_TERMINAL_MODE:=exec}
else
  : ${WTCODE_TMUX_MODE:=send-keys}
  : ${WTCODE_TERMINAL_MODE:=send-keys}
fi
: ${WTCODE_DEBUG:=}
export WTCODE_BASE_REF WTCODE_USE_CURRENT_BRANCH   # key-binding callbacks run as child processes

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
    sed 's|//*|/|g' |              # collapse consecutive slashes
    sed 's|-*/-*|/|g' |            # no hyphens adjacent to slashes
    sed 's|^[-/]*||; s|[-/]*$||'   # trim leading/trailing hyphens/slashes
}

WTCODE_VERSION=0.6.0
--version() { echo "wtcode $WTCODE_VERSION"; }
--help() {
  cat <<USAGE
wtcode $WTCODE_VERSION -- launch a code tool in a git worktree

Usage: wtcode [--base REF] [BRANCH] [CMD [CMD-ARGS...]]
       wtcode --exec CMD [CMD-ARGS...]

  BRANCH     Git branch or worktree name to switch to.
             If omitted and fzf is available, interactively select one.
             Surround with ':' to force creating a new branch
             (use multiple colons to avoid fzf matching, e.g., :::my-branch
             or my-branch:::).

  CMD        Command to launch in the worktree (default: \$WTCODE_CMD,
             or first available of: ${WTCODE_CMDS_TO_TRY[*]}, \$SHELL).

  --exec     Skip branch argument; select interactively, then launch CMD.

  --base REF Fork a brand-new branch from REF (same as \$WTCODE_BASE_REF).

Interactive picker keys (when BRANCH is omitted):
  ctrl-s     scope: all, worktree, local, remote (all and worktree also show and
             match a worktree directory that drifted from its branch name
             or sits outside the main checkout and worktrees root)
  ctrl-o     order: recent, name (remote shown as a suffix), remote/name
  ctrl-r     base for a new branch: the default, or the current branch
  ctrl-t     tool: nested picker of installed tools and recent commands;
             type a new command/args to launch it (unless CMD was given)
  alt-enter  create a new branch named after what you typed (never the
             highlighted one); plain Enter does that too when nothing matches
  ctrl-l     git remote update, then reload
  Changes made in the picker are remembered for next time, even if canceled.

Environment variables:
  WTCODE_CMD             Default tool to launch (e.g., claude, lazygit, vim)
  WTCODE_USE_CURRENT_BRANCH
                         When creating a brand-new branch, fork it from the
                         current HEAD instead of the default: origin/HEAD
                         (falling back to origin/main, then origin/master)
  WTCODE_BASE_REF        Fork brand-new branches from this ref (overrides the above)
  WTCODE_BRANCH_SCOPE    Initial picker scope (all|worktree|local|remote)
  WTCODE_BRANCH_ORDER    Initial picker order (recent|name|full)
  WTCODE_STATE_FILE      Where the picker remembers its last state
                         (default: \$XDG_STATE_HOME/wtcode/state; empty disables)
  WTCODE_TMUX_MODE       When in tmux, control how the tool is launched:
                           send-keys    - send command to current pane (default in tmux,
                                          unless run by a known AI coding agent -- see below)
                           split-window - create split pane with send-keys
                           new-window   - create new window with send-keys
                           exec         - exec the tool directly (opt out of send-keys)
  WTCODE_TERMINAL_MODE   Outside tmux, control how the tool is launched:
                           send-keys    - reuse the current tab/window via AppleScript
                                          (default; macOS only, unless run by a known AI
                                          coding agent -- see below). Terminal.app and
                                          Ghostty 1.3+ use their own scripting support;
                                          any other terminal falls back to simulated
                                          keystrokes
                           exec         - exec the tool directly (opt out of send-keys)

                         When wtcode is invoked by a known AI coding agent (detected via
                         CLAUDECODE, CURSOR_AGENT, GEMINI_CLI, CODEX_SANDBOX, or
                         CODEX_SANDBOX_NETWORK_DISABLED), both modes default to exec
                         instead of send-keys, since send-keys/AppleScript would inject
                         keystrokes into a pane/tab/window the agent doesn't control while
                         it's still working. Set the env var explicitly to override.
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
    $WTCODE_CMD
    claude
    aider
    codex
)

###############################################################################
## --default-base-ref -- ref to fork a brand-new branch from
###############################################################################
# defaults to origin/HEAD (falling back to origin/main, then origin/master),
# so new worktrees start from the repo's default branch instead of whatever
# happens to be checked out where wtcode was invoked. set
# WTCODE_USE_CURRENT_BRANCH=true to restore the old behavior of forking from
# the current HEAD. only consults local remote-tracking refs -- never
# touches the network.
--default-base-ref() {
  if [[ -n $WTCODE_BASE_REF ]]; then
    echo "$WTCODE_BASE_REF"
    return
  fi
  if [[ $WTCODE_USE_CURRENT_BRANCH == true ]]; then
    git rev-parse HEAD
    return
  fi
  local ref
  for ref in origin/HEAD origin/main origin/master; do
    git rev-parse --verify -q "$ref" &>/dev/null && { echo "$ref"; return; }
  done
  git rev-parse HEAD
}

###############################################################################
## interactive picker support -- remembered state, key-binding callbacks
###############################################################################
# The fzf picker lets you cycle some options with key bindings:
#   ctrl-s scope   ctrl-o order   ctrl-r base ref   ctrl-l update
#   alt-enter  create a new branch named after what you typed, not the highlighted one
#   ctrl-t tool: opens a nested picker of installed tools and recently
#           launched commands; type anything to launch a new command/args
# The current values live in small files under a temp dir ($1 of the --fzf-*
# callbacks, which fzf runs as separate processes); every change is also saved
# to $WTCODE_STATE_FILE right away, for next time. none of this is touched when
# a BRANCH is given on the command line.

WTCODE_SCOPES=(all worktree local remote)
WTCODE_ORDERS=(recent name full)   # full: sort by remote/name, name: by name alone

--self() {
  local src=${BASH_SOURCE[0]}
  echo "$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
}

# --state-get KEY -- last remembered value (empty if none)
--state-get() {
  [[ -n $WTCODE_STATE_FILE && -r $WTCODE_STATE_FILE ]] || return 0
  sed -n "s/^$1=//p" "$WTCODE_STATE_FILE" | tail -1
}

# --state-save KEY=VALUE... -- remember values, keeping the other keys
--state-save() {
  [[ -n $WTCODE_STATE_FILE ]] || return 0
  {
    mkdir -p "$(dirname "$WTCODE_STATE_FILE")"
    local tmp=$WTCODE_STATE_FILE.$$ kv
    { [[ -r $WTCODE_STATE_FILE ]] && cat "$WTCODE_STATE_FILE"; true; } > "$tmp"
    for kv; do
      grep -v "^${kv%%=*}=" "$tmp" > "$tmp.2" || true
      echo "$kv" >> "$tmp.2"
      mv "$tmp.2" "$tmp"
    done
    mv "$tmp" "$WTCODE_STATE_FILE"
  } 2>/dev/null || --msg "could not save state to $WTCODE_STATE_FILE"
}

# --pick-valid VALUE DEFAULT CHOICES... -- VALUE if among CHOICES, else DEFAULT
--pick-valid() {
  local v=$1 d=$2 c; shift 2
  for c; do [[ $c == "$v" ]] && { echo "$v"; return; }; done
  echo "$d"
}

# --next-in-cycle CURRENT ITEMS... -- the item after CURRENT, wrapping around
--next-in-cycle() {
  local cur=$1 item take=false; shift
  for item; do
    $take && { echo "$item"; return; }
    [[ $item == "$cur" ]] && take=true
  done
  echo "$1"
}

# --base-ref-for MODE -- the ref a new branch is forked from in each base mode
--base-ref-for() {
  case $1 in
    current) echo HEAD ;;
    origin)  git rev-parse --verify -q origin/HEAD &>/dev/null && echo origin/HEAD || --default-base-ref ;;
    *)       --default-base-ref ;;
  esac
}

# --base-modes -- the distinct bases ^r cycles: default, current branch, and
# origin/HEAD (only when that isn't what default already is)
--base-modes() {
  local def head; def=$(--default-base-ref); head=$(git rev-parse HEAD 2>/dev/null) || head=
  echo default
  [[ $def == "$head" ]] || echo current   # default fell back to HEAD: same thing
  [[ $(--base-ref-for origin) == "$def" ]] || echo origin
}

# --base-label MODE -- "<exact branch> (why)", what a new branch would fork from
--base-label() {
  local ref name
  case $1 in
    current) name=$(git branch --show-current 2>/dev/null); echo "${name:-HEAD} (current)" ;;
    origin)  echo "$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null || echo origin/HEAD) (origin/HEAD)" ;;
    *)
      ref=$(--default-base-ref)
      if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then name=$(git branch --show-current 2>/dev/null); name=${name:-HEAD}
      elif [[ $ref == origin/HEAD ]]; then name=$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null || echo "$ref")
      else name=$ref
      fi
      echo "$name (default)" ;;
  esac
}

# --available-tools -- installed tools worth offering, one per line
--available-tools() {
  local c seen=' '
  for c in ${WTCODE_CMD:+"$WTCODE_CMD"} "${WTCODE_CMDS_TO_TRY[@]}" "${SHELL:-bash}"; do
    [[ -n $c && $seen != *" $c "* ]] || continue
    # an explicit $WTCODE_CMD is always offered; the rest only if installed
    if [[ $c == "${WTCODE_CMD-}" ]] || type "$c" &>/dev/null; then
      echo "$c"; seen+="$c "
    fi
  done
}

# --fzf-init -- make the state dir for one picker session, print its path
--fzf-init() {
  local dir v
  dir=$(mktemp -d "${TMPDIR:-/tmp}/wtcode.XXXXXX")
  # env vars/args win over what was remembered
  v=${WTCODE_BRANCH_SCOPE:-$(--state-get scope)}
  --pick-valid "$v" all "${WTCODE_SCOPES[@]}" > "$dir/scope"
  v=${WTCODE_BRANCH_ORDER:-$(--state-get order)}
  --pick-valid "$v" recent "${WTCODE_ORDERS[@]}" > "$dir/order"
  if [[ -n $WTCODE_BASE_REF || $WTCODE_USE_CURRENT_BRANCH == true ]]; then
    echo default > "$dir/base"
  else
    --pick-valid "$(--state-get base)" default $(--base-modes) > "$dir/base"
  fi
  --base-label "$(<"$dir/base")" > "$dir/base_label"
  if [[ -n ${WTCODE_TOOL_FIXED-} ]]; then
    echo "$WTCODE_TOOL_FIXED" > "$dir/tool_fixed"
  else
    # initial: $WTCODE_CMD, else the last used command if still installed,
    # else the first installed tool
    v=${WTCODE_CMD:-$(--state-get tool)}
    [[ -n $WTCODE_CMD ]] || type "${v%% *}" &>/dev/null || v=$(--available-tools | head -1)
    echo "$v" > "$dir/tool"
  fi
  echo "$dir"
}

# --fzf-commit DIR -- apply the final picker state (changes were already saved
# as they were made, so they survive canceling too)
--fzf-commit() {
  local dir=$1 base tool
  base=$(<"$dir/base")
  [[ $base == default ]] || WTCODE_BASE_REF=$(--base-ref-for "$base")
  if [[ -r $dir/tool ]]; then
    tool=$(<"$dir/tool")
    WTCODE_PICKED_TOOL=$tool
    --history-add "$tool"
  fi
}

# --fzf-cycle DIR KIND -- advance scope|order|base|tool to its next value
--fzf-cycle() {
  local dir=$1 kind=$2 choices
  case $kind in
    scope) choices=("${WTCODE_SCOPES[@]}") ;;
    order) choices=("${WTCODE_ORDERS[@]}") ;;
    base)  choices=($(--base-modes)) ;;
  esac
  --next-in-cycle "$(<"$dir/$kind")" "${choices[@]}" > "$dir/$kind.new"
  mv "$dir/$kind.new" "$dir/$kind"
  --state-save "$kind=$(<"$dir/$kind")"   # remembered right away, even if the picker is canceled
  [[ $kind == base ]] && --base-label "$(<"$dir/base")" > "$dir/base_label"
  return 0
}

# recently launched commands, most recent first
--history-file() { [[ -n $WTCODE_STATE_FILE ]] && echo "$WTCODE_STATE_FILE.cmds" || true; }
--history-add() {
  local f; f=$(--history-file); [[ -n $f && -n $1 ]] || return 0
  { { echo "$1"; grep -vxF -- "$1" "$f" 2>/dev/null || true; } | head -20 > "$f.new" && mv "$f.new" "$f"; } 2>/dev/null || true
}

# --fzf-pick-tool DIR -- nested picker for the tool (run via ctrl-t)
# lists recent commands and installed tools; typing text that matches nothing
# (or pressing alt-enter) takes the typed text as-is, e.g. `claude --resume`
--fzf-pick-tool() {
  local dir=$1 f out query key choice prompt='tool> '
  [[ -e $dir/in_popup ]] || prompt='wtcode tool> '
  f=$(--history-file)
  out=$(
    { [[ -n $f && -r $f ]] && cat "$f"; --available-tools; } | awk '!seen[$0]++' |
    fzf --print-query --expect alt-enter --prompt "$prompt" --height 100% --layout reverse \
        --header 'Pick a tool/recent command, or type a new command with args.
enter: pick highlighted (or typed text if nothing matches)   alt-enter: use typed text as-is' ||
    true
  )
  # fzf prints just the query when nothing matches, else query, key, choice
  { read -r query || true; read -r key || true; read -r choice || true; } <<< "$out"
  if [[ $key == alt-enter || -z $choice ]]; then choice=$query; fi
  if [[ -n $choice ]]; then
    echo "$choice" > "$dir/tool"
    # remembered right away: it's a deliberate choice that should survive
    # canceling the main picker
    --state-save tool="$choice"
    --history-add "$choice"
  fi
  return 0
}

# --tmux-at-least MAJOR MINOR -- is the running tmux at least this version?
--tmux-at-least() {
  local v; v=$(tmux -V 2>/dev/null) || return 1
  [[ $v =~ ([0-9]+)\.([0-9]+) ]] || return 1
  (( BASH_REMATCH[1] > $1 || (BASH_REMATCH[1] == $1 && BASH_REMATCH[2] >= $2) ))
}

# --fzf-pick DIR -- run the picker, print fzf's output (query, then selection).
# inside tmux, fzf's own --tmux is NOT used: since tmux 3.7/fzf 0.7x it opens
# a floating *pane*, whose keys go through tmux's key tables, so the prefix
# (e.g. OPTMUX's C-t) and root bindings (bind -n) get swallowed before fzf
# sees them. a display-popup overlay hands every key to the program instead.
--fzf-pick() {
  local dir=$1
  if [[ -n ${TMUX:-} ]] && type tmux &>/dev/null && --tmux-at-least 3 3; then
    local self cmd envs=() v
    self=$(--self)
    # started marks that the popup really ran: if it was then dismissed (Esc on
    # the popup, client detached, ...) that's a cancel, NOT a reason to fall
    # back to showing a second, different picker
    printf -v cmd ': > %q; %q %q --fzf-run %q > %q' "$dir/started" "$BASH" "$self" "$dir" "$dir/out"
    : > "$dir/in_popup"
    # a popup doesn't inherit our environment; pass along what matters
    for v in $(compgen -e); do
      [[ $v =~ ^(PATH|HOME|SHELL|USER|LOGNAME|TMPDIR|LANG|LC_[A-Z]+|XDG_[A-Z_]+|WTCODE_[A-Z_]+|GIT_[A-Z_]+|FZF_[A-Z_]+)$ ]] &&
        envs+=(-e "$v=${!v}")
    done
    tmux display-popup -E ${TMUX_PANE:+-t "$TMUX_PANE"} -d "$PWD" -w 90% -h 70% -b rounded \
         -T ' wtcode ' ${envs[@]+"${envs[@]}"} "$cmd" 2>/dev/null || true
    if [[ -e $dir/started ]]; then
      cat "$dir/out" 2>/dev/null || true   # (empty when dismissed or canceled)
      return 0
    fi
    rm -f "$dir/in_popup"   # no client to show a popup on, etc.: fall back
  fi
  --fzf-run "$dir"
}

# --fzf-run DIR -- the picker itself (also what runs inside the tmux popup)
--fzf-run() {
  local dir=$1 self b dir_q
  { set +x; } &>/dev/null
  self=$(--self)
  printf -v b '%q %q' "$BASH" "$self"   # command prefix for the key bindings
  printf -v dir_q '%q' "$dir"
  local opts=() prompt='branch> '
  # a popup is titled ' wtcode '; anywhere else the prompt says what this is
  [[ -e $dir/in_popup ]] || { opts+=(--tmux 90%,70%); prompt="wtcode $prompt"; }
  if [[ ! -e $dir/tool_fixed ]]; then
    opts+=(--bind "ctrl-t:execute($b --fzf-pick-tool $dir_q)+transform-header($b --fzf-header $dir_q)")
  fi
  --list-branches "$(<"$dir/scope")" "$(<"$dir/order")" |
  fzf --ansi --color --print-query --delimiter=$'\t' --with-nth=2 --nth=1 \
      --preview 'echo {3}' --preview-window 'down:2:wrap' \
      --header "$(--fzf-header "$dir")" \
      --bind "ctrl-s:execute-silent($b --fzf-cycle $dir_q scope)+reload($b --fzf-list $dir_q)+transform-header($b --fzf-header $dir_q)" \
      --bind "ctrl-o:execute-silent($b --fzf-cycle $dir_q order)+reload($b --fzf-list $dir_q)+transform-header($b --fzf-header $dir_q)" \
      --bind "ctrl-r:execute-silent($b --fzf-cycle $dir_q base)+transform-header($b --fzf-header $dir_q)" \
      --bind "ctrl-l:execute-silent(: > $dir_q/updating)+transform-header($b --fzf-header $dir_q)+reload($b --fzf-update $dir_q)" \
      --bind "alt-enter:execute-silent(: > $dir_q/force_new)+accept" \
      --bind "load:transform-header($b --fzf-header $dir_q)" \
      ${opts[@]+"${opts[@]}"} \
      --prompt "$prompt" || true
}

--fzf-list() { --list-branches "$(<"$1/scope")" "$(<"$1/order")"; }

--fzf-update() {
  GIT_TERMINAL_PROMPT=0 git remote update </dev/null &>/dev/null || true
  rm -f "$1/updating"   # (the header, in place, goes back on the next result)
  --fzf-list "$1"
}

# --fzf-header DIR -- the current values are bold (fzf --ansi styles headers)
--fzf-header() {
  local dir=$1 scope order tool update b=$'\e[1m' r=$'\e[0m'
  case $(<"$dir/scope") in
    worktree) scope=worktrees ;;
    *)        scope="$(<"$dir/scope") branches" ;;   # all/local/remote branches
  esac
  case $(<"$dir/order") in full) order=remote/name ;; *) order=$(<"$dir/order") ;; esac
  if [[ -r $dir/tool_fixed ]]; then tool="tool: $b$(<"$dir/tool_fixed")$r (given)"; else tool="^t tool: $b$(<"$dir/tool")$r"; fi
  update='^l update remotes'
  [[ ! -e $dir/updating ]] || update="^l ${b}updating remotes...$r"   # inline: the rest of the header stays
  echo "Enter: select, or create if nothing matches   $tool"
  echo "alt-enter: create new worktree   ^r branch from: $b$(<"$dir/base_label")$r"
  echo "^s scope: $b$scope$r   ^o order: $b$order$r   $update"
}

# --list-branches [SCOPE] [ORDER] -- candidates for the picker
# format: branch_name<TAB>indicator branch_name<TAB>date hash [upstream] subject
--list-branches() {
  local scope=${1:-all} order=${2:-recent}
  { set +x; } &>/dev/null
  # NOTE: git branch --format uses ref-filter syntax which doesn't support
  # pretty-format's %<(N,trunc) truncation. Using bash to handle truncation,
  # alignment, and coloring instead.
  local c_reset=$'\e[0m' c_green=$'\e[32m' c_cyan=$'\e[36m' c_blue=$'\e[34m' c_yellow=$'\e[33m' c_muted=$'\e[2;90m'   # dim gray: the remote/ part and worktree paths
  local c_red=$'\e[31m' local_branches sort_args
  local_branches=$(git branch --format='%(refname:lstrip=2)')
  # the two places worktrees are expected: the main checkout, and the root
  # where wtcode puts the rest (see --enter-git-worktree)
  local main_wt wt_root=${GIT_WORKTREE_ROOT:-}
  main_wt=$(cd "$(git rev-parse --git-common-dir)/.." 2>/dev/null && pwd -P) || main_wt=
  [[ -z $wt_root && -z $main_wt ]] || : ${wt_root:=$main_wt.worktrees}
  case $order in
    name) sort_args=(-k3,3f -k1,1n) ;;   # by name alone; local before remote on ties
    full) sort_args=(-k4,4f) ;;          # by remote/name
    *)    sort_args=(-k1,1n -k2,2nr) ;;  # local first, then remote, each by recency
  esac
  {
    # stage 1: isremote epoch namekey, then the x-prefixed fields (x keeps
    # read from collapsing empty tab-separated ones)
    if [[ $scope == all || $scope == local || $scope == worktree ]]; then
      git branch --format=$'%(committerdate:unix)\tx%(refname:lstrip=2)\tx%(HEAD)\tx%(worktreepath)\tx%(committerdate:relative)\tx%(objectname:short)\tx%(upstream:track)\tx%(contents:subject)' |
      while IFS=$'\t' read -r epoch branch head worktree rest; do
        [[ $scope == worktree && $head != 'x*' && -z ${worktree#x} ]] && continue
        printf '0\t%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$branch" "$branch" "$head" "$worktree" "$rest" || break
      done
    fi
    # remote-tracking branches that don't have a local counterpart
    if [[ $scope == all || $scope == remote ]]; then
      git branch -r --format=$'%(committerdate:unix)\tx%(refname:lstrip=2)\tx>\tx\tx%(committerdate:relative)\tx%(objectname:short)\tx\tx%(contents:subject)' |
      while IFS=$'\t' read -r epoch remote_ref head worktree rest; do
        remote_ref=${remote_ref#x}
        [[ $remote_ref == */HEAD ]] && continue
        grep -qxF "${remote_ref#*/}" <<< "$local_branches" && continue
        printf '1\t%s\tx%s\tx%s\t%s\t%s\t%s\n' "$epoch" "${remote_ref#*/}" "$remote_ref" "$head" "$worktree" "$rest" || break
      done
    fi
  } |
  sort -t $'\t' "${sort_args[@]}" |
  cut -f4- |
  while IFS=$'\t' read -r branch head worktree date hash upstream subject; do
    # strip the x prefix from all fields
    branch=${branch#x} head=${head#x} worktree=${worktree#x} date=${date#x} hash=${hash#x} upstream=${upstream#x} subject=${subject#x}
    # determine indicator and color: HEAD (*) takes precedence, then worktree (+)
    local pre= suf= nm=$branch
    if [[ $head == '*' ]]; then ind='*'; c=$c_green
    elif [[ -n $worktree ]]; then ind='+'; c=$c_cyan
    elif [[ $head == '>' ]]; then
      # remote-only: mute the remote part, as a prefix (remote/name) or,
      # when sorting by name alone, as a suffix: name (remote)
      ind=' '; c=$c_reset
      if [[ $order == name ]]; then nm=${branch#*/} suf=" (${branch%%/*})"; else pre=${branch%%/*}/ nm=${branch#*/}; fi
    else ind=' '; c=$c_reset
    fi
    # worktrees also show where they are, searchable too, when that is
    # unexpected: under the root but drifted from the branch name (wtcode puts
    # branch X at <root>/X), or somewhere else entirely. the main checkout and
    # in-place worktrees show nothing. local/remote scopes are about branches
    if [[ -n $worktree && $worktree != "$main_wt" && ( $scope == all || $scope == worktree ) ]]; then
      local rel=$worktree
      if [[ -n $wt_root && $worktree == "$wt_root"/* ]]; then
        rel=${worktree#"$wt_root"/}
      elif [[ $worktree == "$HOME"/* ]]; then
        rel="~/${worktree#"$HOME"/}"
      fi
      (( ${#rel} > 28 )) && rel="..${rel: -26}"
      [[ $rel == "$branch" ]] || suf=" @ $rel"
    fi
    # truncate the name to fit, then pad (before adding colors)
    local room=$(( 50 - ${#pre} - ${#suf} )) padw
    (( room < 4 )) && room=4
    (( ${#nm} > room )) && nm="${nm:0:room-2}.."
    padw=$(( 50 - ${#pre} - ${#nm} - ${#suf} )); (( padw < 0 )) && padw=0
    printf -v pad '%*s' "$padw" ''
    printf -v date '%14s' "$date"
    # build display fields with colors embedded
    name_shown="${c_muted}${pre}${c_reset}${c}${nm}${c_reset}${c_muted}${suf}${c_reset}${pad}"
    date_shown="${c_blue}${date}${c_reset}"
    hash_shown="${c_yellow}${hash}${c_reset}"
    if [[ -n $upstream ]]; then upstream_shown="${c_red}${upstream}${c_reset} "; else upstream_shown=''; fi
    printf '%s\t%s %s\t%s  %s %s%s\n' \
      "$branch" "$ind" "$name_shown" "$date_shown" "$hash_shown" "$upstream_shown" "$subject" || break
  done
}

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
    # if branch name unspecified, use fzf to select one or enter a new name.
    # key bindings cycle scope/order/base/tool, see --fzf-* below
    local fzf_dir
    fzf_dir=$(--fzf-init)
    # fzf prints the typed query, then the selection (if any)
    local picked
    picked=$(--fzf-pick "$fzf_dir")
    if [[ -e $fzf_dir/force_new ]]; then
      # alt-enter: the typed text is a new name, never an existing ref
      branch_name=$(head -1 <<< "$picked")
      [[ -n $branch_name ]] && branch_name=:$branch_name
    else
      branch_name=$(cut -f1 <<< "$picked" | tail -1)
    fi
    [[ -z ${branch_name-} ]] || --fzf-commit "$fzf_dir"
    rm -rf "$fzf_dir"
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
    # fork a base ref and create the new worktree: defaults to origin/HEAD
    # (falling back to origin/main, origin/master, then the current HEAD);
    # set WTCODE_USE_CURRENT_BRANCH=true to always fork from the current
    # branch instead
    local base_ref
    base_ref=$(--default-base-ref)
    --msg "creating worktree with new branch: $branch_name (from $base_ref)"
    git worktree add -b "$branch_name" "$worktree_path" "$base_ref"
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
  if [[ $# -eq 0 && -n ${WTCODE_PICKED_TOOL-} ]]; then
    # chosen in the interactive picker; may carry args, e.g. `claude --resume`
    local _w _words=()
    while IFS= read -r -d '' _w; do _words+=("$_w"); done < <(
      printf '%s' "$WTCODE_PICKED_TOOL" | xargs printf '%s\0' 2>/dev/null ||
      printf '%s\0' $WTCODE_PICKED_TOOL)
    set -- "${_words[@]}"
  elif [[ $# -eq 0 ]]; then
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
    local mode=$WTCODE_TMUX_MODE

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
    local mode=$WTCODE_TERMINAL_MODE
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
  [[ $# -gt 0 ]] && WTCODE_TOOL_FIXED=$1   # CMD given: the picker can't change it
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

# global options (before BRANCH/CMD): --base REF
while [[ ${1-} == --base || ${1-} == --base=* ]]; do
  if [[ $1 == --base=* ]]; then WTCODE_BASE_REF=${1#--base=}; shift
  else WTCODE_BASE_REF=${2:?--base needs a ref}; shift 2
  fi
done

# dispatch $1 as a function when it starts with -
[[ ${1-} == -* ]] || set -- -- "$@"
"$@"
