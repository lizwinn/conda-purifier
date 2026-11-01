# SPDX-License-Identifier: MIT
#
# What `conda-purifier env`, `run`, `shell` and `publish` build for a
# project: the same buildCondaProject a sandboxed build uses, from the
# project directory as it is on disk. The command evaluates this file with
# the nixpkgs it was built with and the project's absolute path, and keeps
# the result alive with a GC root under .conda-purifier/.
{
  nixpkgs,
  projectDir,
}:
let
  pkgs = import nixpkgs { };
  inherit (pkgs) lib;
  # The project without what is not its source: its version control, the
  # links conda-purifier and nix-build leave in it.
  src = builtins.path {
    path = projectDir;
    name = "source";
    filter =
      path: type:
      let
        base = baseNameOf path;
      in
      !(base == ".git" || base == ".conda-purifier" || lib.hasPrefix "result" base);
  };
in
pkgs.callPackage ./build-conda-project.nix { } { inherit src; }
