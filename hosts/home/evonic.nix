# Evonic agent platform (https://github.com/anvie/evonic, v1.6.0, AGPL) on home,
# run side by side with Hermes to benchmark the two agents.
#
# Loopback only, on purpose: 127.0.0.1:8080. No Caddy route, no Cloudflare
# tunnel, no DNS record, no firewall opening - reach it with an SSH tunnel
# (`ssh -L 8080:127.0.0.1:8080 home`).
#
# Removal: delete this file, its import in configuration.nix, the `evonic`
# entries in provision.nix (sources, venvs, service ordering) and
# venvs/evonic.txt, then switch. Switching leaves the data behind; to wipe it:
# `sudo rm -rf /var/lib/evonic /opt/evonic-source /opt/evonic-venv
# /var/lib/provision-venvs/evonic.lock`.
#
# Pieces (same layout as Hermes, see provision.nix):
#   /opt/evonic-source   git checkout of txtsamu/evonic, branch home/v1.6.0
#                        (identical to upstream v1.6.0), cloned by
#                        provision-src-evonic, owned by the evonic user
#   /opt/evonic-venv     uv venv on the Nix python313, provision-venv-evonic
#   /var/lib/evonic      state: the checkout has shared/ agents/ data/ logs/
#                        run/ symlinked here, so the sqlite DB, agent
#                        workspaces, knowledge bases and logs live outside the
#                        code tree. The one exception is /opt/evonic-source/.env:
#                        Evonic rewrites it in place (generated SECRET_KEY,
#                        ADMIN_PASSWORD_HASH from `evonic pass`/setup).
#
# No secrets in git. The LLM API key is added by hand after deployment with
# `evonic model add` (stored in the sqlite DB under /var/lib/evonic).
#
# Sandbox: Evonic's Docker sandbox is a per-agent DB flag (`sandbox_enabled`,
# default 0) - not an env var - and home has no Docker/Podman, so it stays off
# and tools run as the unprivileged `evonic` user inside the systemd sandbox
# below.
{ lib, pkgs, ... }:
let
  src = "/opt/evonic-source";
  venv = "/opt/evonic-venv";
  state = "/var/lib/evonic";
  port = 8080;
in
{
  users.users.evonic = {
    isSystemUser = true;
    group = "evonic";
    home = state;
    description = "Evonic agent platform";
  };
  users.groups.evonic = { };

  systemd.tmpfiles.rules = map (d: "d ${state}${d} 0750 evonic evonic -") [
    ""
    "/shared"
    "/agents"
    "/data"
    "/logs"
    "/run"
  ];

  systemd.services.evonic = {
    description = "Evonic agent platform (127.0.0.1:${toString port}, loopback only)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    # PATH for the agent's shell tools (sandbox is off, so they run directly).
    path = [
      pkgs.bash
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gnutar
      pkgs.gzip
      pkgs.curl
      pkgs.procps
      pkgs.ripgrep
    ];
    environment = {
      HOME = state;
      # Bind loopback only. HOST/PORT are also passed on the command line;
      # CONNECTOR_WS_HOST (tunnel-workplace relay) defaults to 0.0.0.0.
      HOST = "127.0.0.1";
      PORT = toString port;
      CONNECTOR_WS_HOST = "127.0.0.1";
      DEBUG = "0";
      PYTHONUNBUFFERED = "1";
      # The venv holds manylinux wheels (numpy, opencv, onnxruntime) that dlopen
      # libstdc++ and libz, which NixOS does not put on the default library
      # path. Without this `import numpy` fails inside the service, and with it
      # Evonic's PromptPurify L5e prompt-injection classifier never loads.
      LD_LIBRARY_PATH = lib.makeLibraryPath [
        pkgs.stdenv.cc.cc.lib
        pkgs.zlib
      ];
      # Cookies default to Secure; this is plain http on loopback.
      FORCE_INSECURE_COOKIES = "1";
      # Memory engine: the evomem binary home already installs (evomem.nix).
      # Resolved through the system profile so it tracks that module; the
      # online "newer evomem?" check would try to overwrite a read-only
      # store path, so it is off.
      EVOMEM_BINARY = "/run/current-system/sw/bin/evomem";
      EVONIC_SKIP_EVOMEM_UPDATE_CHECK = "1";
      # Seconds Evonic waits for one evomem CLI call (default 5). A sync of a
      # knowledge base with a few hundred notes takes longer, and a timed-out
      # sync silently leaves the index stale.
      EVOMEM_TIMEOUT = "120";
    };
    serviceConfig = {
      Type = "simple";
      User = "evonic";
      Group = "evonic";
      WorkingDirectory = src;
      # Foreground mode (no -d): systemd supervises the process. `evonic` is
      # a bash wrapper that picks .venv/bin/python, which provision-src-evonic
      # points at ${venv}.
      ExecStart = "${src}/evonic start --host 127.0.0.1 --port ${toString port}";
      Restart = "on-failure";
      RestartSec = 10;
      TimeoutStopSec = 30;
      # Sandbox. Writable: the state dir and the source checkout (Evonic
      # rewrites .env there and installs skills/plugins into it); everything
      # else is read-only or hidden. Outbound network stays open for the LLM
      # API. No MemoryDenyWriteExecute: numpy/opencv wheels are not
      # guaranteed to be compatible with it.
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      RestrictNamespaces = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
      CapabilityBoundingSet = "";
      UMask = "0077";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      ReadWritePaths = [
        state
        src
        # Per-task workspaces of the Evonic-vs-Hermes benchmark (written by
        # the agent's file/bash tools). "-": ignored when the directory does
        # not exist, so removing the benchmark never breaks the unit.
        "-/srv/bench/work"
      ];
      # Keep a runaway agent from starving hermes and the k3s workloads.
      MemoryMax = "4G";
    };
  };
}
