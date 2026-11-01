#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-update: `conda-purifier update` moves a package that the
# previous lock pinned to an old version, and the lockfile then reads as a
# usable lock. It needs the network.
#
# Run it from the repository root: tests/update.sh
set -euo pipefail

repo=$PWD
cli=$(nix build --no-link --print-out-paths '.#conda-purifier')/bin/conda-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

printf 'channels:\n  - conda-forge\ndependencies:\n  - zstd=1.5.6\n' > environment.yml
"$cli" lock
grep -q 'zstd-1.5.6-' conda-purifier.lock.json

# The environment file now allows any zstd. `lock` keeps the packages the
# file does not name, and `update` moves everything.
printf 'channels:\n  - conda-forge\ndependencies:\n  - zstd\n' > environment.yml
"$cli" update
if grep -q 'zstd-1.5.6-' conda-purifier.lock.json; then
  echo "update left zstd at the old version" >&2
  exit 1
fi
grep -q 'zstd-1\.' conda-purifier.lock.json

# The updated lock passes the stale check of the command and of Nix.
"$cli" prefetch --help > /dev/null
problems=$(nix eval --json --impure --expr \
  "((builtins.getFlake \"git+file://$repo\").lib.conda-purifier.readLock { src = /. + \"$work\"; }).problems")
[ "$problems" = "[]" ]
echo "update: zstd moved, and the lockfile reads as usable"
