# T8 (txtsamu/claude-research#16): MCP trio on home.
#
# hermes-gateway, hermes-mcp, and proxmox-mcp-plus, built as systemd units
# that run the (uv-built) venvs under /opt - same "artifacts live outside the
# Nix store" pattern as evomem (T7) and the other hand-provisioned binaries
# this flake expects. The venvs are provisioned out of band (uv + a Nix
# python3.13 as base interpreter - see the T8 resolution comment for the exact
# recipe), the hermes source is rsynced to /opt/hermes-source, and the
# /root/.hermes state dir is rsynced from warp-vm (node_modules included).
#
# Deliberate deviations from warp-vm's units:
#   - node: warp-vm's /root/.hermes/node is a dynamically-linked binary that
#     cannot run on NixOS. Use pkgs.nodejs_22 on PATH instead (gateway
#     sidecar/node usage). node_modules under /opt/hermes-source are kept.
#   - /usr/bin/python3 does not exist on NixOS; hermes-mcp runs the daemon
#     with the hermes venv python instead of the host python.
{ config, pkgs, ... }:
let
  hermesVenv = "/opt/hermes-venv";
  hermesBin = "${hermesVenv}/bin";
  proxmoxVenv = "/opt/proxmox-venv";
  nodeBin = "${pkgs.nodejs_22}/bin";
  # PATH for the hermes gateway + mcp child processes. Venv first (so
  # `python`/`hermes` resolve there), then Nix node, the source's
  # node_modules .bin (sidecar tooling), then system + /usr/local.
  basePath = "${hermesBin}:${nodeBin}:/opt/hermes-source/node_modules/.bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin";
in
{
  # python3.13 + nodejs_22 referenced by the system so the venv base
  # interpreter and gateway node usage stay available (GC roots).
  environment.systemPackages = [ pkgs.python313 pkgs.nodejs_22 ];

  systemd.services.hermes-gateway = {
    description = "Hermes Agent Gateway - Messaging Platform Integration";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    startLimitIntervalSec = 0;
    serviceConfig = {
      Type = "simple";
      User = "root";
      Group = "root";
      ExecStart = "${hermesBin}/python -m hermes_cli.main gateway run";
      WorkingDirectory = "/root/.hermes";
      Environment = [
        "HOME=/root"
        "USER=root"
        "LOGNAME=root"
        "PATH=${basePath}"
        "VIRTUAL_ENV=${hermesVenv}"
        "HERMES_HOME=/root/.hermes"
        "HERMES_SUPERVISED_CHILD=1"
      ];
      Restart = "always";
      RestartSec = "5";
      RestartForceExitStatus = "75";
      RestartPreventExitStatus = "78";
      KillMode = "mixed";
      KillSignal = "SIGTERM";
      ExecReload = "${pkgs.coreutils}/bin/kill -USR1 $MAINPID";
      ExecStopPost = "${hermesBin}/python -m gateway.cgroup_cleanup";
      TimeoutStopSec = "90";
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  systemd.services.hermes-mcp = {
    description = "Hermes MCP Bridge (pre-warmed stdio daemon)";
    after = [ "network.target" "hermes-gateway.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${hermesBin}/python /root/.hermes/mcp-daemon.py";
      Restart = "always";
      RestartSec = "3";
      User = "root";
      Environment = [ "HOME=/root" "PATH=${basePath}" ];
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  systemd.services.proxmox-mcp-plus = {
    description = "ProxmoxMCP-Plus MCP Server";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      Environment = "PROXMOX_MCP_CONFIG=${config.age.secrets.proxmox-mcp-config.path}";
      ExecStart = "${proxmoxVenv}/bin/proxmox-mcp-plus";
      Restart = "on-failure";
      RestartSec = "5";
    };
  };

  # proxmox-mcp-plus is a streamable MCP server bound to :8811, reached by
  # Claude Code from other hosts. hermes-mcp is on a local Unix socket
  # (no firewall change needed); the gateway dials out (no inbound port).
  networking.firewall.allowedTCPPorts = [ 8811 ];
}
