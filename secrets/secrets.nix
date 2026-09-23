# agenix recipients manifest (T2, txtsamu/claude-research#10).
#
# Recipients are *public* keys - agenix accepts "ssh-ed25519 AAAA..." and
# "age1..." directly. Whoever holds a matching private key can decrypt, so the
# rule is one recipient per place that must be able to read the secrets:
#
#   home     - the host's own SSH host key (captured from the live host with
#              `ssh-keyscan -t ed25519 192.168.50.200`; re-verify it against
#              `ssh-keygen -y -f /etc/ssh/ssh_host_ed25519_key` after any
#              reinstall). Private half only ever lives on `home`.
#   recovery - a standalone age identity, deliberately held OFF the host
#              (password manager / laptop). This is the break-glass recipient:
#              if the host key is lost or the VM is rebuilt, the secrets are
#              still recoverable - and it is also what makes `agenix -e`
#              possible from a machine that is not `home`.
#
# Editing a secret (from a machine holding one of those private keys):
#   nix run github:ryantm/agenix -- -e cloudflare-tunnel-credentials.age -i <identity>
#
# Rekeying after this list changes (run as root on `home`, then commit):
#   nix run github:ryantm/agenix -- -r -i /etc/ssh/ssh_host_ed25519_key
let
  home = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICuMl1a2ZkqmctvGNjASFAYSzrSWyDWwxcCBdF51lnXn";
  recovery = "age1ttah86f7zxkfyeuvtsyys48vu5dg58nk3d3v5ycku534uu73kgdq6ekm3v";
  all = [ home recovery ];
in
{
  "cloudflare-tunnel-credentials.age".publicKeys = all;
  "technitium-admin-password.age".publicKeys = all;
  "netbird-setup-key.age".publicKeys = all;
  "proxmox-mcp-config.age".publicKeys = all;
  "camofox-api-key.age".publicKeys = all;
}
