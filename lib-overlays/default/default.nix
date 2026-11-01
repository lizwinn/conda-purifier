# SPDX-License-Identifier: MIT
#
# The `conda-purifier` library namespace. It holds the builder,
# `lib.conda-purifier.buildCondaProject`, which takes the package set as
# its `pkgs` argument (nix/lib/build-conda-project.nix), and
# `lib.conda-purifier.readLock`, which reads a project's lockfiles into the
# lock in memory of the purifier contract (nix/lib/lock.nix). The library
# it is built over has the shared purifier library under `lib.purifier`.
{ ... }:
{

  overlay = final: prev: {
    conda-purifier = {
      buildCondaProject = import ../../nix/lib/build-conda-project.nix { lib = final; };
      readLock = import ../../nix/lib/lock.nix { lib = final; };
    };
  };

}
