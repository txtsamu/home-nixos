{
  description = "NixOS flake config for `home` - replaces warp-vm, see the migration plan in txtsamu/claude-research";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, disko, agenix, ... }: {
    nixosConfigurations.home = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        agenix.nixosModules.default
        ./hosts/home/configuration.nix
        ./hosts/home/disko.nix
      ];
    };
  };
}
