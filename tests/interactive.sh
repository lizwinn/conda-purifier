#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Exercises conda-purifier outside the sandbox, on a copy of the app
# fixture: `run` and `shell` use the Nix-built environment, a changed
# environment.yml is refused until the next lock, and `publish` hands the
# wheel Nix built to twine. It needs the network only for the lock run.
#
# Run it from the repository root: tests/interactive.sh
set -euo pipefail

cli=$(nix build --no-link --print-out-paths '.#conda-purifier')/bin/conda-purifier
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r tests/fixtures/app "$work/app"
cd "$work/app"

line=$("$cli" run -- hello-conda 1)
[ "$line" = "hello from conda: n+1=2 inverse-sum=1.5 six=1.17.0 numpy=2" ]
echo "run: $line"

[ "$(SHELL=/bin/sh "$cli" shell <<<'echo "$HELLO_CONDA_GREETING"')" = "hello from conda" ]
echo "shell: the environment's variables are set"

echo "# changed" >> environment.yml
if "$cli" run -- true 2> err.txt; then
  echo "a changed environment.yml was not refused" >&2
  exit 1
fi
grep -q 'run `conda-purifier lock` again' err.txt
echo "run: a changed environment.yml is refused"
"$cli" lock
"$cli" run -- hello-conda 2 | grep -q 'n+1=3'
echo "lock: the new lock builds"

# uv fails to connect after Nix built the wheel it would upload.
"$cli" publish -- --publish-url http://127.0.0.1:9/ --username x --password y > err.txt 2>&1 || true
ls .conda-purifier/package-hello-conda/hello_conda-0.1.0-py3-none-any.whl
grep -q 'hello_conda-0.1.0-py3-none-any.whl' err.txt
grep -qi 'connect' err.txt
echo "publish: uv was given the wheel Nix built"
