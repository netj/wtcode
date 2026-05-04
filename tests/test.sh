#!/usr/bin/env bash
# tests for wtcode.sh
# usage: ./tests/test.sh                # run all
#        ./tests/test.sh test_name ...  # run specific tests
set -uo pipefail

WTCODE=$(cd "$(dirname "$0")/.." && pwd)/wtcode.sh
unset WTCODE_DEBUG WTCODE_CMD GIT_WORKTREE_ROOT 2>/dev/null || true

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

run_test() {
  local name=$1 dir
  dir=$(mktemp -d)
  dir=$(cd "$dir" && pwd -P)   # canonicalize (macOS /tmp -> /private/tmp)
  cd "$dir"
  git init -q
  git checkout -q -b main 2>/dev/null || true
  git config user.email test@example.com
  git config user.name Test
  git commit -q --allow-empty -m initial
  export GIT_WORKTREE_ROOT="$dir/wt"
  mkdir -p "$GIT_WORKTREE_ROOT"

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
