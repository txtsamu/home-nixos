# T2 (txtsamu/claude-research#10): agenix bootstrap.
#
# Wires the encrypted files under ../../secrets/ (recipients declared in
# ../../secrets/secrets.nix) into the system - agenix decrypts each at
# activation time to /run/agenix/<name> (root:root, mode 0400 by default),
# never into the world-readable Nix store.
#
# One declaration per secret; each names the module that consumes it.
{ ... }:
{
  # T5 (txtsamu/claude-research#13): a real "home"-named tunnel's
  # credentials.json content, consumed by services.cloudflared's native
  # credentialsFile option (tunnel.nix). warp-vm's token-style tunnel
  # could not be reused - two cloudflared instances cannot share one
  # tunnel identity.
  age.secrets.cloudflare-tunnel-credentials = {
    file = ../../secrets/cloudflare-tunnel-credentials.age;
  };

  # T3 (txtsamu/claude-research#11): consumed by dns.nix as an
  # EnvironmentFile (KEY=VALUE format) for technitium-dns-server.
  age.secrets.technitium-admin-password = {
    file = ../../secrets/technitium-admin-password.age;
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
