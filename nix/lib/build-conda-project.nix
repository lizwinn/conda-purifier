# SPDX-License-Identifier: MIT
#
# Builds a conda project from its conda-purifier.lock.json in the Nix
# sandbox, offline. The result holds every output the lockfile names:
#
#   env              the environment: conda's packages, created by
#                    micromamba from the locked files, with the pip:
#                    section installed into it
#   programs.<name>  each executable of the environment's bin/, wrapped so
#                    that it runs with the environment's variables
#   packages.<name>  the wheel of each of the project's own Python
#                    packages (the local directories of the pip: section)
#   shell            a development shell with the environment active
#
# conda's binaries ask for the dynamic linker at /lib64, which the sandbox
# and NixOS do not have. The build points every ELF file of the environment
# at the linker of the package set; the libraries stay conda's own, found
# through their $ORIGIN run paths.
{
  lib,
  pkgs,
  # The shared library of the nix-purifiers (github:nix-purifiers/purifier),
  # which fetches the download entries and lays them out as a tree.
  purifier,
  stdenv,
  stdenvNoCC,
  writeText,
  micromamba,
  patchelf,
  makeWrapper,
  runCommand,
  mkShell,
}:
{
  # The project directory, holding conda-purifier.lock.json and the files
  # it was made from.
  src,
  lockFile ? src + "/conda-purifier.lock.json",
  # The name of the environment in the store. The default is the `name` of
  # environment.yml, or conda-env.
  name ? null,
  # Runs the conda packages' post-link scripts after the interpreters are
  # patched, as conda does when it installs them.
  runLinkScripts ? true,
  # The fetcher of locked files. A private channel needs one that brings
  # credentials, such as fetchurl with a netrc (see the README); the
  # lockfile holds the channel's URLs without their tokens.
  fetchurl ? null,
}:
let
  locked = import ./lock.nix {
    inherit lib src lockFile;
    platform = stdenv.hostPlatform;
  };

  envName =
    if name != null then
      name
    else if locked.name != null then
      locked.name
    else
      "conda-env";

  # Every locked download, at its path: the conda packages under pkgs/, the
  # pip: section's files under pip/ and its checkouts beside them. The
  # project's own directories are not downloads.
  isDownload = e: !(e ? local);
  dependencies = purifier.tree (
    {
      inherit pkgs;
      name = "${envName}-dependencies";
      entries = locked.conda ++ builtins.filter isDownload (locked.pip ++ locked.pipBuild);
    }
    // lib.optionalAttrs (fetchurl != null) { inherit fetchurl; }
  );

  hex =
    sri:
    builtins.convertHash {
      hash = sri;
      toHashFormat = "base16";
    };

  # micromamba installs from this list, in order, with the hash of each
  # package, from a package cache it finds every file in.
  explicit = writeText "${envName}-explicit.txt" (
    "@EXPLICIT\n" + lib.concatMapStrings (e: "${e.url}#sha256:${hex e.hash}\n") locked.conda
  );

  # A package's post-link script runs with the package's name, version and
  # build number, which its file name holds.
  linkScripts = writeText "${envName}-packages.tsv" (
    lib.concatMapStrings (
      e:
      let
        stem = lib.removeSuffix ".tar.bz2" (lib.removeSuffix ".conda" (baseNameOf e.path));
        parts = lib.splitString "-" stem;
        build = lib.last parts;
        buildNumber = lib.last (lib.splitString "_" build);
      in
      "${e.name}\t${e.version}\t${buildNumber}\n"
    ) locked.conda
  );

  # What pip installs: each package's file or checkout, or the project's own
  # directory. pip builds a directory in place, so the build copies them.
  pipTargets = lib.concatMapStrings (
    e:
    if e ? local then
      "copy ${lib.escapeShellArg "${src}/${e.local}"}\n"
    else if e ? url then
      "file ${dependencies}/${e.path}\n"
    else
      "copy ${dependencies}/${e.path}\n"
  ) locked.pip;

  # The build has no version control metadata. A package built from a
  # directory or a checkout whose version setuptools-scm computes gets the
  # version the lock run recorded, where pip saw the repository.
  scmNormalize =
    name:
    lib.toUpper (
      lib.concatStringsSep "_" (
        builtins.filter (s: builtins.isString s && s != "") (builtins.split "[-_.]+" name)
      )
    );
  scmVersions = lib.listToAttrs (
    map (e: lib.nameValuePair "SETUPTOOLS_SCM_PRETEND_VERSION_FOR_${scmNormalize e.name}" e.version) (
      builtins.filter (e: !(e ? url)) locked.pip
    )
  );

  env = stdenvNoCC.mkDerivation (
    scmVersions
    // {
      name = envName;
      dontUnpack = true;
      nativeBuildInputs = [
        micromamba
        patchelf
      ];
      passAsFile = [
        "pipTargets"
        "stateJson"
      ];
      inherit pipTargets;
      stateJson = builtins.toJSON { env_vars = locked.variables; };
      dynamicLinker = stdenv.cc.bintools.dynamicLinker;
      buildPhase = ''
        runHook preBuild
        export HOME=$TMPDIR/home MAMBA_ROOT_PREFIX=$TMPDIR/root CONDA_PKGS_DIRS=$TMPDIR/pkgs
        mkdir -p "$HOME" "$CONDA_PKGS_DIRS"
        for f in ${dependencies}/pkgs/*; do
          cp "$f" "$CONDA_PKGS_DIRS/$(basename "$f")"
        done

        micromamba create --yes --no-rc --offline --no-pyc --copy \
          --skip-run-link-scripts --prefix "$out" --file ${explicit}

        ${lib.optionalString stdenv.hostPlatform.isLinux ''
          while IFS= read -r -d "" f; do
            if [ ! -L "$f" ] && head -c 4 "$f" | grep -q $'\x7fELF' \
                && patchelf --print-interpreter "$f" >/dev/null 2>&1; then
              chmod u+w "$f"
              patchelf --set-interpreter "$dynamicLinker" "$f"
            fi
          done < <(find "$out" -type f -print0)
        ''}

        ${lib.optionalString runLinkScripts ''
          while IFS=$'\t' read -r pkg version build; do
            script="$out/bin/.$pkg-post-link.sh"
            if [ -f "$script" ]; then
              echo "running the post-link script of $pkg"
              PREFIX="$out" PKG_NAME="$pkg" PKG_VERSION="$version" PKG_BUILDNUM="$build" \
                PATH="$out/bin:$PATH" bash "$script"
            fi
          done < ${linkScripts}
        ''}

        if [ -s "$pipTargetsPath" ]; then
          targets=()
          n=0
          while read -r kind path; do
            if [ "$kind" = copy ]; then
              n=$((n + 1))
              cp -rL --no-preserve=mode "$path" "$TMPDIR/pip-$n"
              targets+=("$TMPDIR/pip-$n")
            else
              targets+=("$path")
            fi
          done < "$pipTargetsPath"
          PIP_CONFIG_FILE=/dev/null "$out/bin/python" -m pip install --disable-pip-version-check \
            --no-index --no-deps --no-cache-dir --no-compile --no-warn-script-location \
            --find-links ${dependencies}/pip "''${targets[@]}"
        fi

        if [ -x "$out/bin/python" ]; then
          stdlib=$("$out/bin/python" -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')
          "$out/bin/python" -m compileall -q -j0 --invalidation-mode unchecked-hash \
            "$stdlib" >/dev/null || true
          # pip refuses to install into the environment and says why (PEP 668).
          cat > "$stdlib/EXTERNALLY-MANAGED" <<'EOF'
        [externally-managed]
        Error=This environment is built by conda-purifier from conda-purifier.lock.json and is read-only. Add the package to the environment file, to its dependencies or to its pip: section, then run `conda-purifier lock`.
        EOF
        fi

        # conda reads the environment's variables from here when it activates
        # the environment.
        cp "$stateJsonPath" "$out/conda-meta/state"
        # The history records when the environment was made.
        echo "==> conda-purifier <==" > "$out/conda-meta/history"
        runHook postBuild
      '';
      dontInstall = true;
      dontFixup = true;
      passthru = {
        inherit dependencies locked;
      };
    }
  );

  setVariables = lib.concatStringsSep " " (
    lib.mapAttrsToList (k: v: "--set ${lib.escapeShellArg k} ${lib.escapeShellArg v}") locked.variables
  );

  # A store name allows fewer characters than a file name.
  storeSafe =
    builtins.replaceStrings
      [
        "@"
        "%"
        "~"
        "!"
        "["
        "]"
        ":"
      ]
      [
        "_"
        "_"
        "_"
        "_"
        "_"
        "_"
        "_"
      ];

  program =
    exe:
    runCommand (storeSafe exe)
      {
        nativeBuildInputs = [ makeWrapper ];
        meta.mainProgram = exe;
      }
      ''
        makeWrapper ${env}/bin/${lib.escapeShellArg exe} "$out/bin/"${lib.escapeShellArg exe} \
          --set CONDA_PREFIX ${env} --prefix PATH : ${env}/bin ${setVariables}
      '';

  package =
    pname: dir:
    stdenvNoCC.mkDerivation (
      scmVersions
      // {
        name = "${pname}-wheel";
        dontUnpack = true;
        buildPhase = ''
          runHook preBuild
          export HOME=$TMPDIR/home
          cp -rL --no-preserve=mode ${lib.escapeShellArg "${src}/${dir}"} "$TMPDIR/source"
          mkdir -p "$out"
          PIP_CONFIG_FILE=/dev/null ${env}/bin/python -m pip wheel --disable-pip-version-check \
            --no-index --no-deps --no-cache-dir --find-links ${dependencies}/pip \
            --wheel-dir "$out" "$TMPDIR/source"
          runHook postBuild
        '';
        dontInstall = true;
        dontFixup = true;
      }
    );
in
{
  inherit env;
  programs = lib.genAttrs locked.programs program;
  packages = lib.mapAttrs package locked.packages;
  shell = mkShell {
    packages = [ env ];
    shellHook = ''
      export CONDA_PREFIX=${env}
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") locked.variables
    );
  };
}
