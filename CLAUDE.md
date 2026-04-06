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

```sh
./wtcode.sh --help
./wtcode.sh --version
./wtcode.sh BRANCH echo hello          # test with a real worktree
./wtcode.sh --exec echo hello           # test --exec (fzf selects branch)
uvx --from . wtcode --version           # test PyPI wrapper
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
