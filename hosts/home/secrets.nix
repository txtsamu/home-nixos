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
  # T5 (txtsamu/claude-research#13) superseded this: warp-vm's token was
  # never actually usable (Cloudflare Tunnel needs a *fresh* tunnel bound to
  # `home`, not a shared token - two cloudflared instances can't run the
  # same tunnel identity). Replaced by cloudflare-tunnel-credentials below,
  # a real "home"-named tunnel's credentials.json content, consumed by
  # services.cloudflared's native credentialsFile option (tunnel.nix).
  age.secrets.cloudflare-tunnel-credentials = {
    file = ../../secrets/cloudflare-tunnel-credentials.age;
  };

  # T3 (txtsamu/claude-research#11): consumed by dns.nix as an
  # EnvironmentFile (KEY=VALUE format) for technitium-dns-server.
  age.secrets.technitium-admin-password = {
    file = ../../secrets/technitium-admin-password.age;
  };

  # T6 (txtsamu/claude-research#14): consumed by vpn.nix's netbird-up
  # oneshot via --setup-key-file. Single machine-scoped setup key created
  # by the user directly in the self-hosted NetBird dashboard
  # (vpn.ssamu.id) - not reused from warp-vm, which has its own peer
  # identity that stays as-is until T19/T20.
  age.secrets.netbird-setup-key = {
    file = ../../secrets/netbird-setup-key.age;
  };

  # T8 (txtsamu/claude-research#16): full proxmox-mcp-plus config.json
  # (contains the Proxmox API token). Encrypted as a whole - cleanest, and
  # keeps the token out of plaintext on disk. Materialized at
  # /run/agenix/proxmox-mcp-config and consumed by mcp.nix as
  # PROXMOX_MCP_CONFIG. Recreated from warp-vm's live
  # /etc/proxmoxmcp/config.json verbatim (host 192.168.50.30:8006,
  # service PVE, token MCPPlus) - see mcp.nix for the unit.
  age.secrets.proxmox-mcp-config = {
    file = ../../secrets/proxmox-mcp-config.age;
  };

  # T9 (txtsamu/claude-research#17): consumed by camofox.nix as an
  # EnvironmentFile (KEY=VALUE format, same pattern as T3's
  # technitium-admin-password) for camofox-browser's CAMOFOX_API_KEY.
  age.secrets.camofox-api-key = {
    file = ../../secrets/camofox-api-key.age;
  };
}
