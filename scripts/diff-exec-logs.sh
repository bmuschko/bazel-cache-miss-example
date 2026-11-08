#!/usr/bin/env bash
# Prints every file and action key whose digest differs between two JSON execution logs.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <exec-log-1.json> <exec-log-2.json>" >&2
  exit 2
fi

# Pairs each digest with the input or output path it belongs to, or with the target label for the action key.
digests() {
  jq -r '
    ((.inputs // []) + (.actualOutputs // []) | .[] | "\(.path)\t\(.digest.hash)"),
    (select(.digest) | "action key of \(.targetLabel)\t\(.digest.hash)")
  ' "$1" | sort -u
}

join -t $'\t' <(digests "$1") <(digests "$2") | awk -F '\t' '$2 != $3 { print $1 }'
