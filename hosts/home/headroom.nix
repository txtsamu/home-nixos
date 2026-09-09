# T11 (txtsamu/claude-research#19): headroom-proxy on home.
#
# headroom-ai==0.36.5 (real PyPI package, exact version match with
# warp-vm) in its own venv - no secrets needed (no API key of its own;
# it's a transparent proxy that forwards whatever credentials the client
# already sends toward the real Anthropic/OpenAI endpoints). State
# directory (~/.headroom - SQLite context-compression cache, savings
# stats) copied verbatim from warp-vm, same pattern as every other
# stateful service this migration has ported.
#
# Real bug #1 hit standing this up: the bare `headroom-ai` PyPI package
# has no HTTP server at all - `headroom proxy` needs the `[proxy]` extra
# (fastapi/uvicorn/mcp/onnxruntime/...) which the initial venv install
# skipped. Fixed by installing `headroom-ai[proxy]==0.36.5` instead
# (still an exact version match with warp-vm).
#
# Real bug #2, same class as T9's camofox/steam-run issue but a lighter
# case of it: with the [proxy] extra installed, the service still failed
# - "libstdc++.so.6: cannot open shared object file" - because
# onnxruntime/magika's compiled extensions are prebuilt wheels expecting
# libstdc++ at a standard FHS path, which NixOS doesn't provide globally.
# This isn't a whole dynamically-linked foreign *binary* (unlike
# camofox's headless-browser downloads), just one missing shared lib for
# an otherwise nix-provided Python interpreter, so the fix is narrower
# than steam-run: point LD_LIBRARY_PATH at nixpkgs' own
# stdenv.cc.cc.lib.
{ pkgs, ... }:
{
  systemd.services.headroom-proxy = {
    description = "Headroom Context Compression Proxy";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      HOME = "/home/moo";
      HEADROOM_HOST = "0.0.0.0";
      LD_LIBRARY_PATH = "${pkgs.stdenv.cc.cc.lib}/lib";
    };
    serviceConfig = {
      User = "moo";
      ExecStart = "/opt/headroom-proxy/venv/bin/headroom proxy";
      Restart = "on-failure";
    };
  };

  networking.firewall.allowedTCPPorts = [ 8787 ];
}
