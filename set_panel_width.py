"""Set VS Code auxiliary bar (secondary side bar) width in state.vscdb.

Usage:
    python set_panel_width.py <width_in_pixels>
    python set_panel_width.py 1920

Modifies the VS Code SQLite state database directly to set the
auxiliary bar width without requiring mouse interaction.
"""

import os
import sqlite3
import sys


def get_state_db_path():
    appdata = os.environ.get("APPDATA")
    if not appdata:
        raise RuntimeError("APPDATA environment variable not set")
    path = os.path.join(appdata, "Code", "User", "globalStorage", "state.vscdb")
    if not os.path.exists(path):
        raise FileNotFoundError(f"VS Code state database not found: {path}")
    return path


def set_auxiliary_bar_width(width):
    db_path = get_state_db_path()

    conn = sqlite3.connect(db_path)
    try:
        cur = conn.cursor()

        cur.execute(
            "UPDATE ItemTable SET value = ? WHERE key = 'workbench.auxiliaryBar.size'",
            (str(width),),
        )
        size_updated = cur.rowcount

        cur.execute(
            "UPDATE ItemTable SET value = ? WHERE key = 'workbench.auxiliaryBar.lastNonMaximizedSize'",
            (str(width),),
        )
        last_size_updated = cur.rowcount

        conn.commit()

        if size_updated == 0:
            print(f"WARNING: key 'workbench.auxiliaryBar.size' not found in database", file=sys.stderr)
            return False

        print(f"Set auxiliaryBar.size = {width}")
        if last_size_updated > 0:
            print(f"Set auxiliaryBar.lastNonMaximizedSize = {width}")
        return True
    except sqlite3.OperationalError as err:
        print(f"ERROR: Database operation failed: {err}", file=sys.stderr)
        print("Is VS Code currently running? The database may be locked.", file=sys.stderr)
        return False
    finally:
        conn.close()


def main():
    if len(sys.argv) != 2:
        print(f"Usage: python {sys.argv[0]} <width_in_pixels>", file=sys.stderr)
        sys.exit(1)

    try:
        width = int(sys.argv[1])
    except ValueError:
        print(f"ERROR: Width must be an integer, got: {sys.argv[1]}", file=sys.stderr)
        sys.exit(1)

    if width < 100 or width > 7680:
        print(f"ERROR: Width {width} is out of reasonable range (100-7680)", file=sys.stderr)
        sys.exit(1)

    success = set_auxiliary_bar_width(width)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
