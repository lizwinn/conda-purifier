# SPDX-License-Identifier: MIT
{ closure-lib, ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [
    inputs.flake-parts.flakeModules.partitions
    # Publishes the derivations of the scope as the packages output.
    closure-lib.caisson.modules.flake."purifier/purifier-packages"
  ];

  debug = false;
  purifier.scope = "conda-purifier";

  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };
  };

  # `nix run github:nix-purifiers/conda-purifier -- lock` locks the
  # environment.yml of the current directory. `nix develop
  # github:nix-purifiers/conda-purifier` gives a shell with conda-purifier.
  perSystem =
    { config, pkgs, ... }:
    {
      packages.default = config.packages.conda-purifier;
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
