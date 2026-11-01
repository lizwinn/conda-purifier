# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.conda-purifier`, made with lib.makeScope from the members
# in pkgs/default.nix. The scope holds the builder
# `pkgs.conda-purifier.buildCondaProject` beside the `conda-purifier`
# command, and `pkgs.conda-purifier.overrideScope` replaces what everything
# in the scope shares. A package written for callPackage takes the scope by
# name. A consumer that lists this flake in `projects` holds the overlay as
# `conda-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "conda-purifier";
}
