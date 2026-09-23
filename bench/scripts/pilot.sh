#!/usr/bin/env bash
# pilot — the three phases of a tells run in order: generate the corpus,
# judge it, report the gap. Each phase is its own asciinema recording under
# bench/results/<suite>/proofs/, rendered to a GIF and a transcript, so the
# run is reproducible from the recording alone.
#
# Usage: bash bench/scripts/pilot.sh <suite-id> [generate] [judge] [report]
#   With no phase named, all three run. Naming phases reruns the ones
#   that failed without re-recording the ones that passed.
# Run from a plain terminal or through `sd job start`, never inside a
# harness sandbox: every generator and judge starts its own sandbox and
# they do not nest.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SUITE_ID=${1:?usage: pilot.sh <suite-id> [phase...]}
shift
PHASES=("$@")
[ ${#PHASES[@]} -gt 0 ] || PHASES=(generate judge report)
PROOFS="$ROOT/bench/results/$SUITE_ID/proofs"
mkdir -p "$PROOFS"

record() {
    local phase=$1
    shift
    local cast="$PROOFS/$phase.cast"
    asciinema rec --overwrite --quiet --command "$*" "$cast"
    asciinema convert -f txt --overwrite "$cast" "$PROOFS/$phase.txt"
    if command -v agg >/dev/null; then
        agg --theme github-dark --font-size 11 --fps-cap 3 --last-frame-duration 3 "$cast" "$PROOFS/$phase.gif"
    fi
    shasum -a 256 "$PROOFS/$phase.txt" | cut -d' ' -f1 >"$PROOFS/$phase.sha256"
}

for phase in "${PHASES[@]}"; do
    case "$phase" in
        generate) record generate bash "$ROOT/bench/scripts/generate.sh" "$SUITE_ID" ;;
        judge) record judge bash "$ROOT/bench/scripts/judge.sh" "$SUITE_ID" ;;
        report) record report python3 "$ROOT/bench/scripts/report.py" "$SUITE_ID" ;;
        *) echo "unknown phase $phase" >&2; exit 2 ;;
    esac
done

latest=$(ls -d "$ROOT/bench/results/$SUITE_ID"/*Z | tail -1)
cat "$latest/report.md"
