# T9 (txtsamu/claude-research#17): camofox-browser on home.
#
# Node.js server (source + node_modules copied verbatim from warp-vm's
# /root/camofox-browser, same "artifacts live outside the Nix store"
# pattern as evomem/hermes) wrapping Camoufox, a stealth Firefox fork
# (the actual downloaded browser binary, /root/.cache/camoufox, also
# copied verbatim - 1.2G, not something to re-fetch and risk a different
# build).
#
# Real NixOS problem specific to this ticket: the Camoufox binary (and
# any native .node addons in the copied node_modules - playwright-core
# bundles its own) is a normal dynamically-linked ELF built for a
# standard FHS Linux layout (/lib, /usr/lib, standard ld.so paths), which
# doesn't exist on NixOS. This is the same class of issue as T8's
# "warp-vm's node won't run on NixOS" - but here it's not just one binary,
# it's an entire Firefox-derived browser plus whatever native addons ship
# inside node_modules. Wrapping the *whole* ExecStart (not just spawned
# child processes) in pkgs.steam-run gives the entire process tree a
# proper FHS-compatible environment via a bind-mounted overlay, so both
# the Node native addons and the browser subprocess Node spawns get it
# for free - simpler and more robust than hand-patchelf-ing individual
# binaries.
{ config, pkgs, ... }:
{
  systemd.services.camofox-browser = {
    description = "Camofox Browser Server (anti-detection headless browser for AI agents)";
    after = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      NODE_ENV = "production";
      CAMOFOX_CRASH_REPORT_ENABLED = "false";
      CAMOFOX_ADDONS = "/root/camofox-browser/addons/quetta_xpi";
      CAMOFOX_DISABLE_DEFAULT_ADDONS = "1";
    };
    serviceConfig = {
      Type = "exec";
      WorkingDirectory = "/root/camofox-browser";
      EnvironmentFile = config.age.secrets.camofox-api-key.path;
      ExecStart = "${pkgs.steam-run}/bin/steam-run ${pkgs.nodejs_22}/bin/node server.js";
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  networking.firewall.allowedTCPPorts = [ 9377 ];
}
