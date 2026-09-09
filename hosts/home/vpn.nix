# T6 (txtsamu/claude-research#14): NetBird mesh membership on home.
#
# Scope cut down from the original ticket text after checking with the
# user: WARP-routed egress (warp-svc, warp-bypass-setup.sh's `ip rule`
# logic, and the WARP-dependent relays - microsocks, socks-relay,
# ovpn-relay) is dead weight, not something to port. The user doesn't use
# WARP anymore since warp-vm moved to NetBird - this module is NetBird
# membership only.
#
# `netbird` *package*, not the `services.netbird` module - matches the
# plan's §2.1 call (the module has several open 2026 nixpkgs bugs relevant
# to a self-hosted management setup; see the migration plan doc). Hand-
# written unit mirrors warp-vm's own netbird.service almost exactly.
#
# Fresh enrollment, not a copy of warp-vm's identity: a single machine-
# scoped setup key created directly in the NetBird dashboard
# (vpn.ssamu.id) by the user. warp-vm keeps its own peer identity as-is
# until T19/T20 - this is a genuinely new peer, not a migrated one.
{ pkgs, config, ... }:
{
  systemd.services.netbird = {
    description = "NetBird mesh network client";
    after = [ "network.target" "syslog.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.netbird}/bin/netbird service run --log-level info --daemon-addr unix:///var/run/netbird.sock --log-file /var/log/netbird/client.log";
      Restart = "always";
      RestartSec = 120;
      StateDirectory = "netbird";
      LogsDirectory = "netbird";
    };
  };

  # Idempotent: `netbird up` only actually consumes the setup key on first
  # registration - once /var/lib/netbird holds a registered peer identity,
  # subsequent runs (every activation/boot) just reconnect using the
  # existing local state, so re-running this on every switch is safe and
  # doesn't burn through the setup key's use count.
  systemd.services.netbird-up = {
    description = "NetBird enrollment/reconnect";
    after = [ "netbird.service" ];
    requires = [ "netbird.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.netbird}/bin/netbird up --management-url https://vpn.ssamu.id:443 --setup-key-file ${config.age.secrets.netbird-setup-key.path}";
    };
  };

  # Port of warp-vm's netbird-k8s-fwd-fix.sh (netbirdio/netbird#6022:
  # kube-router-style forwarding clobbers the meta mark NetBird uses to
  # authorize forwarded traffic, so wt0-sourced traffic bound for the k3s
  # pod CIDR gets dropped by netbird's catch-all forward-filter chain).
  # Not Kube-OVN-specific as the original comment might suggest - it's a
  # generic NetBird+k8s interaction, and home's k3s uses the same default
  # flannel pod CIDR (10.42.0.0/16) that triggered it on warp-vm.
  systemd.services.netbird-k8s-fwd-fix = {
    description = "Re-insert NetBird forward-filter accept rule for the k3s pod CIDR";
    after = [ "netbird-up.service" ];
    requires = [ "netbird-up.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.nftables ];
    script = ''
      for i in $(seq 1 30); do
        nft list chain ip netbird netbird-acl-forward-filter >/dev/null 2>&1 && break
        sleep 1
      done
      nft list chain ip netbird netbird-acl-forward-filter 2>/dev/null | grep -q "10.42.0.0/16" && exit 0
      nft insert rule ip netbird netbird-acl-forward-filter iifname "wt0" ip daddr 10.42.0.0/16 accept
    '';
  };
}
