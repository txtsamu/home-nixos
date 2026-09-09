# home-nixos

Declarative NixOS config for `home` — the Proxmox VM replacing `warp-vm`.

Full context, inventory, and rationale: [warp-vm-nixos-migration-plan.md](https://github.com/txtsamu/claude-research/blob/main/warp-vm-nixos-migration-plan.md) in `txtsamu/claude-research`.
Execution is tracked as tickets T1–T20 there: [txtsamu/claude-research#9–#28](https://github.com/txtsamu/claude-research/issues?q=is%3Aissue+%22T1%3A%22+OR+%22T2%3A%22).

## Layout

- `flake.nix` — inputs: nixpkgs (26.05), disko, agenix
- `hosts/home/configuration.nix` — base config; imports every module below
- `hosts/home/disko.nix` — declarative disk layout
- `hosts/home/{secrets,dns,proxy,tunnel,vpn,evomem,mcp,tiktok-bot,k3s}.nix` — one module per remaining ticket, stubs until that ticket lands

## Bootstrap

Installed via `nixos-anywhere` onto a throwaway Debian cloud-init VM (same recipe `warp-vm` itself used), which `nixos-anywhere` kexecs into a NixOS installer and reformats via `disko` — no manual ISO/console step.

```
nix run github:nix-community/nixos-anywhere -- --flake .#home root@<temp-ip>
```
