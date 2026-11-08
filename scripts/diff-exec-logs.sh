#!/usr/bin/env bash
# Prints every file and action key whose digest differs between two parsed execution logs.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <exec-log-1.txt> <exec-log-2.txt>" >&2
  exit 2
fi

# Pairs each digest with the input or output path it belongs to, or with the target label for the action key.
digests() {
  awk '
    /^ *path: / { key = $2 }
    /^target_label: / { key = "action key of " $2 }
    /^ *hash: / && key != "" { gsub(/"/, "", key); gsub(/"/, "", $2); print key "\t" $2; key = "" }
  ' "$1" | sort -u
}

join -t $'\t' <(digests "$1") <(digests "$2") | awk -F '\t' '$2 != $3 { print $1 }'
