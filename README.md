# wtcode

**Effortlessly launch your favorite code tool in a git worktree.**

*worktree code* / *what-the-code* -- streamlines git worktree selection, creation, and launching tools like [Claude Code](https://claude.ai/code), [lazygit](https://github.com/jesseduffield/lazygit), your editor, or any command.

## Install

### Homebrew

```sh
brew install netj/tap/wtcode
```

### PyPI (via [uv](https://docs.astral.sh/uv/))

```sh
uv tool install wtcode
```

Or try it without installing:

```sh
uvx wtcode
```

> **Note:** `uv tool install` is recommended over `uvx` for regular use.
> `uvx` keeps a parent `uv tool run` process alive, which can interfere with tools like tmux that detect the working directory from the process tree.

### From source

```sh
git clone https://github.com/netj/wtcode.git
ln -s "$PWD/wtcode/wtcode.sh" /usr/local/bin/wtcode
```

## Usage

```
wtcode [BRANCH] [CMD [CMD-ARGS...]]
wtcode --exec CMD [CMD-ARGS...]
```

- **`BRANCH`** -- Git branch or worktree name. If omitted and [fzf](https://github.com/junegunn/fzf) is available, interactively select one. Surround with `:` to create a new branch (use `:::name` or `name:::` to avoid fzf matching the colons).
- **`CMD`** -- Command to launch in the worktree. Defaults to `$WTCODE_CMD`, or the first available of: `claude`, `aider`, `codex`, `$SHELL`.
- **`--exec`** -- Skip the branch argument; select interactively via fzf, then launch `CMD`.
- **`--help`** / **`--version`** -- Show help or version info.

### Examples

```sh
wtcode feature-x                  # launch default tool in feature-x worktree
wtcode feature-x lazygit          # launch lazygit
wtcode feature-x claude --resume  # launch claude with flags
wtcode --exec claude --resume     # select interactively, launch claude --resume
wtcode :new-feature               # create new branch and worktree
wtcode                            # interactive branch selection via fzf
WTCODE_CMD=cursor wtcode feature  # use cursor as default tool
```

## Environment variables

| Variable | Description |
|---|---|
| `WTCODE_CMD` | Default tool to launch (e.g., `claude`, `lazygit`, `vim`, `cursor`) |
| `WTCODE_DEBUG` | Enable debug tracing when set to any value |
| `GIT_WORKTREE_ROOT` | Override the directory where worktrees are created |

## How it works

1. **Select/specify a branch** -- pass as argument or pick interactively with fzf
2. **Create or switch to the worktree** -- worktrees are organized under `$GIT_WORKTREE_ROOT` (defaults to `../<repo>.worktrees/`)
3. **Launch a tool** -- runs the specified command (or smart default) inside the worktree

## Dependencies

- **git** -- required
- **[fzf](https://github.com/junegunn/fzf)** -- recommended, for interactive branch selection
- **[jq](https://jqlang.github.io/jq/)** -- optional, for Claude Code auto-trust setup

## License

[MIT](LICENSE)
