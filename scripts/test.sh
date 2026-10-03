#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
node --test tests/*.test.mjs
python3 -m unittest discover -s tests -p 'test_*.py'
if command -v swiftc >/dev/null; then
  devflow_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/devflow-tests.XXXXXX")
  trap 'rm -rf "$devflow_test_dir"' EXIT
  for suite in IslandScreenGeometry SafeWebURL PipelineDateFilter IslandStateMachine; do
    swiftc "NotchBuddy/Sources/App/${suite}.swift" "tests/${suite}Tests.swift" -o "$devflow_test_dir/$suite"
    "$devflow_test_dir/$suite"
  done
fi
