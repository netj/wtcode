#!/usr/bin/env bash
# tests for wtcode.sh
# usage: ./tests/test.sh                # run all
#        ./tests/test.sh test_name ...  # run specific tests
set -uo pipefail

WTCODE=$(cd "$(dirname "$0")/.." && pwd)/wtcode.sh
export WTCODE   # (the fake fzf stub calls back into it)
unset WTCODE_DEBUG WTCODE_CMD GIT_WORKTREE_ROOT 2>/dev/null || true
# tests must never send-keys into whatever pane/tab/window happens to be
# "current" -- force the exec-directly path regardless of the environment
# tests run in. Unsetting TMUX alone is NOT enough: --terminal-send-keys
# (the outside-tmux path, for Terminal.app/Ghostty/etc.) keys off
# TERM_PROGRAM/TERMINAL_EMULATOR instead, which survive even with TMUX
# unset since they describe the real GUI terminal hosting this shell (e.g.
# the Ghostty window running your actual tmux session). Forgetting this once
# sent real AppleScript/System-Events keystrokes into a live vim pane in an
# unrelated tmux session.
unset TMUX TMUX_PANE TERM_PROGRAM TERMINAL_EMULATOR 2>/dev/null || true
export WTCODE_TERMINAL_MODE=exec WTCODE_TMUX_MODE=exec
# the picker remembers its last state on disk; tests must not touch the real
# one (individual tests opt in by pointing this at a temp file)
export WTCODE_STATE_FILE=
unset WTCODE_BASE_REF WTCODE_BRANCH_SCOPE WTCODE_BRANCH_ORDER 2>/dev/null || true

pass=0; fail=0; failures=()

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
dim()   { printf '\033[2m%s\033[0m' "$*"; }

assert_eq() {
  local expected=$1 actual=$2 msg=${3:-}
  if [[ $expected == "$actual" ]]; then return 0; fi
  echo "  $(red FAIL): $msg" >&2
  echo "    expected: $expected" >&2
  echo "    actual:   $actual" >&2
  return 1
}

assert_contains() {
  local haystack=$1 needle=$2 msg=${3:-}
  if [[ $haystack == *"$needle"* ]]; then return 0; fi
  echo "  $(red FAIL): $msg" >&2
  echo "    expected substring: $needle" >&2
  echo "    actual:             $haystack" >&2
  return 1
}

--fake-claude-bin() {
  local bin; bin=$(mktemp -d)
  printf '#!/usr/bin/env bash\npwd\n' >"$bin/claude"
  chmod +x "$bin/claude"
  echo "$bin"
}

run_test() {
  local name=$1 dir orig_home=$HOME
  dir=$(mktemp -d)
  dir=$(cd "$dir" && pwd -P)   # canonicalize (macOS /tmp -> /private/tmp)
  cd "$dir"
  git init -q
  git checkout -q -b main 2>/dev/null || true
  git config user.email test@example.com
  git config user.name Test
  git config core.excludesfile /dev/null   # isolate from the dev machine's global gitignore
  git commit -q --allow-empty -m initial
  export GIT_WORKTREE_ROOT="$dir/wt"
  mkdir -p "$GIT_WORKTREE_ROOT"
  # --provision-claude-settings writes to ~/.claude.json -- redirect HOME so
  # tests never read or mutate the real developer's global Claude Code config
  export HOME="$dir"

  printf '%s ' "$name"
  if ( "$name" "$dir" ); then
    echo "$(green PASS)"
    pass=$((pass+1))
  else
    echo "$(red FAIL)"
    fail=$((fail+1))
    failures+=("$name")
  fi

  # cleanup
  if [[ -d $dir/.git ]]; then
    git -C "$dir" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' |
      while read -r wt; do
        [[ $wt == "$dir" ]] || git -C "$dir" worktree remove --force "$wt" 2>/dev/null || true
      done
  fi
  cd /
  rm -rf "$dir"
  unset GIT_WORKTREE_ROOT
  export HOME=$orig_home
}

###############################################################################
# tests for branch -> worktree pre-check (commit 1f40287)
###############################################################################

test_branch_on_different_named_worktree() {
  local dir=$1
  git worktree add -q "$GIT_WORKTREE_ROOT/bar" -b foo
  local out
  out=$("$WTCODE" foo pwd 2>/dev/null | tail -1)
  assert_eq "$GIT_WORKTREE_ROOT/bar" "$out" "wtcode foo should cd to bar/ where foo is checked out"
}

test_chaotic_case_branch_wins_over_dir() {
  local dir=$1
  # branch foo on bar/, AND dir foo/ exists holding another branch
  git worktree add -q "$GIT_WORKTREE_ROOT/bar" -b foo
  git worktree add -q "$GIT_WORKTREE_ROOT/foo" -b unrelated
  local out
  out=$("$WTCODE" foo pwd 2>/dev/null | tail -1)
  assert_eq "$GIT_WORKTREE_ROOT/bar" "$out" "branch lookup must win over directory lookup"
}

test_matching_branch_and_dir_still_works() {
  local dir=$1
  git worktree add -q "$GIT_WORKTREE_ROOT/foo" -b foo
  local out
  out=$("$WTCODE" foo pwd 2>/dev/null | tail -1)
  assert_eq "$GIT_WORKTREE_ROOT/foo" "$out" "matching branch+dir should still resolve"
}

###############################################################################
# tests for trailing-colon parsing (commit a80608f)
###############################################################################

test_trailing_colon_forces_new_branch() {
  local dir=$1
  local out
  out=$("$WTCODE" newbranch: pwd 2>/dev/null | tail -1)
  assert_eq "$GIT_WORKTREE_ROOT/newbranch" "$out" "trailing : should create new worktree" || return 1
  assert_eq "newbranch" "$(git -C "$GIT_WORKTREE_ROOT/newbranch" branch --show-current)" \
    "trailing : should produce a branch named without the colon"
}

test_leading_colon_still_works() {
  local dir=$1
  local out
  out=$("$WTCODE" :newbranch pwd 2>/dev/null | tail -1)
  assert_eq "$GIT_WORKTREE_ROOT/newbranch" "$out" "leading : regression"
}

test_multi_colons_both_sides() {
  local dir=$1
  local out
  out=$("$WTCODE" :::newbranch::: pwd 2>/dev/null | tail -1)
  assert_eq "$GIT_WORKTREE_ROOT/newbranch" "$out" ":::name::: should strip all colons"
}

test_only_colons_errors() {
  local dir=$1
  local out rc=0
  out=$("$WTCODE" ::: pwd 2>&1) || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "  $(red FAIL): expected non-zero exit on bare colons" >&2
    return 1
  fi
  assert_contains "$out" "non-empty branch name" "should mention branch name requirement"
}

###############################################################################
# tests for numbered-suffix fallback (commit ba049cc)
###############################################################################

test_dir_holding_other_branch_uses_suffix() {
  local dir=$1
  # foo/ exists holding branch 'occupant', no branch named foo anywhere
  git worktree add -q "$GIT_WORKTREE_ROOT/foo" -b occupant
  local out
  out=$("$WTCODE" foo pwd 2>/dev/null | tail -1)
  assert_eq "$GIT_WORKTREE_ROOT/foo-2" "$out" "should pick foo-2 instead of stealing foo/" || return 1
  assert_eq "foo" "$(git -C "$GIT_WORKTREE_ROOT/foo-2" branch --show-current)" \
    "foo-2/ should hold the foo branch" || return 1
  assert_eq "occupant" "$(git -C "$GIT_WORKTREE_ROOT/foo" branch --show-current)" \
    "foo/ should still hold the occupant branch (untouched)"
}

test_suffix_skips_occupied_n() {
  local dir=$1
  git worktree add -q "$GIT_WORKTREE_ROOT/foo" -b occupant
  git worktree add -q "$GIT_WORKTREE_ROOT/foo-2" -b occupant2
  local out
  out=$("$WTCODE" foo pwd 2>/dev/null | tail -1)
  assert_eq "$GIT_WORKTREE_ROOT/foo-3" "$out" "should skip occupied foo-2 and pick foo-3"
}

test_after_suffix_resolves_via_precheck() {
  local dir=$1
  git worktree add -q "$GIT_WORKTREE_ROOT/foo" -b occupant
  "$WTCODE" foo pwd >/dev/null 2>&1   # creates foo-2/ with branch foo
  local out
  out=$("$WTCODE" foo pwd 2>/dev/null | tail -1)
  assert_eq "$GIT_WORKTREE_ROOT/foo-2" "$out" "second invocation should resolve via branch pre-check"
}

###############################################################################
# regression: basic creation paths
###############################################################################

test_new_branch_default() {
  local dir=$1
  local out
  out=$("$WTCODE" :brandnew pwd 2>/dev/null | tail -1)
  assert_eq "$GIT_WORKTREE_ROOT/brandnew" "$out" "new branch should land in matching dir" || return 1
  assert_eq "brandnew" "$(git -C "$GIT_WORKTREE_ROOT/brandnew" branch --show-current)" \
    "new branch should be checked out"
}

test_existing_branch_not_checked_out_anywhere() {
  local dir=$1
  git branch dormant
  local out
  out=$("$WTCODE" dormant pwd 2>/dev/null | tail -1)
  assert_eq "$GIT_WORKTREE_ROOT/dormant" "$out" "existing dormant branch should get its own worktree" || return 1
  assert_eq "dormant" "$(git -C "$GIT_WORKTREE_ROOT/dormant" branch --show-current)"
}

test_slash_in_new_branch_name() {
  local dir=$1
  local out
  out=$("$WTCODE" :fix/foo pwd 2>/dev/null | tail -1)
  assert_eq "$GIT_WORKTREE_ROOT/fix/foo" "$out" "slash should nest the worktree dir" || return 1
  assert_eq "fix/foo" "$(git -C "$GIT_WORKTREE_ROOT/fix/foo" branch --show-current)" \
    "slash should be preserved in branch name" || return 1
  out=$("$WTCODE" ":Security/Bar Something//blah" pwd 2>/dev/null | tail -1)
  assert_eq "$GIT_WORKTREE_ROOT/security/bar-something/blah" "$out" \
    "free-form text around slashes should be sanitized"
}

###############################################################################
# tests for interactive picker support (scope/order/base/state)
###############################################################################

--picker-repo() {
  git branch zeta
  git worktree add -q "$GIT_WORKTREE_ROOT/wt1" -b wt1
  git init -q --bare "$1/remote.git"
  git remote add origin "$1/remote.git"
  git branch alpha && git push -q origin main alpha && git branch -q -D alpha
  git fetch -q origin
}

--header() { "$WTCODE" --fzf-header "$1" | sed $'s/\x1b\\[[0-9;]*m//g'; }   # without bold escapes
--names() { "$WTCODE" --list-branches "$@" | cut -f1 | tr '\n' ' '; }

test_list_scopes() {
  local dir=$1
  --picker-repo "$dir"
  assert_eq "main wt1 zeta origin/alpha " "$(--names all)" "all" || return 1
  assert_eq "main wt1 " "$(--names worktree)" "worktree" || return 1
  assert_eq "main wt1 zeta " "$(--names local)" "local" || return 1
  assert_eq "origin/alpha " "$(--names remote)" "remote"
}

test_list_orders() {
  local dir=$1
  --picker-repo "$dir"
  assert_eq "origin/alpha main wt1 zeta " "$(--names all name)" "by name alone: alpha < main" || return 1
  assert_eq "main origin/alpha wt1 zeta " "$(--names all full)" "by remote/name" || return 1
  # remote part is muted as a prefix by default, and as a suffix when sorting by name
  local shown
  shown=$("$WTCODE" --list-branches remote recent | cut -f2 | sed $'s/\x1b\\[[0-9;]*m//g')
  assert_contains "$shown" "origin/alpha" "remote/ prefix" || return 1
  shown=$("$WTCODE" --list-branches remote name | cut -f2 | sed $'s/\x1b\\[[0-9;]*m//g')
  assert_contains "$shown" "alpha (origin)" "name (remote) suffix"
}

test_base_labels_and_header() {
  local dir=$1 d
  --picker-repo "$dir"; git remote set-head origin main >/dev/null
  assert_eq "origin/main (default)" "$("$WTCODE" --base-label default)" "default is origin/HEAD, named exactly" || return 1
  assert_eq "main (current)" "$("$WTCODE" --base-label current)" "current branch" || return 1
  assert_eq "default current" "$("$WTCODE" --base-modes | tr '\n' ' ' | sed 's/ $//')" "origin/HEAD isn't offered twice" || return 1
  assert_eq "side/x (default)" "$(WTCODE_BASE_REF=side/x "$WTCODE" --base-label default)" "explicit base" || return 1
  d=$("$WTCODE" --fzf-init)
  # ^r is always shown, and alt-enter is hinted
  assert_contains "$(--header "$d")" "^r branch from: origin/main (default)" "^r always visible" || return 1
  assert_contains "$(--header "$d")" "alt-enter: create new worktree" "alt-enter hint" || return 1
  : > "$d/updating"   # ^l pressed: only that spot changes, the rest of the header stays
  assert_contains "$(--header "$d")" "^l updating remotes..." "inline update indicator" || return 1
  assert_contains "$(--header "$d")" "^s scope: all branches" "rest of the header stays while updating" || return 1
  rm "$d/updating"
  "$WTCODE" --fzf-cycle "$d" base
  assert_contains "$(--header "$d")" "^r branch from: main (current)" "label follows ^r"
}

test_fzf_cycle_and_state() {
  local dir=$1 d
  export WTCODE_STATE_FILE=$dir/state
  --picker-repo "$dir"; git remote set-head origin main >/dev/null   # so a "current" base is distinct
  d=$("$WTCODE" --fzf-init)
  assert_eq "all recent default" "$(cat "$d/scope" "$d/order" "$d/base" | tr '\n' ' ' | sed 's/ $//')" "defaults" || return 1
  "$WTCODE" --fzf-cycle "$d" scope; "$WTCODE" --fzf-cycle "$d" scope
  assert_eq "local" "$(<"$d/scope")" "scope cycles all->worktree->local" || return 1
  "$WTCODE" --fzf-cycle "$d" base
  assert_eq "current" "$(<"$d/base")" "base cycles default->current" || return 1
  "$WTCODE" --fzf-cycle "$d" order; "$WTCODE" --fzf-cycle "$d" order; "$WTCODE" --fzf-cycle "$d" order
  assert_eq "recent" "$(<"$d/order")" "order wraps around" || return 1
  "$WTCODE" --fzf-cycle "$d" scope
  # commit remembers; a fresh session starts from it, env vars win over it
  "$WTCODE" --state-save scope=local base=current
  d=$("$WTCODE" --fzf-init)
  assert_eq "local current" "$(<"$d/scope") $(<"$d/base")" "remembered" || return 1
  d=$(WTCODE_BRANCH_SCOPE=remote WTCODE_BASE_REF=origin/main "$WTCODE" --fzf-init)
  assert_eq "remote default" "$(<"$d/scope") $(<"$d/base")" "env overrides remembered"
}

test_history_and_tool_picker_state() {
  local dir=$1 d
  export WTCODE_STATE_FILE=$dir/state
  source <(sed -n '/^--history-file()/,/^}/p;/^--history-add()/,/^}/p' "$WTCODE")
  --history-add "claude --resume"; --history-add "aider"; --history-add "claude --resume"
  assert_eq "claude --resume aider" "$(tr '\n' ' ' < "$dir/state.cmds" | sed 's/ $//')" "MRU, deduped" || return 1
  d=$(WTCODE_CMD="vim -R" "$WTCODE" --fzf-init)
  assert_eq "vim -R" "$(<"$d/tool")" "WTCODE_CMD seeds the tool, args included"
}

test_tmux_version_gate() {
  local dir=$1 v
  mkdir "$dir/bin"
  for v in "3.8:0" "3.3a:0" "next-3.4:0" "3.2a:1" "2.9:1" "4.0:0"; do
    printf '#!/bin/sh\necho "tmux %s"\n' "${v%:*}" > "$dir/bin/tmux"; chmod +x "$dir/bin/tmux"
    local got=0
    ( PATH="$dir/bin:$PATH"; source <(sed -n '/^--tmux-at-least()/,/^}/p' "$WTCODE"); --tmux-at-least 3 3 ) || got=1
    assert_eq "${v#*:}" "$got" "tmux ${v%:*} supports popup env (-e)" || return 1
  done
}

# a stand-in for fzf: drains the list, optionally acts like alt-enter was pressed,
# then prints what fzf --print-query would: the query, then the selection
--fake-fzf() {
  local bin=$1/bin; mkdir -p "$bin"
  cat > "$bin/fzf" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
dir=$(printf '%s\n' "$@" | grep -o -m1 'fzf-cycle [^ ]*' | head -1 | cut -d' ' -f2)
[[ -z ${STUB_ALT_ENTER-} ]] || : > "$dir/force_new"
printf '%s\n' "$STUB_QUERY"
[[ -z ${STUB_PICK-} ]] || printf '%s\tx\ty\n' "$STUB_PICK"
STUB
  chmod +x "$bin/fzf"
}

test_alt_enter_creates_typed_name() {
  local dir=$1 out
  git branch zeta
  --fake-fzf "$dir"
  out=$(PATH="$dir/bin:$PATH" STUB_ALT_ENTER=1 STUB_QUERY=fresh STUB_PICK=zeta "$WTCODE" --exec pwd 2>/dev/null | tail -1)
  assert_eq "$GIT_WORKTREE_ROOT/fresh" "$out" "alt-enter creates the typed name even with a highlighted match" || return 1
  assert_eq "fresh" "$(git -C "$GIT_WORKTREE_ROOT/fresh" branch --show-current)" || return 1
  # a typed name matching an existing branch is still created fresh with alt-enter
  out=$(PATH="$dir/bin:$PATH" STUB_ALT_ENTER=1 STUB_QUERY=zeta-2 STUB_PICK=zeta "$WTCODE" --exec pwd 2>/dev/null | tail -1)
  assert_eq "$GIT_WORKTREE_ROOT/zeta-2" "$out" "alt-enter: new name" || return 1
  out=$(PATH="$dir/bin:$PATH" STUB_QUERY=zet STUB_PICK=zeta "$WTCODE" --exec pwd 2>/dev/null | tail -1)
  assert_eq "$GIT_WORKTREE_ROOT/zeta" "$out" "without alt-enter the selection wins over the query"
}

test_state_untouched_by_noninteractive_runs() {
  local dir=$1
  export WTCODE_STATE_FILE=$dir/state
  "$WTCODE" :foo pwd >/dev/null 2>&1
  [[ ! -e $dir/state ]] || { echo "  state file written by a non-interactive run" >&2; return 1; }
}

test_base_ref_env_and_flag() {
  local dir=$1
  git checkout -q -b side && git commit -q --allow-empty -m side-only && git checkout -q main
  WTCODE_BASE_REF=side "$WTCODE" :fromenv true >/dev/null 2>&1
  assert_eq "side-only" "$(git log -1 --format=%s fromenv)" "WTCODE_BASE_REF" || return 1
  "$WTCODE" --base side :fromflag true >/dev/null 2>&1
  assert_eq "side-only" "$(git log -1 --format=%s fromflag)" "--base REF" || return 1
  "$WTCODE" --base=side :fromflag2 true >/dev/null 2>&1
  assert_eq "side-only" "$(git log -1 --format=%s fromflag2)" "--base=REF" || return 1
  "$WTCODE" :fromdefault true >/dev/null 2>&1
  assert_eq "initial" "$(git log -1 --format=%s fromdefault)" "unchanged default"
}

###############################################################################
# tests for .claude/settings.json symlinking (provisioning only for claude)
###############################################################################

test_provisions_claude_settings_symlinks() {
  local dir=$1
  mkdir -p "$dir/.claude"
  echo '{"main":"settings"}' >"$dir/.claude/settings.json"
  echo '{"main":"local"}' >"$dir/.claude/settings.local.json"

  local bin; bin=$(--fake-claude-bin)
  PATH="$bin:$PATH" "$WTCODE" newbranch claude >/dev/null 2>&1
  rm -rf "$bin"

  local wt="$GIT_WORKTREE_ROOT/newbranch"
  assert_eq "$dir/.claude/settings.json" "$(readlink "$wt/.claude/settings.json")" \
    "settings.json should be symlinked to the main worktree's copy" || return 1
  assert_eq "$dir/.claude/settings.local.json" "$(readlink "$wt/.claude/settings.local.json")" \
    "settings.local.json should be symlinked to the main worktree's copy"
}

test_provisions_claude_settings_skips_existing_file() {
  local dir=$1
  mkdir -p "$dir/.claude"
  echo '{"main":"settings"}' >"$dir/.claude/settings.json"
  echo '{"main":"local"}' >"$dir/.claude/settings.local.json"

  # simulate the worktree already having settings.local.json provisioned some
  # other way (e.g. git-tracked, or a post-checkout hook) BEFORE wtcode runs
  git worktree add -q "$GIT_WORKTREE_ROOT/pre" -b pre
  mkdir -p "$GIT_WORKTREE_ROOT/pre/.claude"
  echo '{"worktree":"local"}' >"$GIT_WORKTREE_ROOT/pre/.claude/settings.local.json"

  local bin; bin=$(--fake-claude-bin)
  PATH="$bin:$PATH" "$WTCODE" pre claude >/dev/null 2>&1
  rm -rf "$bin"

  local wt="$GIT_WORKTREE_ROOT/pre"
  if [[ -L "$wt/.claude/settings.local.json" ]]; then
    echo "  $(red FAIL): pre-existing settings.local.json must not be replaced with a symlink" >&2
    return 1
  fi
  assert_eq '{"worktree":"local"}' "$(cat "$wt/.claude/settings.local.json")" \
    "pre-existing settings.local.json content must be untouched" || return 1
  assert_eq "$dir/.claude/settings.json" "$(readlink "$wt/.claude/settings.json")" \
    "settings.json (not pre-existing) should still get symlinked"
}

test_provisions_claude_gitignore_when_needed() {
  local dir=$1
  mkdir -p "$dir/.claude"
  echo '{}' >"$dir/.claude/settings.json"

  local bin; bin=$(--fake-claude-bin)
  PATH="$bin:$PATH" "$WTCODE" newbranch claude >/dev/null 2>&1
  rm -rf "$bin"

  local wt="$GIT_WORKTREE_ROOT/newbranch"
  local gi="$wt/.claude/.gitignore"
  [[ -f $gi ]] || { echo "  $(red FAIL): .claude/.gitignore should have been created" >&2; return 1; }
  assert_contains "$(cat "$gi")" "settings.json" "generated .gitignore should cover settings.json" || return 1
  assert_contains "$(cat "$gi")" "settings.local.json" "generated .gitignore should cover settings.local.json"
}

test_provisions_claude_gitignore_skipped_when_already_ignored() {
  local dir=$1
  mkdir -p "$dir/.claude"
  echo '{}' >"$dir/.claude/settings.json"
  echo '.claude/' >"$dir/.gitignore"
  git add .gitignore
  git commit -q -m 'ignore .claude/'

  local bin; bin=$(--fake-claude-bin)
  PATH="$bin:$PATH" "$WTCODE" newbranch claude >/dev/null 2>&1
  rm -rf "$bin"

  local wt="$GIT_WORKTREE_ROOT/newbranch"
  assert_eq "$dir/.claude/settings.json" "$(readlink "$wt/.claude/settings.json")" \
    "settings.json should still be symlinked" || return 1
  if [[ -e "$wt/.claude/.gitignore" ]]; then
    echo "  $(red FAIL): .claude/.gitignore should not be created when already covered by an ignore rule" >&2
    return 1
  fi
  return 0
}

test_provisions_claude_settings_safe_with_existing_claude_dir() {
  local dir=$1
  mkdir -p "$dir/.claude"
  echo '{}' >"$dir/.claude/settings.json"

  git worktree add -q "$GIT_WORKTREE_ROOT/pre" -b pre
  mkdir -p "$GIT_WORKTREE_ROOT/pre/.claude/commands"
  echo '# my command' >"$GIT_WORKTREE_ROOT/pre/.claude/commands/foo.md"

  local bin; bin=$(--fake-claude-bin)
  PATH="$bin:$PATH" "$WTCODE" pre claude >/dev/null 2>&1
  rm -rf "$bin"

  local wt="$GIT_WORKTREE_ROOT/pre"
  assert_eq '# my command' "$(cat "$wt/.claude/commands/foo.md")" \
    "unrelated .claude/ content must be left untouched" || return 1
  assert_eq "$dir/.claude/settings.json" "$(readlink "$wt/.claude/settings.json")" \
    "settings.json should still be symlinked in alongside existing content"
}

test_provisions_claude_settings_idempotent_rerun() {
  local dir=$1
  mkdir -p "$dir/.claude"
  echo '{}' >"$dir/.claude/settings.json"

  local bin; bin=$(--fake-claude-bin)
  PATH="$bin:$PATH" "$WTCODE" newbranch claude >/dev/null 2>&1
  local rc=0
  PATH="$bin:$PATH" "$WTCODE" newbranch claude >/dev/null 2>&1 || rc=$?
  rm -rf "$bin"

  if [[ $rc -ne 0 ]]; then
    echo "  $(red FAIL): second run should not error" >&2
    return 1
  fi
  local wt="$GIT_WORKTREE_ROOT/newbranch"
  assert_eq "$dir/.claude/settings.json" "$(readlink "$wt/.claude/settings.json")" \
    "settings.json symlink should be unchanged after rerun" || return 1
  assert_eq "1" "$(grep -c settings.json "$wt/.claude/.gitignore")" \
    ".gitignore should not accumulate duplicate entries across reruns"
}

test_provisions_trust_flags_in_claude_json() {
  local dir=$1
  echo '{"projects":{}}' >"$HOME/.claude.json"

  local bin; bin=$(--fake-claude-bin)
  PATH="$bin:$PATH" "$WTCODE" newbranch claude >/dev/null 2>&1
  rm -rf "$bin"

  local wt="$GIT_WORKTREE_ROOT/newbranch"
  local entry
  entry=$(jq -c --arg p "$wt" '.projects[$p]' "$HOME/.claude.json")
  assert_contains "$entry" '"hasTrustDialogAccepted":true' "trust dialog flag should be set" || return 1
  assert_contains "$entry" '"hasCompletedProjectOnboarding":true' "project onboarding flag should be set"
}

test_trust_flags_not_overwritten_if_entry_exists() {
  local dir=$1
  local wt="$GIT_WORKTREE_ROOT/newbranch"
  # can't know wt's realpath before wtcode creates it, so pre-seed by branch
  # name it will resolve to, matching how wtcode computes worktree_path
  jq -n --arg p "$wt" '{projects: {($p): {hasTrustDialogAccepted: false}}}' >"$HOME/.claude.json"

  local bin; bin=$(--fake-claude-bin)
  PATH="$bin:$PATH" "$WTCODE" newbranch claude >/dev/null 2>&1
  rm -rf "$bin"

  local entry
  entry=$(jq -c --arg p "$wt" '.projects[$p]' "$HOME/.claude.json")
  assert_eq '{"hasTrustDialogAccepted":false}' "$entry" \
    "an existing project entry must not be touched, even if incomplete"
}

test_no_provisioning_for_non_claude_tools() {
  local dir=$1
  mkdir -p "$dir/.claude"
  echo '{}' >"$dir/.claude/settings.json"
  echo '{}' >"$dir/.claude/settings.local.json"

  "$WTCODE" newbranch pwd >/dev/null 2>&1

  local wt="$GIT_WORKTREE_ROOT/newbranch"
  if [[ -e "$wt/.claude/settings.json" || -e "$wt/.claude/settings.local.json" || -e "$wt/.claude/.gitignore" ]]; then
    echo "  $(red FAIL): .claude/ should not be provisioned when launching a non-claude tool" >&2
    return 1
  fi
  return 0
}

###############################################################################
# main
###############################################################################

ALL_TESTS=(
  test_branch_on_different_named_worktree
  test_chaotic_case_branch_wins_over_dir
  test_matching_branch_and_dir_still_works
  test_trailing_colon_forces_new_branch
  test_leading_colon_still_works
  test_multi_colons_both_sides
  test_only_colons_errors
  test_dir_holding_other_branch_uses_suffix
  test_suffix_skips_occupied_n
  test_after_suffix_resolves_via_precheck
  test_new_branch_default
  test_existing_branch_not_checked_out_anywhere
  test_slash_in_new_branch_name
  test_list_scopes
  test_list_orders
  test_base_labels_and_header
  test_fzf_cycle_and_state
  test_history_and_tool_picker_state
  test_tmux_version_gate
  test_alt_enter_creates_typed_name
  test_state_untouched_by_noninteractive_runs
  test_base_ref_env_and_flag
  test_provisions_claude_settings_symlinks
  test_provisions_claude_settings_skips_existing_file
  test_provisions_claude_gitignore_when_needed
  test_provisions_claude_gitignore_skipped_when_already_ignored
  test_provisions_claude_settings_safe_with_existing_claude_dir
  test_provisions_claude_settings_idempotent_rerun
  test_no_provisioning_for_non_claude_tools
  test_provisions_trust_flags_in_claude_json
  test_trust_flags_not_overwritten_if_entry_exists
)

if [[ $# -gt 0 ]]; then
  tests_to_run=("$@")
else
  tests_to_run=("${ALL_TESTS[@]}")
fi

for t in "${tests_to_run[@]}"; do
  run_test "$t"
done

echo
if (( fail == 0 )); then
  echo "$(green "all $pass tests passed")"
else
  echo "$(red "$fail failed"), $pass passed"
  printf '  %s\n' "${failures[@]}"
  exit 1
fi
