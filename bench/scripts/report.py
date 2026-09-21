#!/usr/bin/env python3
"""Merge the judges, run Vale over the corpus, and report the gap.

Reads bench/corpus/<suite> and bench/judgments/<suite>. For every
document it groups the judges' annotations by sentence, keeps a sentence
as a confirmed tell when at least two judges flagged it, and lists the
sentences one judge alone flagged as splits for the adjudicator. It then
runs Vale over each document with the fork's ai-tells style and matches
Vale's findings to the confirmed sentences by line.

Writes under bench/results/<suite>/<timestamp>/:
  confirmed.json    confirmed tells with the judges, categories, and regexes
  splits.json       one-judge tells, the adjudicator's queue
  vale.json         Vale findings per document
  gap.json          confirmed tells Vale missed, grouped by category
  summary.json      totals in the bench summary shape (metadata, rankings)
  report.md         the human table
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAJORITY = 2


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def norm(sentence: str) -> str:
    return re.sub(r"\s+", " ", sentence).strip().lower()


def vale_findings(doc: Path) -> list[dict]:
    result = subprocess.run(
        ["vale", "--config", str(ROOT / "bench" / "vale.ini"), "--output=JSON", "--minAlertLevel=suggestion", str(doc)],
        capture_output=True, text=True, check=False, cwd=ROOT,
    )
    try:
        data = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        return []
    if "Code" in data:
        return []
    return [f for findings in data.values() for f in findings]


def line_of(text: str, sentence: str) -> int | None:
    needle = norm(sentence)[:60]
    for number, line in enumerate(text.splitlines(), start=1):
        if needle and needle in norm(line):
            return number
    return None


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: report.py <suite-id>", file=sys.stderr)
        return 2
    suite = argv[1]
    corpus = ROOT / "bench" / "corpus" / suite
    judgments = ROOT / "bench" / "judgments" / suite
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
    out = ROOT / "bench" / "results" / suite / stamp
    out.mkdir(parents=True)

    confirmed: list[dict] = []
    splits: list[dict] = []
    vale_all: dict[str, list[dict]] = {}
    gap: list[dict] = []
    per_judge = Counter()
    per_generator = Counter()
    docs = 0

    for record in sorted(corpus.glob("*/*.run.json")):
        run = load_json(record)
        gen_slug = run["profile"].replace("@", "-")
        name = f"{gen_slug}--{run['test']}"
        doc = corpus / gen_slug / f"{run['test']}.md"
        if not doc.is_file() or doc.stat().st_size == 0:
            continue
        docs += 1
        text = doc.read_text(encoding="utf-8")
        votes: dict[str, list[dict]] = defaultdict(list)
        for judgment in judgments.glob(f"*/{name}.json"):
            judge = judgment.parent.name
            for annotation in load_json(judgment).get("annotations", []):
                key = norm(annotation.get("sentence", ""))
                if key:
                    votes[key].append({"judge": judge, **annotation})
                    per_judge[judge] += 1
        findings = vale_findings(doc)
        vale_all[name] = findings
        vale_lines = {f["Line"] for f in findings}
        for key, entries in votes.items():
            item = {
                "document": name,
                "generator": run["profile"],
                "sentence": entries[0]["sentence"],
                "judges": sorted({e["judge"] for e in entries}),
                "categories": sorted({e.get("category", "other") for e in entries}),
                "regexes": sorted({e["regex"] for e in entries if e.get("regex")}),
                "tells": [e.get("tell", "") for e in entries],
            }
            if len(item["judges"]) >= MAJORITY:
                line = line_of(text, item["sentence"])
                item["line"] = line
                item["vale_hit"] = line in vale_lines if line else False
                confirmed.append(item)
                per_generator[run["profile"]] += 1
                if not item["vale_hit"]:
                    gap.append(item)
            else:
                splits.append(item)

    by_category = Counter(c for item in gap for c in item["categories"])
    (out / "confirmed.json").write_text(json.dumps(confirmed, indent=2), encoding="utf-8")
    (out / "splits.json").write_text(json.dumps(splits, indent=2), encoding="utf-8")
    (out / "vale.json").write_text(json.dumps(vale_all, indent=2), encoding="utf-8")
    (out / "gap.json").write_text(json.dumps(gap, indent=2), encoding="utf-8")

    caught = len(confirmed) - len(gap)
    summary = {
        "metadata": {
            "suiteId": suite,
            "timestamp": stamp,
            "version": "tells-report-1",
            "documents": docs,
            "confirmedTells": len(confirmed),
            "valeCaught": caught,
            "valeMissed": len(gap),
            "valeRecall": round(caught / len(confirmed), 3) if confirmed else None,
            "splitsForAdjudicator": len(splits),
            "majority": MAJORITY,
        },
        "rankings": [
            {"model": generator, "confirmedTells": count}
            for generator, count in per_generator.most_common()
        ],
        "judges": [{"judge": judge, "annotations": count} for judge, count in per_judge.most_common()],
        "gapByCategory": [{"category": c, "missed": n} for c, n in by_category.most_common()],
    }
    (out / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")

    lines = [
        f"# Tells report: {suite} at {stamp}",
        "",
        f"Documents {docs}. Confirmed tells (at least {MAJORITY} judges) {len(confirmed)}. "
        f"Vale caught {caught}, missed {len(gap)}. Splits for the adjudicator {len(splits)}.",
        "",
        "| Generator | Confirmed tells |",
        "|---|---|",
        *[f"| {r['model']} | {r['confirmedTells']} |" for r in summary["rankings"]],
        "",
        "| Category Vale missed | Count |",
        "|---|---|",
        *[f"| {g['category']} | {g['missed']} |" for g in summary["gapByCategory"]],
        "",
    ]
    (out / "report.md").write_text("\n".join(lines), encoding="utf-8")
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
