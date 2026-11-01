#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Exercises conda-purifier outside the sandbox, on a copy of the app
# fixture: `prefetch` builds the environment of the everyday loop, a
# changed environment.yml is refused until the next lock, a lockfile kept
# outside the project works through CONDA_PURIFIER_LOCKFILE, and `publish`
# hands the wheel Nix built to uv. It needs the network only for the lock
# run.
#
# Run it from the repository root: tests/interactive.sh
set -euo pipefail

repo=$PWD
cli=$(nix build --no-link --print-out-paths '.#conda-purifier')/bin/conda-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r tests/fixtures/app "$work/app"
chmod -R u+w "$work/app"
cd "$work/app"

"$cli" prefetch
# The greeting is a variable of environment.yml, which `conda activate`
# sets; the program runs without it here.
line=$(.conda-purifier/env/bin/hello-conda 1)
[ "$line" = "no greeting: n+1=2 inverse-sum=1.5 six=1.17.0 numpy=2" ]
echo "prefetch: $line"
ls .conda-purifier/downloads/pkgs > /dev/null
echo "prefetch: the downloads have a GC root"

echo "# changed" >> environment.yml
if "$cli" prefetch 2> err.txt; then
  echo "a changed environment.yml was not refused" >&2
  exit 1
fi
grep -q 'run `conda-purifier lock` again' err.txt
echo "prefetch: a changed environment.yml is refused"
"$cli" lock
"$cli" prefetch
.conda-purifier/env/bin/hello-conda 2 | grep -q 'n+1=3'
echo "lock: the new lock builds"

# The lockfile moves out of the project, and the GC roots go beside it.
mkdir ../outside
mv conda-purifier.lock.json ../outside/
rm -r .conda-purifier
CONDA_PURIFIER_LOCKFILE=$work/outside/conda-purifier.lock.json "$cli" prefetch
"$work"/outside/.conda-purifier/env/bin/hello-conda 3 | grep -q 'n+1=4'
echo "prefetch: a lockfile outside the project works"
mv ../outside/conda-purifier.lock.json .

# A conda-lock.yml kept outside the project: the lock starts from the copy
# in the project, the project's copy stays as it is, and the commands read
# the outside copy.
cp -r "$repo/tests/fixtures/conda-lock" "$work/cl"
chmod -R u+w "$work/cl"
rm "$work/cl/conda-purifier.lock.json"
"$cli" -C "$work/cl" --tool-lockfile "$work/tool/conda-lock.yml" lock
cmp "$work/tool/conda-lock.yml" "$work/cl/conda-lock.yml"
echo "# changed outside" >> "$work/tool/conda-lock.yml"
if "$cli" -C "$work/cl" --tool-lockfile "$work/tool/conda-lock.yml" prefetch 2> err.txt; then
  echo "the commands did not read the conda-lock.yml outside the project" >&2
  exit 1
fi
grep -q 'run `conda-purifier lock` again' err.txt
export CONDA_PURIFIER_TOOL_LOCKFILE=$work/tool/conda-lock.yml
"$cli" -C "$work/cl" lock
"$cli" -C "$work/cl" prefetch
unset CONDA_PURIFIER_TOOL_LOCKFILE
cmp "$work/cl/conda-lock.yml" "$repo/tests/fixtures/conda-lock/conda-lock.yml"
echo hello | "$work/cl/.conda-purifier/env/bin/zstd" | "$work/cl/.conda-purifier/env/bin/zstd" -d | grep -qx hello
echo "lock: a conda-lock.yml outside the project works"

# uv fails to connect after Nix built the wheel it would upload.
"$cli" publish -- --publish-url http://127.0.0.1:9/ --username x --password y > err.txt 2>&1 || true
ls .conda-purifier/release/hello_conda-0.1.0-py3-none-any.whl
grep -q 'hello_conda-0.1.0-py3-none-any.whl' err.txt
grep -qi 'connect' err.txt
echo "publish: uv was given the wheel Nix built"
