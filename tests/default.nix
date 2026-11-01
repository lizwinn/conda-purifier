# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked files.
{
  pkgs,
  # The flake's default package overlay, which adds buildCondaProject.
  overlay,
}:
let
  inherit (pkgs) lib;

  # Every fixture builds the way a consumer's package does: through
  # buildCondaProject of a package set the overlay applies to.
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildCondaProject;

  # An environment.yml with python and numpy from conda-forge, and a pip:
  # section with a pure wheel, a wheel per platform, an sdist, a git
  # requirement and the project's own package.
  app = buildCondaProject { src = ./fixtures/app; };

  # Explicit spec files, one per platform, with MD5 hashes only, as
  # `conda list --explicit --md5` writes them.
  explicit = buildCondaProject {
    src = ./fixtures/explicit;
    name = "bzip2-env";
  };

  # A pip: section with a Mercurial and a Subversion requirement.
  vcs = buildCondaProject { src = ./fixtures/vcs; };

  # A conda-lock.yml, reused as it is.
  condaLock = buildCondaProject {
    src = ./fixtures/conda-lock;
    name = "zstd-env";
  };

  host = pkgs.stdenv.hostPlatform;
  readLock =
    args:
    import ../nix/lib/lock.nix (
      {
        inherit lib;
        src = ./fixtures/app;
        lockFile = ./fixtures/app/conda-purifier.lock.json;
        platform = host;
      }
      // args
    );

  # A lockfile check passes when `assertion` holds; it fails with
  # `message` otherwise.
  evalCheck =
    name: assertion: message:
    if assertion then
      pkgs.runCommand name { } "touch $out"
    else
      throw "conda-purifier check ${name}: ${message}";

  fails = value: !(builtins.tryEval (builtins.deepSeq value value)).success;
in
{
  # The project's command runs with the environment's variables and finds
  # a package of every kind the pip: section has, and numpy from conda.
  app =
    pkgs.runCommand "app-check"
      {
        nativeBuildInputs = [ app.programs.hello-conda ];
      }
      ''
        line=$(hello-conda 41)
        echo "$line"
        [ "$line" = "hello from conda: n+1=42 inverse-sum=1.5 six=1.17.0 numpy=2" ]
        touch $out
      '';

  # numpy comes from the conda package, not from a wheel on PyPI, and the
  # command of the git requirement is a program of the environment.
  app-environment =
    pkgs.runCommand "app-environment-check"
      {
        nativeBuildInputs = [ app.programs.sample ];
      }
      ''
        ls ${app.env}/conda-meta/numpy-2.*.json
        ${app.env}/bin/python -c 'import importlib.metadata as m; i = m.distribution("numpy").read_text("INSTALLER").strip(); assert i == "conda", i'
        sample
        grep -q HELLO_CONDA_GREETING ${app.env}/conda-meta/state
        touch $out
      '';

  # The wheel of the project's own package is built, ready to publish.
  app-package = pkgs.runCommand "app-package-check" { } ''
    ls ${app.packages.hello-conda}/hello_conda-0.1.0-py3-none-any.whl
    touch $out
  '';

  # The development shell holds the environment and sets its variables.
  app-shell =
    assert lib.elem app.env app.shell.nativeBuildInputs;
    pkgs.runCommand "app-shell-check" { } ''
      ${app.shell.shellHook}
      [ "$HELLO_CONDA_GREETING" = "hello from conda" ]
      [ "$CONDA_PREFIX" = ${app.env} ]
      touch $out
    '';

  explicit = pkgs.runCommand "explicit-check" { nativeBuildInputs = [ explicit.programs.bzip2 ]; } ''
    echo hello | bzip2 | bzip2 -d | grep -qx hello
    touch $out
  '';

  conda-lock =
    pkgs.runCommand "conda-lock-check" { nativeBuildInputs = [ condaLock.programs.zstd ]; }
      ''
        echo hello | zstd | zstd -d | grep -qx hello
        touch $out
      '';

  # The Mercurial and Subversion requirements are installed from their
  # checkouts, with their commands.
  vcs = pkgs.runCommand "vcs-check" { nativeBuildInputs = [ vcs.programs.yoyo ]; } ''
    ${vcs.env}/bin/python -c 'import yoyo, docutils.core; print(docutils.core.publish_string("*x*", writer="html").count(b"<em>x</em>"))' | grep -qx 1
    yoyo --help > /dev/null
    touch $out
  '';

  # Each platform has its own packages and programs: the conda linker of
  # binutils is named for its platform.
  lock-platforms =
    let
      x86 = readLock { platform = lib.systems.elaborate "x86_64-linux"; };
      arm = readLock { platform = lib.systems.elaborate "aarch64-linux"; };
    in
    evalCheck "lock-platforms" (
      x86.subdir == "linux-64"
      && arm.subdir == "linux-aarch64"
      && lib.elem "x86_64-conda-linux-gnu-ld" x86.programs
      && lib.elem "aarch64-conda-linux-gnu-ld" arm.programs
      && x86.packages == { hello-conda = "hello"; }
      # The environment takes the name environment.yml gives it.
      && app.env.name == "hello-conda"
    ) "the lock reader did not select each platform's packages and programs";

  # A lock whose environment.yml changed afterwards is refused, and so is a
  # platform the lock does not cover.
  lock-refusals = evalCheck "lock-refusals" (
    fails (readLock { src = ./fixtures/stale; }).conda
    && fails (readLock { platform = lib.systems.elaborate "powerpc64le-linux"; }).conda
  ) "the lock reader accepted a stale lock or an unlocked platform";
}
