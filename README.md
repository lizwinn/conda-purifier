# conda-purifier

conda-purifier builds conda environments with Nix, in the Nix sandbox and
offline, without generated Nix files in your repository. It is one of the
[nix-purifiers](https://nix-purifiers.github.io), which share a
[contract](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md)
for their builders, commands, checks and READMEs.

## Quickstart

`conda-purifier lock` solves your `environment.yml` and writes
`conda-purifier.lock.json` beside it. Commit that file.

```console
$ nix run github:nix-purifiers/conda-purifier -- lock
conda-purifier: solving environment.yml for linux-64
conda-purifier: solving environment.yml for linux-aarch64
...
conda-purifier: wrote conda-purifier.lock.json (linux-64: 35 conda, 6 pip, linux-aarch64: 35 conda, 6 pip)
```

Your flake builds the environment from that lockfile with
`lib.conda-purifier.buildCondaProject`:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.conda-purifier.url = "github:nix-purifiers/conda-purifier";

  outputs =
    { nixpkgs, conda-purifier, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      project = conda-purifier.lib.conda-purifier.buildCondaProject {
        inherit pkgs;
        src = ./.;
      };
    in
    {
      packages.x86_64-linux = project.packages;
      checks.x86_64-linux.tests = project.tests;
      devShells.x86_64-linux.default = project.shell;
    };
}
```

The flake's `lib` has the shared
[purifier](https://github.com/nix-purifiers/purifier) library under
`lib.purifier`, which the builder uses. If your flake composes its own
library, add `conda-purifier.lib` to it.

`buildCondaProject` returns these attributes:

| Attribute | What it is |
|---|---|
| `packages.environment` | The environment, with the conda packages and the `pip:` section installed. |
| `packages.<program>` | Each executable in the `bin/` directory of the environment, wrapped so that it runs with the variables of the environment. The lockfile lists the programs of each platform. |
| `tests` | The project's test command, run in the sandbox with the environment active. The default is `python -m pytest` when the environment has pytest. The `testCommand` argument replaces it. |
| `release` | A directory with the wheel of each of the project's own Python packages. `conda-purifier publish` uploads it. |
| `fetches` | The entries of the purifier library that the build downloads, for SBOM, license and vulnerability tools. |
| `shell` | A development shell with the environment active. |

Its other arguments are `lockFile`, `name` (the default is the `name` in
`environment.yml`), `runLinkScripts`, `testCommand`, `environmentYml` and
`condaLockYml` (for sources that are not in `src`), and `fetchers`.

`lib.conda-purifier.readLock { src; lockFile; }` reads the lockfiles into
the shape every purifier shares: `{ purifier; entries; outputs; problems; }`.
Each entry carries the Nix `systems` that need it.

## Everyday loop

Work in the environment that `conda-purifier prefetch` builds:

```console
$ conda-purifier prefetch
conda-purifier: the environment is /nix/store/...-hello-conda
conda-purifier: activate it with `conda activate ./.conda-purifier/env`; editors take ./.conda-purifier/env/bin/python
$ conda activate ./.conda-purifier/env
$ python -m pytest
```

`.conda-purifier/` belongs in `.gitignore`. Activation sets `CONDA_PREFIX`,
`PATH` and the `variables:` of `environment.yml`. The environment is
read-only: `pip install` stops and says what to do instead.

To add a package, put it in `environment.yml` and run
`conda-purifier lock`. The lock run keeps the version of every package
that the file does not name, in the conda section and in the `pip:`
section, so adding one package does not move the others. The next
`prefetch` builds the new environment.

To move packages, run `conda-purifier update`. It solves the whole
environment again, or only the packages you name:

```console
$ conda-purifier update numpy pandas
```

With a `conda-lock.yml`, `update` runs the update of conda-lock on it first
and then relocks. Explicit spec files have no resolver, so `update` refuses
them.

`conda-purifier publish` builds `release` with Nix and uploads the wheels
with `uv publish`. Arguments after `--` go to `uv publish`:

```console
$ conda-purifier publish -- --publish-url https://test.pypi.org/legacy/ --token "$TOKEN"
```

A package of the project that setuptools-scm or hatch-vcs versions gets
the version that pip saw in the lock run, since the sandbox has no `.git`.

### Keeping the lockfile outside the project

A packaging flake can build a project whose author does not change it.
Pass `lockFile` to `buildCondaProject`; it replaces any lockfile in
`src`. Every command takes `--lockfile <path>`, or reads
`CONDA_PURIFIER_LOCKFILE`, which a development shell can set to the same
path. The GC roots then go in `.conda-purifier/` beside the lockfile.

## Offline work

`conda-purifier prefetch` builds the environment and every locked download
for the current system, and keeps them alive with GC roots:
`.conda-purifier/env` and `.conda-purifier/downloads`. After a prefetch,
the everyday loop works with the network cut off, including a rebuild
after a change to the project's own packages, since the downloads are
already in the Nix store.

The check `conformance-offline` runs the loop of a fixture in the sandbox,
which has no network.

### Private channels

A private channel puts its access token in the URL (`/t/<token>/`). The
lockfile records the URL without the token, so the token stays out of your
repository. The build fetches files with the `fetchers.fetchurl` that you
pass to `buildCondaProject`, which for a private channel has to bring
credentials of its own, such as nixpkgs' `fetchurl` with a `netrcPhase`.

## Editor

Point the editor at `.conda-purifier/env/bin/python`, the way you would
point it at a conda environment. In VS Code, run "Python: Select
Interpreter". For pyright, pass
`--pythonpath .conda-purifier/env/bin/python`. Run
`conda-purifier prefetch` first, so that the interpreter exists.

## Errors and fixes

Each of these stops with a message that names the command to run, in the
commands and at Nix evaluation:

| What happened | What conda-purifier says |
|---|---|
| The environment file changed after the lock | `environment.yml changed after conda-purifier.lock.json was written; run conda-purifier lock again` |
| The lockfile was edited by hand | `conda-purifier.lock.json was changed after conda-purifier wrote it; run conda-purifier lock to write it again` |
| The lockfile is not valid JSON | `conda-purifier.lock.json is not a lockfile conda-purifier wrote; run conda-purifier lock to write it again` |
| The lockfile lacks the hash of a file | `conda-purifier.lock.json has no SHA-256 for <url>; run conda-purifier lock to write it again` |
| The lockfile has an older format | `conda-purifier.lock.json is format 1; this conda-purifier reads format 2. Run conda-purifier lock to write it again` |
| A platform is missing from the lock | `conda-purifier.lock.json has no packages for linux-aarch64; run conda-purifier lock --platform linux-aarch64 together with the other platforms` |
| A kept version conflicts with a change | `The environment file conflicts with the versions the lock keeps; run conda-purifier update with the packages to move` |
| `pip install` inside the environment | `This environment is built by conda-purifier ... Add the package to the environment file ..., then run conda-purifier lock` |

## Sources supported and refused

conda-purifier reads one of three inputs, found in this order:

- **`conda-lock.yml`**, as [conda-lock](https://github.com/conda/conda-lock)
  writes it (format 1). It already records every package and hash, so the
  lockfile copies none of them: Nix reads the packages from `conda-lock.yml`.
- **`environment.yml`**. conda-purifier solves it with micromamba for each
  platform, as conda would, and resolves its `pip:` section with the
  environment's own pip.
- **Explicit spec files**, as `conda list --explicit` writes them, one per
  platform, passed with `--file`. Nix reads the packages from these files.

For `conda-lock.yml` and explicit spec files, the lockfile adds only what
those files lack: the SHA-256 of a file listed with an MD5 hash only, and
the programs of each platform. For an `environment.yml`, the lockfile
records the solve, which nothing else records: the URL and hash of each
conda package and of each `pip:` download, the revision of each checkout,
the version and directory of each of the project's own packages, and the
build requirements of the `pip:` section. Nix derives the name, version and
path of every download from the URL.

The `pip:` section of an `environment.yml` may hold any requirement pip
accepts:

- packages from PyPI or another index (`--index-url` and
  `--extra-index-url` lines apply);
- wheels, and sdists, whose build requirements are locked as wheels;
- git, Mercurial, Subversion and Bazaar requirements, pinned to the
  revision pip resolves;
- the project's own packages, as directories inside the project;
- `-r` requirement files, which become inputs of the lock.

pip installs only what the conda packages do not already provide. By
default the lock covers `linux-64` and `linux-aarch64`, and `--platform`
names others. A package with a wheel per platform gets the wheel of each
platform; when a platform has no wheel, its lock holds the sdist of the
package and the build requirements of the sdist.

The lock run uses its own micromamba root and package cache, and ignores
your `.condarc` and `CONDA_*` settings, so two machines produce the same
lock from the same inputs. It installs the `pip:` section offline from the
recorded files before it writes the lockfile.

conda-purifier refuses these:

- A `conda-lock.yml` of another format than 1, or one that is not laid out
  as conda-lock writes it. Nix reads that file line by line, and the lock
  run compares the result with what a YAML parser reads.
- A build requirement of the `pip:` section with no wheel for a platform.
  The error names the requirement.
- macOS for the `pip:` section. conda-purifier locks `osx-64` and
  `osx-arm64` conda packages, but it resolves the `pip:` section for Linux
  platforms only, and the macOS build is untested.
- The pre-link scripts of conda packages. The build runs post-link scripts
  only.

## Real-world projects

- [geopandas](https://github.com/geopandas/geopandas) at `ead9a4fe`, its
  `environment-dev.yml`: 309 conda packages on linux-64 (pandas, pyarrow,
  scipy, matplotlib, and the GDAL, GEOS and PROJ stack). The lock run takes
  about a minute. The lockfile sits outside the geopandas source, in
  `tests/real/geopandas/`, which is the external form of the contract.
  CI builds the environment on x86_64-linux and aarch64-linux and runs the
  geopandas tests of its geometry methods and coordinate reference systems
  in it, offline. Adding `pip` and `-e .` to `environment-dev.yml` installs
  geopandas from the checkout, and the build gives hatch-vcs the version
  that the lock run saw. Raising the `ruff` pin and relocking gives the new
  ruff. With the environment, pyright leaves one import of geopandas
  unresolved, `sqlalchemy.text`, which names a function rather than a
  module; without it, pyright leaves 30.

## Credits

The purifier idea was inspired by the
[cargo (libnix)](https://github.com/nixcloud/cargo) project of nixcloud.
conda-purifier uses [micromamba](https://github.com/mamba-org/mamba) to
solve and install, and [uv](https://github.com/astral-sh/uv) to publish.
It is MIT licensed.
