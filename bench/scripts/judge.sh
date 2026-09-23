#!/usr/bin/env bash
# judge — send every corpus document to every judge that did not write it
# and keep each judge's annotations.
#
# Output per (judge, document):
#   bench/judgments/<suite>/<judge>/<generator>--<prompt-id>.json
# holding the parsed annotation object, plus .transcript.json and
# .run.json sidecars in the same shape generate.sh writes. A judge never
# reads a document from its own model family (bench/models.yaml).
#
# Usage: bash bench/scripts/judge.sh <suite-id> [judge-profile...]
#   Existing judgments whose text digest matches are skipped.
#
# Run this outside a nested sandbox: every harness starts its own.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SUITE_ID=${1:?usage: judge.sh <suite-id> [judge...]}
shift
MODELS="$ROOT/bench/models.yaml"
CORPUS="$ROOT/bench/corpus/$SUITE_ID"
OUT_BASE="$ROOT/bench/judgments/$SUITE_ID"
TEMPLATE="$ROOT/bench/prompts/judge.md"
TIMEOUT=${JUDGE_TIMEOUT:-15m}
# An empty working directory, so an agentic harness has nothing to read
# but the prompt.
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/tells-run.XXXXXX")
trap 'command rm -rf "$SCRATCH"' EXIT

if [ $# -gt 0 ]; then
    JUDGES=("$@")
else
    mapfile -t JUDGES < <(yq -r '.judges[].profile' "$MODELS")
fi

family_of() {
    # mikefarah yq: no --arg, values come in through env().
    P="$1" yq -r '(.generators + .judges)[] | select(.profile == env(P)) | .family' "$MODELS" | head -1
}

for judge in "${JUDGES[@]}"; do
    judge_slug=${judge//@/-}
    judge_family=$(family_of "$judge")
    out="$OUT_BASE/$judge_slug"
    mkdir -p "$out"
    for record in "$CORPUS"/*/*.run.json; do
        gen_profile=$(jq -r '.profile' "$record")
        [ "$(family_of "$gen_profile")" = "$judge_family" ] && continue
        test_id=$(jq -r '.test' "$record")
        gen_slug=${gen_profile//@/-}
        doc="$CORPUS/$gen_slug/$test_id.md"
        [ -s "$doc" ] || continue
        text_sha=$(jq -r '.text_sha256' "$record")
        name="$gen_slug--$test_id"
        if [ -f "$out/$name.run.json" ] && [ "$(jq -r '.text_sha256' "$out/$name.run.json")" = "$text_sha" ] \
            && jq -e 'has("parse_error") | not' "$out/$name.json" >/dev/null 2>&1; then
            echo "skip $judge_slug/$name"
            continue
        fi
        prompt_file=$(mktemp "${TMPDIR:-/tmp}/judge.XXXXXX")
        # Fill the template without sed, so regex characters in the text
        # survive: everything before the marker, then the id, then the text.
        {
            sed -n '1,/^====================$/p' "$TEMPLATE" | sed "s/{{DOCUMENT_ID}}/$name/"
            cat "$doc"
        } >"$prompt_file"
        started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        t0=$(date +%s)
        status=0
        # Every judge runs through rune run with clean harness state, so
        # no user-level instruction file reaches the model.
        rune run "$judge" --clean-harness-state --prompt-file "$prompt_file" --timeout "$TIMEOUT" --repo "$SCRATCH" --json \
            >"$out/$name.transcript.json" 2>"$out/$name.stderr.txt" || status=$?
        t1=$(date +%s)
        # The answer is JSON, sometimes inside a fence. Take the first
        # balanced object that has an annotations array.
        jq -r '.text // empty' "$out/$name.transcript.json" \
            | perl -0ne 'print $1 if /(\{.*"annotations"\s*:\s*\[.*\]\s*\})/s' \
            | jq '.' >"$out/$name.json" 2>/dev/null || true
        # An empty or unparsable answer (a harness exit, a refusal, prose
        # with no object) is recorded as zero annotations with parse_error,
        # so the phase continues and the pair is retried on the next run.
        if ! jq -e '.annotations | type == "array"' "$out/$name.json" >/dev/null 2>&1; then
            printf '{"document":"%s","annotations":[],"parse_error":true}\n' "$name" >"$out/$name.json"
        fi
        count=$(jq '.annotations | length' "$out/$name.json")
        jq -n \
            --arg suite "$SUITE_ID" --arg document "$name" --arg profile "$judge" \
            --arg model_id "$(jq -r '.resolved_model // empty' "$out/$name.transcript.json" 2>/dev/null)" \
            --arg started "$started" --argjson seconds "$((t1 - t0))" --argjson status "$status" \
            --arg text_sha "$text_sha" \
            --argjson count "$count" \
            '{suite: $suite, document: $document, profile: $profile, model_id: $model_id,
              started: $started, seconds: $seconds, exit: $status,
              text_sha256: $text_sha, annotations: $count}' >"$out/$name.run.json"
        rm -f "$prompt_file"
        echo "$judge_slug/$name exit=$status annotations=$(jq -r .annotations "$out/$name.run.json")"
    done
done
