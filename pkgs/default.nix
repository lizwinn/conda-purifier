# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The command that writes conda-purifier.lock.json and uses the
  # environment Nix builds from it.
  conda-purifier = callPackage ./conda-purifier { };
}
