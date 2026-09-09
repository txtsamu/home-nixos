# agenix recipients manifest (T2, txtsamu/claude-research#10).
#
# Recipients here are SSH host public keys, not personal age keys - agenix
# accepts "ssh-ed25519 AAAA..." directly. That means decrypting or
# re-encrypting (`agenix -e <file>`, `agenix -r` to rekey) requires the
# matching SSH *private* host key, which only ever lives on that host
# (/etc/ssh/ssh_host_ed25519_key on `home`, root-readable only) - so secret
# edits happen as root on `home` itself, e.g.:
#   nix run github:ryantm/agenix -- -e cloudflare-tunnel-token.age -i /etc/ssh/ssh_host_ed25519_key
#
# Captured via `ssh-keyscan -t ed25519 192.168.50.202` against the live host.
let
  home = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICuMl1a2ZkqmctvGNjASFAYSzrSWyDWwxcCBdF51lnXn";
in
{
  "cloudflare-tunnel-credentials.age".publicKeys = [ home ];
  "technitium-admin-password.age".publicKeys = [ home ];
  "netbird-setup-key.age".publicKeys = [ home ];
  "proxmox-mcp-config.age".publicKeys = [ home ];
}
