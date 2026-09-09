# T11 (txtsamu/claude-research#19): headroom-proxy on home.
#
# headroom-ai==0.36.5 (real PyPI package, exact version match with
# warp-vm) in its own venv - a normal pure-Python-ish install, none of
# the FHS/dynamic-linking problems T9/T10 hit, no secrets needed (no
# API key of its own; it's a transparent proxy that forwards whatever
# credentials the client already sends toward the real Anthropic/OpenAI
# endpoints). State directory (~/.headroom - SQLite context-compression
# cache, savings stats) copied verbatim from warp-vm, same pattern as
# every other stateful service this migration has ported.
{ ... }:
{
  systemd.services.headroom-proxy = {
    description = "Headroom Context Compression Proxy";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      HOME = "/home/moo";
      HEADROOM_HOST = "0.0.0.0";
    };
    serviceConfig = {
      User = "moo";
      ExecStart = "/opt/headroom-proxy/venv/bin/headroom proxy";
      Restart = "on-failure";
    };
  };

  networking.firewall.allowedTCPPorts = [ 8787 ];
}
