#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
node --test tests/*.test.mjs
python3 -m unittest discover -s tests -p 'test_*.py'
