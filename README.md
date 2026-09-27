# home-nixos

Declarative NixOS config for `home` — the Proxmox VM replacing `warp-vm`.

Full context, inventory, and rationale: [warp-vm-nixos-migration-plan.md](https://github.com/txtsamu/claude-research/blob/main/warp-vm-nixos-migration-plan.md) in `txtsamu/claude-research`.
Execution is tracked as tickets T1–T20 there: [txtsamu/claude-research#9–#28](https://github.com/txtsamu/claude-research/issues?q=is%3Aissue+%22T1%3A%22+OR+%22T2%3A%22).

## Layout

- `flake.nix` — inputs: nixpkgs (26.05), disko, agenix
- `hosts/home/configuration.nix` — base config; imports every module below
- `hosts/home/disko.nix` — declarative disk layout
- `hosts/home/secrets.nix` — agenix wiring (T2, done): declares `age.secrets.*` pointing at `../../secrets/*.age`
- `secrets/secrets.nix` — agenix recipients manifest (which SSH host key(s) can decrypt which `.age` file); see comments there for the edit workflow
- `secrets/*.age` — encrypted secrets, safe to commit
- `hosts/home/{dns,proxy,tunnel,vpn,evomem,mcp,camofox,headroom,tiktok-bot,k3s,checkmk-agent}.nix` — one module per service
- `hosts/home/provision.nix` — oneshots that recreate the out-of-store app artifacts: source checkouts (`provision-src-*`, clone + `patches/` when missing) and uv venvs on Nix python (`provision-venv-*`, rebuilt from `venvs/*.txt` / the on-host freeze snapshot when missing or when nixpkgs moves python)
- `.github/workflows/` — CI (`nix flake check` + system instantiation) and a weekly `flake.lock` update PR

## Deploying

`home` deploys from a read-only clone of this repo at `~moo/home-nixos`. Edit elsewhere, push, then:

```
cd ~/home-nixos && git pull && sudo nixos-rebuild switch --flake .#home
```

`nixos-rebuild list-generations` shows the deployed commit under *Configuration Revision*. Format with `nix fmt` before committing (CI checks it).

## Bootstrap

Installed via `nixos-anywhere` onto a throwaway Debian cloud-init VM (same recipe `warp-vm` itself used), which `nixos-anywhere` kexecs into a NixOS installer and reformats via `disko` — no manual ISO/console step.

```
nix run github:nix-community/nixos-anywhere -- --flake .#home root@<temp-ip>
```
