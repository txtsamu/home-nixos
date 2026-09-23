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
      # switch time on the live host. drvPath is a plain string: evaluating
      # the config is the check, nothing is built.
      checks.${system}.config-evaluates = pkgs.runCommand "home-config-evaluates" { } ''
        echo "${home.config.system.build.toplevel.drvPath}" > $out
      '';

      # `nix fmt` - nixfmt is the official RFC 166 formatter (the same one
      # nixpkgs uses). Note `nix flake check` *builds* every formatter output it
      # finds, and that pulls in a GHC toolchain, so CI runs
      # `nix flake check --no-build` and only evaluates it there.
      formatter.${system} = pkgs.nixfmt;
    };
}
