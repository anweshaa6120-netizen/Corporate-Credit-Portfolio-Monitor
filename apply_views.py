"""Apply every sql/*.sql file to the DuckDB database, in filename order.

Kept deliberately thin: the SQL files are the product, this only runs them.
Files are numbered so the sanity checks (00_, 99_) bracket the views, and any
failing check aborts the run via DuckDB's error().

Run:  python apply_views.py [--db data/portfolio.duckdb]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import duckdb

ROOT = Path(__file__).parent
DEFAULT_DB = ROOT / "data" / "portfolio.duckdb"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--db", type=Path, default=DEFAULT_DB)
    args = ap.parse_args()
    if not args.db.exists():
        print(f"{args.db} not found -- run `make seed` first", file=sys.stderr)
        return 1

    con = duckdb.connect(str(args.db))
    for path in sorted((ROOT / "sql").glob("*.sql")):
        try:
            result = con.execute(path.read_text())
        except duckdb.Error as exc:
            print(f"FAILED  {path.name}\n        {exc}", file=sys.stderr)
            return 1
        if "checks" in path.name:
            for name, status in result.fetchall():
                print(f"  check  {name:<52}{status}")
        else:
            print(f"applied {path.name}")
    con.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
