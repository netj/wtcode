"""Thin wrapper to exec wtcode.sh from the installed package."""

import os
import sys
from importlib.resources import as_file, files


def main():
    script = files("wtcode").joinpath("wtcode.sh")
    with as_file(script) as path:
        os.execvp("bash", ["bash", str(path)] + sys.argv[1:])


if __name__ == "__main__":
    main()
