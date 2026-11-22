"""Private before/after copies and per-service verification for local updates."""
import json
import os
import sys
import time
from datetime import date
from pathlib import Path


def capture(source, target):
    try:
        data = source.read_bytes()
    except FileNotFoundError:
        data = None
    rows = {}
    if data is not None:
        with target.open("xb") as output:
            output.write(data)
        document = json.loads(data)
        for row in document["entries"]:
            key = row["date"], row["provider"]
            if key in rows:
                raise ValueError("duplicate date/service in " + target.name)
            rows[key] = row
    return rows


def totals(row):
    if row.get("dailyTotals"):
        return row["dailyTotals"]
    if row.get("deltaUnit") and row.get("dailyDelta") is not None:
        return {row["deltaUnit"]: row["dailyDelta"]}
    return {}


def compare(before, after):
    results = []
    for key in sorted(before.keys() | after.keys()):
        old, new = before.get(key), after.get(key)
        result = dict(date=key[0], provider=key[1], review=False)
        if new is None or old is None:
            result.update(status="missing" if new is None else "added", review=new is None)
        elif old == new:
            result.update(status="unchanged")
        else:
            prior, current = totals(old), totals(new)
            result.update(status="changed", fields=sorted(k for k in old.keys() | new.keys()
                          if old.get(k) != new.get(k)), totalsBefore=prior, totalsAfter=current)
            result["review"] = key[0] != date.today().isoformat() or prior != current
        results.append(result)
    return results


def main(mode, directory, source):
    os.umask(0o077)
    before_path = directory / "before.json"
    if mode == "before":
        capture(source, before_path)
        return
    before = {}
    if before_path.exists():
        before = {(r["date"], r["provider"]): r for r in json.loads(before_path.read_bytes())["entries"]}
    # Give the first refresh a chance to finish even when launch returns immediately.
    initial = before_path.read_bytes() if before_path.exists() else None
    for _ in range(20):
        if (source.read_bytes() if source.exists() else None) != initial:
            break
        time.sleep(1)
    after = capture(source, directory / "after.json")
    rows = compare(before, after)
    (directory / "comparison.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2))
    review = sum(r["review"] for r in rows)
    print(f"History comparison: {len(rows)} date/service pairs, {review} require review. {directory}")
    if review or (before_path.exists() and not source.exists()):
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]))
