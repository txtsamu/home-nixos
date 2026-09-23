# home-nixos

Declarative NixOS config for `home` — the Proxmox VM replacing `warp-vm`.

Full context, inventory, and rationale: [warp-vm-nixos-migration-plan.md](https://github.com/txtsamu/claude-research/blob/main/warp-vm-nixos-migration-plan.md) in `txtsamu/claude-research`.
Execution is tracked as tickets T1–T20 there: [txtsamu/claude-research#9–#28](https://github.com/txtsamu/claude-research/issues?q=is%3Aissue+%22T1%3A%22+OR+%22T2%3A%22).

## Layout

- `flake.nix` — inputs: nixpkgs (26.05), disko, agenix. Outputs: `nixosConfigurations.home`, a `checks` entry that evaluates it (what `nix flake check` and CI run), and `formatter`
- `hosts/home/configuration.nix` — base config: static networking + `networking.extraHosts` LAN short names, users/SSH, swap, nix settings (flakes enabled, store auto-optimise, weekly GC); imports every module below
- `hosts/home/keys/admin.pub` — authorized key(s) for `moo` and `root`
- `hosts/home/disko.nix` — declarative disk layout
- `hosts/home/secrets.nix` — agenix wiring: declares `age.secrets.*` pointing at `../../secrets/*.age`
- `secrets/secrets.nix` — agenix recipients manifest (which host key / age key can decrypt which `.age` file); see the comments there for the edit and rekey workflow
- `secrets/*.age` — encrypted secrets, safe to commit
- `hosts/home/{dns,proxy,tunnel,vpn,evomem,mcp,camofox,headroom,tiktok-bot,k3s,checkmk-agent}.nix` — one module per ticket

## Deploying a change

Build from the repo, never from a local checkout on the host (a checkout on the
host silently drifts from `main` and the next repo-based switch reverts it):

```
nixos-rebuild switch --flake github:txtsamu/home-nixos#home --refresh
```

`nix flake check` evaluates the config without touching the running system —
run it before switching. CI (`.github/workflows/ci.yml`) runs the same check on
every push and PR.

## Secrets

Two agenix recipients: `home`'s own SSH host key (normal activation-time
decryption) and an offline age recovery key. Losing the host key therefore does
not lose the secrets, and `agenix -e` works from any machine holding the
recovery key. See [`secrets/secrets.nix`](secrets/secrets.nix).

## Bootstrap

Installed via `nixos-anywhere` onto a throwaway Debian cloud-init VM (same recipe `warp-vm` itself used), which `nixos-anywhere` kexecs into a NixOS installer and reformats via `disko` — no manual ISO/console step.

```
nix run github:nix-community/nixos-anywhere -- --flake .#home root@<temp-ip>
```
