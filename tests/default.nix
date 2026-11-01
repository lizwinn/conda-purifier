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

  # A real project: the development environment of geopandas, pinned to a
  # commit, with a lockfile that conda-purifier wrote for it. The source is
  # fetched at evaluation time, since lock.nix reads its environment file.
  geopandasSrc = builtins.fetchTarball {
    url = "https://github.com/geopandas/geopandas/archive/ead9a4fe380b3e5cb189fca03328af4e1db5fa33.tar.gz";
    sha256 = "sha256-9sR1nMgm6iiDQSD4KN8cI9WD38eB/mARv/MHGbOZwIo=";
  };
  geopandas = buildCondaProject {
    src = geopandasSrc;
    lockFile = ./real/geopandas/conda-purifier.lock.json;
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
        # pip says what to do instead of installing into the environment.
        if ${app.env}/bin/python -m pip install --no-index six > pip.log 2>&1; then
          echo "pip installed into the environment" >&2
          exit 1
        fi
        grep -q 'run `conda-purifier lock`' pip.log
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

  # geopandas' own tests of its geometry methods and coordinate reference
  # systems pass in the environment, offline in the sandbox, against the
  # GDAL, GEOS and PROJ of conda-forge.
  real-geopandas = pkgs.runCommand "real-geopandas-check" { } ''
    cp -r ${geopandasSrc} source
    chmod -R u+w source
    cd source
    export HOME=$TMPDIR
    # setuptools-scm writes this file when geopandas is installed from a
    # checkout; the tests run from the source tree.
    echo '__version__ = "1.1.2.dev0+gead9a4fe"' > geopandas/_version.py
    ${geopandas.env}/bin/python -m pytest -q -p no:cacheprovider \
      geopandas/tests/test_geom_methods.py geopandas/tests/test_crs.py
    touch $out
  '';

  # The project's own package and the git requirement build without version
  # control metadata, so setuptools-scm gets the versions the lock run saw.
  scm-versions = evalCheck "scm-versions" (
    app.env.SETUPTOOLS_SCM_PRETEND_VERSION_FOR_HELLO_CONDA == "0.1.0"
    && app.env.SETUPTOOLS_SCM_PRETEND_VERSION_FOR_SAMPLEPROJECT == "4.0.0"
    && app.packages.hello-conda.SETUPTOOLS_SCM_PRETEND_VERSION_FOR_HELLO_CONDA == "0.1.0"
    && !(app.env ? SETUPTOOLS_SCM_PRETEND_VERSION_FOR_SIX)
  ) "the builds do not pass the locked versions to setuptools-scm";

  # A lock with a package hash or a package entry changed by hand is refused
  # before anything is fetched.
  lock-edited = evalCheck "lock-edited" (
    fails
      (readLock {
        src = ./fixtures/explicit;
        lockFile = ./fixtures/tampered-hash/conda-purifier.lock.json;
      }).conda
    &&
      fails
        (readLock {
          src = ./fixtures/explicit;
          lockFile = ./fixtures/missing-entry/conda-purifier.lock.json;
        }).conda
  ) "the lock reader accepted a lockfile edited by hand";

  # A lock whose environment.yml changed afterwards is refused, and so is a
  # platform the lock does not cover.
  lock-refusals = evalCheck "lock-refusals" (
    fails (readLock { src = ./fixtures/stale; }).conda
    && fails (readLock { platform = lib.systems.elaborate "powerpc64le-linux"; }).conda
  ) "the lock reader accepted a stale lock or an unlocked platform";
}
