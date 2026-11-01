# conda-purifier

conda-purifier builds conda environments with Nix, in the Nix sandbox and
offline, without generated Nix files in your repository.

`conda-purifier lock` writes `conda-purifier.lock.json` beside your
`environment.yml`. The lockfile records every file the environment needs,
for each platform: the conda packages, and the packages of the
environment's `pip:` section together with what building them needs. It
also records what the environment produces: its programs, and the wheels
of your own Python packages. `buildCondaProject` reads the lockfile at
evaluation time and builds the environment from it.

## What it locks

conda-purifier reads one of three inputs, found in this order:

- **`conda-lock.yml`**, as [conda-lock](https://github.com/conda/conda-lock)
  writes it (format 1). conda-purifier reuses its packages and hashes.
- **`environment.yml`**. conda-purifier solves it with micromamba for each
  platform, as conda would, and resolves its `pip:` section with the
  environment's own pip.
- **Explicit spec files**, as `conda list --explicit` writes them, one per
  platform, passed with `--file`. Files listed with an MD5 hash only are
  downloaded once to record their SHA-256.

The `pip:` section of an `environment.yml` may hold any requirement pip
accepts:

- packages from PyPI or another index (`--index-url` and
  `--extra-index-url` lines apply);
- wheels, and sdists, whose build requirements are locked as wheels;
- git, Mercurial, Subversion and Bazaar requirements, pinned to the
  revision pip resolves;
- the project's own packages, as directories inside the project;
- `-r` requirement files, which become inputs of the lock.

pip installs only what the conda packages do not already provide.

By default the lock covers `linux-64` and `linux-aarch64`. `--platform`
names others. A package with a wheel per platform gets the wheel of each
platform; when a platform has no wheel, its lock holds the package's sdist
and the sdist's build requirements.

```console
$ nix run github:nix-purifiers/conda-purifier -- lock
conda-purifier: solving environment.yml for linux-64
conda-purifier: solving environment.yml for linux-aarch64
...
conda-purifier: wrote conda-purifier.lock.json (linux-64: 35 conda, 6 pip, linux-aarch64: 35 conda, 6 pip)
```

The lock run uses its own micromamba root and package cache, and ignores
your `.condarc` and `CONDA_*` settings, so two machines produce the same
lock from the same inputs. It installs the `pip:` section offline from the
recorded files before it writes the lockfile.

Commit `conda-purifier.lock.json`. When `environment.yml`, a requirement
file it includes, `conda-lock.yml` or the explicit spec files change, the
build refuses the lock until `conda-purifier lock` runs again.

## Building with Nix

The flake's `overlays.default` adds `buildCondaProject` to a package set:

```nix
{
  inputs.conda-purifier.url = "github:nix-purifiers/conda-purifier";

  outputs =
    { nixpkgs, conda-purifier, ... }:
    let
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        overlays = [ conda-purifier.overlays.default ];
      };
      project = pkgs.buildCondaProject { src = ./.; };
    in
    {
      packages.x86_64-linux = {
        default = project.programs.hello-conda;
        env = project.env;
      };
      devShells.x86_64-linux.default = project.shell;
    };
}
```

`buildCondaProject { src; }` returns every output the lockfile names:

| Attribute | What it is |
|---|---|
| `env` | The environment, with conda's packages and the `pip:` section installed. |
| `programs.<name>` | Each executable in the `bin/` directory of the environment, wrapped so that it runs with the variables of the environment. The lockfile lists the programs of each platform. |
| `packages.<name>` | The wheel of each of the project's own Python packages. |
| `shell` | A development shell with the environment active. |

Its other arguments are `lockFile`, `name` (the default is the `name` in
`environment.yml`), `runLinkScripts` and `fetchurl`.

conda's binaries ask for the dynamic linker at `/lib64`, which NixOS and
the Nix sandbox do not have. The build points every ELF file of the
environment at the dynamic linker of the package set. The libraries stay
conda's own. After that it runs the packages' post-link scripts, installs
the `pip:` section with pip from the locked files, and records the
`variables:` of `environment.yml` for `conda activate`.

### Private channels

A private channel puts its access token in the URL (`/t/<token>/`). The
lockfile records the URL without the token, so the token stays out of your
repository. The build fetches files with the `fetchurl` you pass to
`buildCondaProject`, which for a private channel has to bring credentials
of its own, such as nixpkgs' `fetchurl` with a `netrcPhase`.

## Using the environment interactively

`conda-purifier env` builds the same environment through Nix and prints its
path. It keeps the environment alive with a GC root at
`.conda-purifier/env`, which belongs in `.gitignore`. `conda-purifier run --
<command>` runs a command in the environment, and `conda-purifier shell`
starts your shell in it. Both set `CONDA_PREFIX`, `PATH` and the
`variables:` of `environment.yml`.

```console
$ conda-purifier run -- hello-conda 41
hello from conda: n+1=42 inverse-sum=1.5 six=1.17.0 numpy=2
```

The environment is read-only. Your own packages are installed as they were
at the last build, and the next `run` builds in any change to them.

## Publishing

`conda-purifier publish` builds the wheels of the project's own packages
with Nix and uploads them with `uv publish`. Arguments after `--` go to
`uv publish`:

```console
$ conda-purifier publish -- --publish-url https://test.pypi.org/legacy/ --token "$TOKEN"
```

## Limits

- conda-purifier runs and is tested on Linux. It can lock `osx-64` and
  `osx-arm64` for conda packages, but it resolves the `pip:` section for
  Linux platforms only, and the macOS build is untested.
- Build requirements of the `pip:` section are installed as wheels, as pip
  does with `--only-binary`. A build requirement with no wheel for a
  platform stops the lock and names the requirement.
- The build runs post-link scripts of conda packages and not their
  pre-link scripts.

## Credit

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo). conda-purifier is one
of the [nix-purifiers](https://nix-purifiers.github.io).

## License

MIT
