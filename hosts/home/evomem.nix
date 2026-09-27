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
    src = pkgs.fetchzip {
      url = "https://github.com/anvie/evomem/releases/download/v${version}/evomem-${version}-x86_64-unknown-linux-musl.zip";
      hash = "sha256-E9ZKFEyw2sTfbLbR0s3xk79LnrdMtpPXZqB8hkItpR8=";
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

  # Upstream's static musl release binary (anvie/evomem v0.4.2), fetched
  # into the store. Byte-identical (sha256 577377ca...) to the
  # /usr/local/bin/evomem copied over from warp-vm in T7, so this is the
  # same tested artifact, now reproducible from the flake. The old
  # /usr/local/bin copy is left in place for anything that still calls it
  # by path; `evomem` on PATH is this one.
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
    };
  };

  environment.systemPackages = [ evomem ];

  networking.firewall.allowedTCPPorts = [ 7700 ];
}
