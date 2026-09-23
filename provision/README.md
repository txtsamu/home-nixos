# Out-of-band provisioning (what the flake does *not* build)

The units in `hosts/home/` are declared here, but several of the things they run
are **not**: venvs, binaries and data directories that were provisioned by hand
when their ticket landed. Nothing in `nixos-rebuild` recreates them, and no GC
root protects them - `description =` in a unit only says *where* to find an
artifact, not that it exists.

This file exists so that is a known, written-down gap instead of a surprise
during a rebuild. Recipes below were read off the live host (`pyvenv.cfg` and the
ticket write-ups in `txtsamu/claude-research`), not reconstructed from memory.

## What lives where

| path | what | how it was made |
|---|---|---|
| `/opt/hermes-venv` | hermes gateway + mcp deps (131 pkgs) | `uv venv` (uv 0.11.21) over nixpkgs `python3-3.13.15` |
| `/opt/hermes-source` | rsync'd hermes checkout, node_modules included; has its own `venv/` managed by `hermes update` | copied from warp-vm |
| `/opt/proxmox-venv` | proxmox-mcp-plus (54 pkgs, no pip inside - uv-managed) | `uv venv` + `uv pip install`, same python3.13.15 |
| `/opt/headroom-proxy/venv` | `headroom-ai[proxy]==0.36.5` (92 pkgs) | plain `python3.13 -m venv` + pip |
| `/opt/tiktok-bot` | `git clone` of the private `txtsamu/tiktok-bot`, plus gitignored runtime state (`watchdb.sqlite3`, cookies, `ig_sessions/`) | cloned + patched on the host (3 `HERMES_PIP_BIN`/`GALLERY_DL_BIN`/`YTDLP_BIN` paths repointed) |
| `/opt/tiktok-bot-venv` | tiktok-bot deps (63 pkgs), separate from hermes' venv on purpose (f2 wants `websockets<13`) | `python3.13 -m venv` + pip |
| `/usr/local/bin/evomem` | stripped static build of the evomem binary | copied from warp-vm's running copy, **no source in any repo** |
| `/root/camofox-browser` | camofox server + `node_modules` | copied from warp-vm |
| `/root/.cache/camoufox` | the Camoufox (Firefox fork) binary, ~1.2G | downloaded, copied verbatim |
| `/var/lib/netbird`, `/root/evomem-kb` | service state; evomem-kb is an iSCSI LUN from TrueNAS | see `evomem.nix` |

## Recreating the Python venvs

`provision/frozen/*.txt` are `pip freeze` snapshots taken from the live venvs
(2026-09-24). They are the closest thing to a recipe that exists:

```bash
# uv-created venvs (hermes, proxmox) - nixpkgs python3.13 + uv:
uv venv --python 3.13 /opt/hermes-venv
uv pip install --python /opt/hermes-venv/bin/python -r provision/frozen/hermes-venv.txt

# venv-created ones (headroom, tiktok-bot):
python3.13 -m venv /opt/headroom-proxy/venv
/opt/headroom-proxy/venv/bin/pip install -r provision/frozen/headroom-proxy-venv.txt
```

Two caveats that matter: `tiktok-bot-venv` installs `instagrapi` from a git URL
(its PyPI sdist is broken), which the freeze records; and the tiktok-bot
`tiktok_bot.py` on the host has three hardcoded `/opt/hermes-venv` paths patched
to `/opt/tiktok-bot-venv` - a host-only edit that is *not* in the upstream repo.

`/opt/hermes-source` is refreshed by `hermes update` itself (which is why the
ticket enabling `programs.nix-ld` matters); its inner `venv/` is that updater's
own, not something to rebuild by hand.

## Known gap

`/usr/local/bin/evomem` is a binary with no source in a repo. If this VM is
rebuilt from scratch, evomem is the one service that cannot be restored from the
flake plus these freezes. Getting its source (or at least a tagged build) into a
repo is the outstanding follow-up.
