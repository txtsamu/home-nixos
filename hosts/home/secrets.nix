# T2 (txtsamu/claude-research#10): agenix bootstrap.
#
# Wires the encrypted files under ../../secrets/ (recipients declared in
# ../../secrets/secrets.nix) into the system - agenix decrypts each at
# activation time to /run/agenix/<name> (root:root, mode 0400 by default),
# never into the world-readable Nix store.
#
# cloudflare-tunnel-token is the pathfinder secret for this bootstrap: pulled
# fresh from warp-vm's live `cloudflared.service` ExecStart (plan's §2.1 note
# - ~6 real secrets total, ported one at a time as their owning ticket lands).
# Not consumed by any service yet - that's T5 (txtsamu/claude-research#13),
# which will point cloudflared's unit at config.age.secrets.cloudflare-tunnel-token.path
# instead of an inline plaintext token. This ticket only proves the
# encrypt -> commit -> decrypt-on-activation path works end to end.
{ ... }:
{
  age.secrets.cloudflare-tunnel-token = {
    file = ../../secrets/cloudflare-tunnel-token.age;
  };

  # T3 (txtsamu/claude-research#11): consumed by dns.nix as an
  # EnvironmentFile (KEY=VALUE format) for technitium-dns-server.
  age.secrets.technitium-admin-password = {
    file = ../../secrets/technitium-admin-password.age;
  };
}
