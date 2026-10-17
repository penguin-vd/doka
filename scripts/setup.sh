#!/bin/sh
# Once per clone: git's hooks from scripts/hooks/.
#   scripts/setup.sh
set -eu
cd "$(dirname "$0")/.."
git config core.hooksPath scripts/hooks
echo "hooks: scripts/hooks"
