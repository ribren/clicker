"""Single frozen entry point for the pyatv CLIs Clicker uses.

PyInstaller bundles one executable + shared libs; the first argument picks
which pyatv tool to run:  atvbridge atvremote ...  /  atvbridge atvscript ...
"""
import sys


def run() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in ("atvremote", "atvscript"):
        sys.stderr.write("usage: atvbridge {atvremote|atvscript} [args...]\n")
        return 2
    tool = sys.argv.pop(1)
    sys.argv[0] = tool
    if tool == "atvremote":
        from pyatv.scripts.atvremote import main
    else:
        from pyatv.scripts.atvscript import main
    return main()


if __name__ == "__main__":
    sys.exit(run())
