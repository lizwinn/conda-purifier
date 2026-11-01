# SPDX-License-Identifier: MIT
{ ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The `conda-purifier` scope is the `default` entry of the package
    # overlay registry of this flake (pkg-overlays/): the package set
    # applies it by default, and the flake exports it as `pkgOverlays` and
    # as the plain `overlays.default`. The scope holds the builder, which is
    # a function, so the flake exports the command from the scope by hand
    # rather than exporting the whole scope as packages.
    nixpkgs = {
      packages.export.enabled = false;
    };
  };

  # `nix run github:nix-purifiers/conda-purifier -- lock` locks the
  # environment.yml of the current directory. `nix develop
  # github:nix-purifiers/conda-purifier` gives a shell with conda-purifier.
  perSystem =
    { config, pkgs, ... }:
    {
      # The derivations of the scope.
      packages = lib.filterAttrs (_: lib.isDerivation) pkgs.conda-purifier // {
        default = config.packages.conda-purifier;
      };
      devShells.default = pkgs.mkShell {
        packages = [ config.packages.conda-purifier ];
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              overlay = self.overlays.default;
              inherit (self) lib;
              cli = (pkgs.extend self.overlays.default).conda-purifier.conda-purifier;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
