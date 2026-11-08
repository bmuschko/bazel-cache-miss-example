#!/usr/bin/env bash
# Asserts how many actions a Bazel build executed and how many it served from the disk cache.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <build-log> <executed> <disk-cache-hits>" >&2
  exit 2
fi

log="$1" want_executed="$2" want_hits="$3"
executed=0 hits=0

summary="$(grep -E '^INFO: [0-9]+ process(es)?:' "${log}" | tail -1)"
[[ -n "${summary}" ]] || { echo "FAIL: no process summary found in ${log}"; exit 1; }
echo "${summary}"

# Strips the "INFO: N processes: " prefix and the trailing period, then tallies each category.
while IFS= read -r entry; do
  count="${entry%% *}"
  label="${entry#* }"
  case "${label}" in
    internal | "action cache hit") ;;
    "disk cache hit") hits=$((hits + count)) ;;
    *) executed=$((executed + count)) ;;
  esac
done < <(echo "${summary}" | sed -E 's/^INFO: [0-9]+ process(es)?: //; s/\.$//' | tr ',' '\n' | sed -E 's/^ +//')

echo "executed=${executed} disk-cache-hits=${hits}"
if [[ "${executed}" != "${want_executed}" || "${hits}" != "${want_hits}" ]]; then
  echo "FAIL: expected executed=${want_executed} disk-cache-hits=${want_hits}"
  exit 1
fi
echo "PASS"
