#!/usr/bin/env bash
# Compares the Swift filter against the exact-fraction Python reference on several sequences.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product hmmcheck >/dev/null
BIN="$(swift build --show-bin-path)/hmmcheck"
status=0
for seq in "2 6 6 1 6 6" "6 6 6 6 6 6 6 6 6 6" "1 2 3 4 5 1 2 3" "6 0 6 0 0 1 6" "3"; do
  if diff <("$BIN" csv $seq) <(python3 -I reference/hmm_reference.py --csv $seq) >/dev/null; then
    echo "MATCH     [$seq]"
  else
    echo "MISMATCH  [$seq]"; diff <("$BIN" csv $seq) <(python3 -I reference/hmm_reference.py --csv $seq) || true; status=1
  fi
done
exit $status
