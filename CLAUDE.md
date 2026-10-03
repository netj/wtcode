# wtcode

A bash script that streamlines git-worktree selection/creation and launches code tools.
Published to GitHub, PyPI, and Homebrew.

## Project structure

- `wtcode.sh` — the main bash script (canonical source)
- `wtcode/` — thin Python wrapper package for PyPI/uvx (`__main__.py` execs `wtcode.sh`)
- `wtcode/wtcode.sh` — symlink to `../wtcode.sh`
- `pyproject.toml` — PyPI packaging config

## Version

Version is defined in three places — keep them in sync:
- `wtcode.sh`: `WTCODE_VERSION=X.Y.Z`
- `pyproject.toml`: `version = "X.Y.Z"`
- `wtcode/__init__.py`: `__version__ = "X.Y.Z"`

## Testing

Automated tests cover branch→worktree resolution and the colon-prefix/suffix
parsing. Each test spins up a throwaway repo under `mktemp -d`.

```sh
./tests/test.sh                         # run all
./tests/test.sh test_chaotic_case_branch_wins_over_dir   # run one
```

`tests/test.sh` forces `WTCODE_TERMINAL_MODE=exec` and `WTCODE_TMUX_MODE=exec`
(and unsets `TMUX`/`TERM_PROGRAM`/`TERMINAL_EMULATOR`) so it never fires real
tmux send-keys or macOS AppleScript/System-Events keystrokes into whatever
pane/tab/window happens to be current. If you add a new mechanism that
targets "the current terminal" outside of exec, make sure it's disabled by
one of those knobs too, or add a new one and disable it here — otherwise
running the test suite can inject text into an unrelated live session.

Manual smoke tests:

```sh
./wtcode.sh --help
./wtcode.sh --version
./wtcode.sh BRANCH echo hello          # test with a real worktree
./wtcode.sh --exec echo hello           # test --exec (fzf selects branch)
uvx --from . wtcode --version           # test PyPI wrapper
```

If your current shell is itself inside tmux (true for an agent shell running
inside the user's tmux session), any manual `./wtcode.sh ...` invocation
that reaches `--launch-code-tool` picks the tmux branch first — whenever
`$TMUX` is set, `WTCODE_TERMINAL_MODE` is irrelevant. Setting only
`WTCODE_TERMINAL_MODE=exec` and forgetting `WTCODE_TMUX_MODE=exec` still
lets it default to `send-keys` and fire real keystrokes into whatever pane
is current, possibly one the user is actively watching. Always set **both**
when manually testing:

```sh
WTCODE_TERMINAL_MODE=exec WTCODE_TMUX_MODE=exec ./wtcode.sh BRANCH echo hello
```

## Release checklist

1. Bump version in all three places (see above)
2. Commit and push:
   ```sh
   git push origin main
   ```
3. Tag and push:
   ```sh
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```
4. Create GitHub release:
   ```sh
   gh release create vX.Y.Z --title "wtcode vX.Y.Z" --notes "..."
   ```
5. Build and publish to PyPI:
   ```sh
   uv build
   token=$(python3 -c "import configparser; c=configparser.ConfigParser(); c.read('$HOME/.pypirc'); print(c.get('pypi','password'))")
   uv publish dist/wtcode-X.Y.Z* --token "$token"
   ```
6. Update Homebrew formula in `netj/homebrew-tap`:
   - Compute sha256: `curl -sL https://github.com/netj/wtcode/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256`
   - Update `wtcode.rb` via `gh api repos/netj/homebrew-tap/contents/wtcode.rb --method PUT ...` with new url, sha256, version

## Conventions

- Internal bash functions are prefixed with `--` (e.g., `--enter-git-worktree`, `--launch-code-tool`, `--msg`)
- Command wrappers (e.g., `claude()`) add pre-launch setup then `exec` the real command
- `$1` starting with `-` dispatches to a function; otherwise `set -- -- "$@"` routes to `--()` (the main flow)
