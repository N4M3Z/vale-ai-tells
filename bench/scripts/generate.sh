#!/usr/bin/env bash
# generate — run every prompt of a suite through every generator model and
# keep the text, the transcript, and the run record.
#
# Each (model, prompt) pair becomes one document under
#   bench/corpus/<suite>/<model>/<prompt-id>.md
# with a sidecar <prompt-id>.run.json that records the tool, the resolved
# model id, the harness version, exit status, wall time, and the digest of
# the text. The rune run transcript goes to <prompt-id>.transcript.txt.
# The record is what the judge stage and the report read; the transcript is
# the proof that the text came from the named harness.
#
# Usage: bash bench/scripts/generate.sh <suite-id> [model...]
#   Models default to the four generators in bench/models.yaml. A model is
#   a rune profile address such as grok@grok. A document that exists with a
#   matching prompt digest is skipped, so a rerun fills gaps only.
#
# Run this outside a nested sandbox: every harness starts its own.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SUITE_ID=${1:?usage: generate.sh <suite-id> [model...]}
shift
SUITE="$ROOT/bench/suites/$SUITE_ID.json"
[ -f "$SUITE" ] || { echo "no suite $SUITE" >&2; exit 2; }

if [ $# -gt 0 ]; then
    MODELS=("$@")
else
    mapfile -t MODELS < <(yq -r '.generators[].profile' "$ROOT/bench/models.yaml")
fi

SYSTEM=$(jq -r '.system_prompt' "$SUITE")
OUT_BASE="$ROOT/bench/corpus/$SUITE_ID"
TIMEOUT=${GENERATE_TIMEOUT:-30m}
# An empty working directory, so an agentic harness has nothing to read
# but the prompt.
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/tells-run.XXXXXX")
trap 'command rm -rf "$SCRATCH"' EXIT

for model in "${MODELS[@]}"; do
    slug=${model//@/-}
    out="$OUT_BASE/$slug"
    mkdir -p "$out"
    jq -c '.tests[]' "$SUITE" | while IFS= read -r test; do
        id=$(jq -r '.id' <<<"$test")
        prompt=$(jq -r '.prompt' <<<"$test")
        prompt_digest=$(printf '%s\n\n%s' "$SYSTEM" "$prompt" | shasum -a 256 | cut -d' ' -f1)
        doc="$out/$id.md"
        record="$out/$id.run.json"
        if [ -f "$record" ] && [ "$(jq -r '.prompt_sha256' "$record")" = "$prompt_digest" ] && [ -s "$doc" ]; then
            echo "skip $slug/$id"
            continue
        fi
        prompt_file=$(mktemp "${TMPDIR:-/tmp}/gen.XXXXXX")
        printf '%s\n\n%s\n' "$SYSTEM" "$prompt" >"$prompt_file"
        started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        t0=$(date +%s)
        status=0
        rune run "$model" --clean-harness-state --prompt-file "$prompt_file" --timeout "$TIMEOUT" --repo "$SCRATCH" --json \
            >"$out/$id.transcript.json" 2>"$out/$id.stderr.txt" || status=$?
        t1=$(date +%s)
        # rune run --json reports the final assistant text as .text and the
        # model the harness answered with as .resolved_model.
        jq -r '.text // empty' "$out/$id.transcript.json" >"$doc" 2>/dev/null || true
        jq -n \
            --arg suite "$SUITE_ID" --arg test "$id" --arg profile "$model" \
            --arg model_id "$(jq -r '.resolved_model // empty' "$out/$id.transcript.json" 2>/dev/null)" \
            --arg tool "${model##*@}" \
            --arg started "$started" --argjson seconds "$((t1 - t0))" --argjson status "$status" \
            --arg prompt_sha "$prompt_digest" \
            --arg text_sha "$(shasum -a 256 "$doc" | cut -d' ' -f1)" \
            --argjson words "$(wc -w <"$doc" | tr -d ' ')" \
            '{suite: $suite, test: $test, profile: $profile, tool: $tool, model_id: $model_id,
              started: $started, seconds: $seconds, exit: $status,
              prompt_sha256: $prompt_sha, text_sha256: $text_sha, words: $words}' >"$record"
        rm -f "$prompt_file"
        echo "$slug/$id exit=$status words=$(jq -r .words "$record") ${t1}s"
    done
done
