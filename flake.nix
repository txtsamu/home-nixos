{
  description = "NixOS flake config for `home` - replaces warp-vm, see the migration plan in txtsamu/claude-research";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      agenix,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      home = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          disko.nixosModules.disko
          agenix.nixosModules.default
          ./hosts/home/configuration.nix
          ./hosts/home/disko.nix
        ];
      };
    in
    {
      nixosConfigurations.home = home;

      # `nix flake check` (run in CI on every push/PR) evaluates this, so a
      # module that stops evaluating - bad option name, typo'd import, unfree
      # package without a declared predicate - fails there instead of at
      # switch time on the live host.
      #
      # builtins.seq, *not* string interpolation: interpolating the drv path
      # would make it a build input of this derivation, and a store path that
      # was only computed, never realised, is not valid - which is exactly how
      # the first CI run failed ('path ...-nixos-system-home-....drv is not
      # valid'). seq forces the path string to be evaluated (i.e. the whole
      # system config) while keeping it out of the closure.
      checks.${system}.config-evaluates =
        builtins.seq home.config.system.build.toplevel.drvPath
          (pkgs.runCommand "home-config-evaluates" { } ''
            echo ok > $out
          '');

      # `nix fmt` - nixfmt is the official RFC 166 formatter (the same one
      # nixpkgs uses). Note `nix flake check` *builds* every formatter output it
      # finds, and that pulls in a GHC toolchain, so CI runs
      # `nix flake check --no-build` and only evaluates it there.
      formatter.${system} = pkgs.nixfmt;
    };
}
