# anoa-browser on home: tiktok-bot's primary profile-scrape browser
# (SCRAPE_BROWSER=anoa in tiktok-bot.nix), with camofox (camofox.nix) kept as
# its automatic fallback. Evaluation + test numbers: tiktok-bot-anoa-browser-
# backend-vs-camofox.md in txtsamu/claude-research.
#
# anoa is Qt WebEngine (Chromium 140) driven over CDP/MCP, built from its own
# flake (input `anoa`, pinned to a release tag) - unlike camofox it is a
# proper Nix package, so no steam-run/FHS wrapper is needed.
#
# Ports: 9500 HTTP discovery + /mcp, 9501 Chromium's own DevTools (loopback
# only), 9502 CDP websocket proxy. anoa binds 9500 and 9502 on 0.0.0.0 with no
# option to narrow it, so they are deliberately NOT opened in the firewall -
# only tiktok-bot on this host uses them. The auth token is defense in depth on
# top of that (it does not cover 9501, which is loopback-only anyway).
{ config, anoa, ... }:
{
  systemd.services.anoa-browser = {
    description = "anoa headless browser (CDP/MCP) for tiktok-bot profile scraping";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    environment.HOME = "/var/lib/anoa-browser";
    # The token goes in through a config file rather than --auth-token, which
    # would put it in the world-readable /proc/<pid>/cmdline. printf is a bash
    # builtin, so the token never lands in an argv here either.
    script = ''
      printf '{"authToken":"%s"}' "$ANOA_TOKEN" > "$RUNTIME_DIRECTORY/config.json"
      exec ${anoa}/bin/anoa --headless --port 9500 --ephemeral \
        --config "$RUNTIME_DIRECTORY/config.json"
    '';
    serviceConfig = {
      DynamicUser = true;
      StateDirectory = "anoa-browser";
      CacheDirectory = "anoa-browser";
      RuntimeDirectory = "anoa-browser";
      RuntimeDirectoryMode = "0700";
      EnvironmentFile = config.age.secrets.anoa-auth-token.path;
      # anoa prints the token (and a /setup?token= URL) to stderr on startup.
      LogFilterPatterns = "~token";
      Restart = "on-failure";
      RestartSec = 10;
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
  };
}
