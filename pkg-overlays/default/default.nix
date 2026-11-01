# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.conda-purifier`: the `conda-purifier` command. The builder is in
# the library, as `lib.conda-purifier.buildCondaProject`. A consumer that
# lists this flake in `projects` holds the overlay as
# `conda-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "conda-purifier";
}
