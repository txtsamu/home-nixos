# T5 (txtsamu/claude-research#13): Cloudflare Tunnel on home.
#
# Real discrepancy found: warp-vm runs a *token*-only remotely-managed
# tunnel (`cloudflared tunnel run --token ...`, no local credentials.json,
# ingress managed via the dashboard). The native services.cloudflared
# module has no token/tokenFile option at all - it only supports the
# credentialsFile + local `ingress` config style (verified against the
# module source, nixos/modules/services/networking/cloudflared.nix).
#
# Rather than hand-roll a unit to keep the token style, used the module as
# designed: created a brand-new tunnel ("home", not a reuse of warp-vm's
# "px1"-named tunnel - see the ticket's resolution comment for why a fresh
# tunnel is required, not just a fresh token) via the Cloudflare API, which
# hands back the same {AccountTag, TunnelSecret, TunnelID} JSON structure
# the module's credentialsFile expects directly - no format conversion
# needed. Local `ingress` config below is a deliberate throwaway route
# (home-t5-test.ssamu.id -> home's own Technitium web UI) proving the
# tunnel works end-to-end without touching any of warp-vm's real public
# hostname routes.
{ config, ... }:
{
  services.cloudflared = {
    enable = true;
    tunnels."83033670-b996-49b7-8174-1032db860685" = {
      credentialsFile = config.age.secrets.cloudflare-tunnel-credentials.path;
      default = "http_status:404";
      ingress = {
        "home-t5-test.ssamu.id" = "http://localhost:5380";
      };
    };
  };
}
