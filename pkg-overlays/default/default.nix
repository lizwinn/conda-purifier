# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.conda-purifier` (the `conda-purifier` command), and the builder
# `pkgs.buildCondaProject` (nix/lib/build-conda-project.nix) beside them,
# where nixpkgs keeps its own builders, so a package written for callPackage
# takes it by name. A consumer that lists this flake in `projects` holds it
# as `conda-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "conda-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildCondaProject = final.callPackage ../../nix/lib/build-conda-project.nix {
        lib = closure-lib;
      };
    };
}
