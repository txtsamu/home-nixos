{
  description = "NixOS flake config for `home` - replaces warp-vm, see the migration plan in txtsamu/claude-research";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    # tiktok-bot's scrape browser (hosts/home/anoa.nix). Not following our
    # nixpkgs: its Qt WebEngine build is tested against its own pin.
    anoa.url = "github:porcupine-md/anoa-browser/v0.19.1";
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      agenix,
      anoa,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosConfigurations.home = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs.anoa = anoa.packages.${system}.default;
        modules = [
          disko.nixosModules.disko
          agenix.nixosModules.default
          # Shows up as "Configuration Revision" in `nixos-rebuild
          # list-generations` - ties each generation to a commit.
          { system.configurationRevision = self.rev or self.dirtyRev or null; }
          ./hosts/home/configuration.nix
          ./hosts/home/disko.nix
        ];
      };

      formatter.${system} = pkgs.nixfmt-tree;

      # `nix flake check` - format check (and full eval). CI additionally
      # builds the whole system closure.
      checks.${system}.formatting =
        pkgs.runCommand "check-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; }
          ''
            cd ${self}
            find . -name '*.nix' -print0 | xargs -0 nixfmt --check
            touch $out
          '';
    };
}
