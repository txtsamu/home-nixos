# T7 (txtsamu/claude-research#15): evomem on home.
#
# Data lives on a dedicated TrueNAS iSCSI LUN, not the VM's local disk -
# matches this homelab's existing pattern of keeping stateful data off the
# Proxmox VM and on the NAS (see the k3s apps' democratic-csi-backed PVCs,
# T13). Provisioned out of band on the NAS (192.168.50.10): zvol
# `data/evomem-kb` (20GiB, sparse), extent + target + LUN-0 association,
# all named `evomem-kb`, following the existing `immich-pgdata` convention
# (portal 1, initiator group 1 "allow-all-lan", no CHAP).
#
# `nofail` + a short device-timeout on the mount are deliberate: T1 already
# hit one real boot hang from a missing-device wait
# (txtsamu/claude-research#9) - a NAS blip should degrade evomem (it'll
# just keep restarting via Restart=on-failure until the mount appears),
# not hang the whole box at boot.
{ pkgs, ... }:
let
  evomem = pkgs.stdenvNoCC.mkDerivation rec {
    pname = "evomem";
    version = "0.4.2";
    # txtsamu/evomem fork, branch perf/cache-lexical-vocabulary: upstream 0.4.2
    # plus a cached lexical vocabulary. Upstream rescans all of word_index on
    # every search (~5 s at 43k chunks, serialized behind one mutex, so a few
    # concurrent callers blew past the MCP bridge's timeout); this is ~0.13 s
    # with byte-identical results. Drop back to anvie/evomem once upstream
    # has the fix.
    src = pkgs.fetchzip {
      url = "https://github.com/txtsamu/evomem/releases/download/v${version}-perf1/evomem-${version}-perf1-x86_64-unknown-linux-musl.zip";
      hash = "sha256-x3IQq+k2L3yujtvXHxwssMcqKfzVRy8j2pTXiY4PxP0=";
      stripRoot = false;
    };
    installPhase = "install -Dm755 evomem $out/bin/evomem";
  };
  nasPortal = "192.168.50.10:3260";
  targetIqn = "iqn.2005-10.org.freenas.ctl:evomem-kb";
in
{
  services.openiscsi = {
    enable = true;
    # Fixed rather than auto-generated so it's stable across rebuilds/
    # reinstalls, in case the NAS's "allow-all-lan" initiator group is ever
    # tightened to specific IQNs later. Host-wide (not evomem-specific) -
    # T13's democratic-csi initiator traffic uses the same identity.
    name = "iqn.2026-09.lan.home:initiator";
  };

  systemd.services.iscsi-login-evomem-kb = {
    description = "Discover + login to the evomem-kb TrueNAS iSCSI target";
    after = [
      "network-online.target"
      "iscsid.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "iscsid.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.openiscsi}/bin/iscsiadm -m discovery -t sendtargets -p ${nasPortal}
      ${pkgs.openiscsi}/bin/iscsiadm -m node -T ${targetIqn} -p ${nasPortal} --op update -n node.startup -v automatic
      ${pkgs.openiscsi}/bin/iscsiadm -m node -T ${targetIqn} -p ${nasPortal} --login || true
    '';
  };

  fileSystems."/root/evomem-kb" = {
    device = "/dev/disk/by-path/ip-${nasPortal}-iscsi-${targetIqn}-lun-0";
    fsType = "ext4";
    options = [
      "_netdev"
      "nofail"
      "x-systemd.requires=iscsi-login-evomem-kb.service"
      "x-systemd.after=iscsi-login-evomem-kb.service"
      "x-systemd.device-timeout=30"
    ];
  };

  # Static musl release binary of the fork above, fetched into the store.
  # (Originally upstream's anvie/evomem v0.4.2, byte-identical sha256
  # 577377ca... to the /usr/local/bin/evomem copied over from warp-vm in
  # T7.) The old /usr/local/bin copy is left in place for anything that
  # still calls it by path; `evomem` on PATH is this one.
  systemd.services.evomem = {
    description = "Evomem knowledge server (REST API on :7700)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = "/root/evomem-kb";
    environment.EVOMEM_ROOT = "/root/evomem-kb";
    serviceConfig = {
      Type = "simple";
      ExecStart = "${evomem}/bin/evomem --knowledge /root/evomem-kb serve --host 0.0.0.0 --port 7700";
      Restart = "on-failure";
      RestartSec = 5;
      # Sandbox (config audit). The service needs exactly one writable path -
      # its knowledge directory - so everything else is locked down. Verified
      # before shipping: the same option set was run as a replica on
      # 127.0.0.1:7799 (served /health 200) and a write test into
      # /root/evomem-kb under this exact sandbox succeeded, with the parent
      # read-only as intended.

      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      ReadWritePaths = [ "/root/evomem-kb" ];
    };
  };

  environment.systemPackages = [ evomem ];

  networking.firewall.allowedTCPPorts = [ 7700 ];
}
