#!/usr/bin/env bash
# wtcode -- launch a code tool in a git worktree for a given branch
# https://github.com/netj/wtcode
# Author: Jaeho Shin <netj@sparcs.org>
# Created: 2026-02-03
set -eu
shopt -s extglob
${WTCODE_DEBUG:+set -x}

--msg() { echo "wtcode: $*" >&2; }

WTCODE_VERSION=0.1.1
--version() { echo "wtcode $WTCODE_VERSION"; }
--help() {
  cat <<USAGE
wtcode $WTCODE_VERSION -- launch a code tool in a git worktree

Usage: wtcode [BRANCH] [CMD [CMD-ARGS...]]

  BRANCH     Git branch or worktree name to switch to.
             If omitted and fzf is available, interactively select one.
             Prefix with ':' to force creating a new branch
             (use multiple colons to avoid fzf matching, e.g., :::my-branch).

  CMD        Command to launch in the worktree (default: \$WTCODE_CMD,
             or first available of: ${WTCODE_CMDS_TO_TRY[*]}, \$SHELL).

Environment variables:
  WTCODE_CMD             Default tool to launch (e.g., claude, lazygit, vim)
  WTCODE_DEBUG           Enable debug tracing when set
  GIT_WORKTREE_ROOT      Override the directory where worktrees are created

Examples:
  wtcode feature-x                  # select/create worktree, launch default tool
  wtcode feature-x lazygit          # launch lazygit in the worktree
  wtcode feature-x claude --resume  # launch claude with --resume
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
## --select-git-branch -- determine which branch/worktree to use
###############################################################################
--select-git-branch() {
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

  # check if branch name starts with ':' to force new branch creation
  # supports multiple colons (e.g., :::my-branch) to avoid fzf matching
  force_new_branch=false
  if [[ $branch_name == :* ]]; then
    force_new_branch=true
    branch_name=${branch_name##+(:)}
    : ${branch_name:?non-empty branch name required after ':'}
    # sanitize free-form text into a valid git branch name
    branch_name=$(printf '%s' "$branch_name" |
      tr '[:upper:]' '[:lower:]' |   # lowercase
      sed 's/[^a-z0-9/_-]/-/g' |     # replace non-alnum to hyphens
      sed 's/--*/-/g' |              # collapse consecutive hyphens
      sed 's/^-//; s/-$//'           # trim leading/trailing hyphens
    )
    : ${branch_name:?branch name is empty after sanitization}
  fi

  # check if branch_name refers to a remote branch (e.g., origin/feature-x)
  remote_branch=
  if ! $force_new_branch; then
    for remote in $(git remote); do
      if [[ $branch_name == "$remote/"* ]]; then
        remote_branch=$branch_name
        branch_name=${branch_name#"$remote/"}
        break
      fi
    done
  fi

  # remaining args are the command to launch
  wtcode_cmd=("$@")
}

###############################################################################
## --prepare-git-worktree -- create or switch to the worktree for $branch_name
###############################################################################
--prepare-git-worktree() {
  # determine root of the worktree dirs
  cd "$(git rev-parse --show-toplevel)"
  : ${GIT_WORKTREE_ROOT:=$(
    git_common_dir=$(git rev-parse --git-common-dir)
    cd "$git_common_dir"
    cd ..
    repo_name=$(basename "$PWD")
    echo "$PWD"/../"$repo_name".worktrees
  )}

  # ensure worktree based on given branch name
  worktree_path="$GIT_WORKTREE_ROOT"/"$branch_name"
  if [[ -e "$worktree_path"/.git ]]; then
    --msg "using existing worktree: $worktree_path"
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
## --launch-code-tool -- resolve and exec the tool in the worktree
###############################################################################
--launch-code-tool() {
  # resolve the command to launch if not specified by user
  if [[ ${#wtcode_cmd[@]} -eq 0 ]]; then
    for _cmd in "${WTCODE_CMDS_TO_TRY[@]}"; do
      [[ -n "$_cmd" ]] && type "$_cmd" &>/dev/null && wtcode_cmd=("$_cmd") && break
    done
    # fall back to an interactive shell
    wtcode_cmd=("${wtcode_cmd[@]:-${SHELL:-bash}}")
  fi

  --msg "launching: ${wtcode_cmd[*]}"
  "${wtcode_cmd[@]}"
}

###############################################################################
## Command wrappers -- override specific tools with pre-launch setup.
## Define a function with the tool's name to add custom behavior.
###############################################################################

# claude: auto-trust the worktree in Claude Code's config
claude() {
  if type jq &>/dev/null && [[ -f ~/.claude.json ]]; then
    (
      export worktree_path="$PWD"
      jq -e '.projects[env.worktree_path]' ~/.claude.json &>/dev/null || {
        jq '
          .projects[env.worktree_path] = ({}
          | .hasTrustDialogAccepted = true
          )
        ' ~/.claude.json >~/.claude.json.wtcode.$$
        mv -f ~/.claude.json.wtcode.$$ ~/.claude.json
      }
    )
  fi
  exec claude "$@"
}

###############################################################################
## main
###############################################################################

-h() { --help "$@"; }

--() {
  --select-git-branch "$@"
  --prepare-git-worktree
  --launch-code-tool
}

# dispatch $1 as a function when it starts with -
[[ ${1-} == -* ]] || set -- -- "$@"
"$@"
