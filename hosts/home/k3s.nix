# T13 (txtsamu/claude-research#21): k3s core platform on home.
#
# Single-node k3s, same flags as warp-vm's live cluster (disable traefik +
# servicelb - MetalLB replaces servicelb, an Ingress controller is a later
# concern once real app traffic moves over). services.openiscsi is already
# enabled by evomem.nix (T7); democratic-csi's node plugin uses the same
# initiator identity.
#
# The Helm platform layer (Rancher, Fleet+friends bootstrapped by Rancher
# itself, cert-manager, democratic-csi) and the MetalLB manifest are applied
# imperatively after activation, not declared here - they're live Kubernetes
# objects inside the cluster this module stands up, not NixOS state, and
# that's how warp-vm's cluster itself was built (plan's §1.2/§3.2). See the
# ticket's resolution comment for the exact commands run and the values
# used (matched against warp-vm's `helm get values` output).
{ config, pkgs, ... }:
{
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = toString [
      "--disable=traefik"
      "--disable=servicelb"
      "--write-kubeconfig-mode=644"
      # Real bug hit while working T14 (txtsamu/claude-research#22): k3s's
      # bundled kube-router network-policy controller crash-loops the
      # entire k3s.service against MetalLB's nftables rules - a known,
      # unresolved upstream issue (k3s-io/k3s#11493, explicitly reported
      # "in environments using metallb with L2Advertisement", exactly this
      # setup). Symptom was intermittent, confusing "connection refused"
      # errors from kubectl (the API server was actually restarting under
      # it). warp-vm's cluster only has one trivial no-op NetworkPolicy
      # (cattle-fleet-local-system/default-allow-all) - nothing relies on
      # real enforcement, and --disable-network-policy is k3s's own
      # documented fix for this exact controller/CNI conflict class.
      "--disable-network-policy"
      # Same root cause hits kube-proxy too, non-fatally but functionally:
      # its default iptables mode goes through the same iptables-nft
      # translation shim, so it was logging "Sync failed" on the
      # FORWARD->KUBE-EXTERNAL-SERVICES chain jump every 30s and silently
      # not maintaining its rules - exactly the chain LoadBalancer/NodePort
      # external traffic needs. Switch kube-proxy itself to Kubernetes'
      # native nftables backend (GA since k8s 1.33, this is 1.35) instead
      # of the iptables-compat shim - avoids the translation layer
      # entirely rather than working around symptoms of it.
      "--kube-proxy-arg=proxy-mode=nftables"
      # Paired with configuration.nix's swapfile addition (real memory
      # overcommit on this box - Checkmk flags CRIT at 157% committed).
      # kubelet refuses to start at all on a node with swap enabled
      # unless told otherwise - this isn't optional once swapDevices is
      # non-empty. Deliberately not also setting
      # --kubelet-arg=feature-gates=NodeSwap=true: that would let pod
      # cgroups use swap directly, which is still rough upstream (real
      # reports of pods ignoring configured swap limits in current k3s)
      # and isn't needed for the actual goal - a host-level safety net
      # against OOM-killer thrashing, not per-pod swap accounting.
      "--kubelet-arg=fail-swap-on=false"
    ];
  };

  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
  ];

  # 10250 = kubelet's own API (metrics/cadvisor/exec/logs). Never opened
  # before because nothing needed to reach it from outside the node -
  # metrics-server's own `kubectl top` scraping apparently doesn't hit
  # this same external-IP path (or is otherwise exempted), so this went
  # unnoticed until a real external scraper (VictoriaMetrics, added for
  # the 48h resource-right-sizing exercise referenced in the migration
  # plan doc) tried to reach `role: node` targets at the node's real LAN
  # IP and hit a firewall timeout, not a connection refused.
  networking.firewall.allowedTCPPorts = [
    6443
    10250
  ];

  # NFS client support - needed for the plain-NFS PVs some apps use
  # alongside democratic-csi's iSCSI-backed ones (photos-nfs, immich-nfs,
  # nextcloud-nfs, all served from the same TrueNAS box at 192.168.50.10).
  # Real bug hit while working T14 (txtsamu/claude-research#22): without
  # this, kubelet's NFS mount fails outright - "NFS: mount program didn't
  # pass remote address" - because NixOS doesn't wire up NFS client support
  # (rpcbind + the nfs kernel module/mount.nfs helper) by default the way
  # Debian does. The plan doc's original T1 inventory actually flagged this
  # dependency (rpcbind/nfs-blkmap "needed for ... the /mnt/photos NFS
  # mount") but it never got wired into a module until now.
  boot.supportedFilesystems = [ "nfs" ];
  services.rpcbind.enable = true;

  # ...that fix alone wasn't enough: k3s.service's systemd unit has its own
  # narrow, hardcoded PATH (coreutils/findutils/gnugrep/gnused/systemd
  # only) that doesn't include /run/current-system/sw/bin, so kubelet still
  # couldn't find mount.nfs even once it existed on the system - manually
  # running the exact same mount command as root succeeded immediately,
  # which is what pointed at PATH rather than NFS support itself being
  # broken. systemd.services.<name>.path extends a unit's PATH without
  # having to hand-list every other binary already implicitly available.
  systemd.services.k3s.path = [ pkgs.nfs-utils ];

  # democratic-csi's node plugin hostPath-mounts this in (iscsiDirHostPath in
  # its Helm values, matching warp-vm's convention) - unlike Debian, NixOS
  # doesn't create /var/iscsi implicitly, so the node pod's mount silently
  # fails without it (real bug hit standing this up: FailedMount, "/var/iscsi
  # is not a directory").
  systemd.tmpfiles.rules = [ "d /var/iscsi 0755 root root -" ];

  # Clean shutdown for the iSCSI-backed pod volumes.
  #
  # Real bug, 2026-11-07: `systemctl reboot` hung and needed a hard reset from
  # Proxmox. k3s.service has KillMode=process, so stopping it leaves the
  # containerd-shim pods running, and kubelet's CSI volumes (democratic-csi
  # iSCSI LUNs mounted under /var/lib/kubelet) stay mounted - systemd has no
  # unit for them, so nothing orders their unmount against the network. The
  # network went down (eth0 address deleted) with those filesystems still
  # mounted, iscsid lost the NAS, the sync in systemd-shutdown timed out, the
  # NAS dropped the sessions after its 30 s NOP timeout, and ext4 aborted the
  # journals on a dozen volumes (postgres/mariadb crash recovery on next boot).
  #
  # This unit starts before k3s and stops after it, and after iscsid and
  # network-online (stop order is the reverse of start order), so its ExecStop
  # runs once k3s is down but while the network and iscsid still work. It
  # waits for the pods to exit on their own (systemd is already stopping their
  # cri-containerd scopes), then runs k3s's own killall script for any leftover
  # shims and to unmount /var/lib/kubelet/{pods,plugins}, and finally logs the
  # democratic-csi iSCSI sessions out. The evomem-kb LUN is not touched: it is
  # a normal fstab mount that systemd already unmounts first.
  #
  # restartIfChanged/stopIfChanged = false: a `switch` must never run ExecStop
  # on a live node - that would kill every pod.
  systemd.services.k3s-shutdown-cleanup = {
    description = "Stop k3s pods and detach CSI iSCSI volumes before the network goes down";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "iscsid.service"
    ];
    before = [ "k3s.service" ];
    restartIfChanged = false;
    stopIfChanged = false;
    path = with pkgs; [
      coreutils
      gnugrep
      gnused
      openiscsi
      procps
      config.services.k3s.package
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
      TimeoutStopSec = 240;
    };
    preStop = ''
      # Pods get SIGTERM from systemd's own scope stops; give them time to
      # flush (databases) before anything is killed.
      deadline=$((SECONDS + 100))
      while pgrep -f containerd-shim > /dev/null && [ "$SECONDS" -lt "$deadline" ]; do
        sleep 1
      done

      # Kill leftover shims, unmount /var/lib/kubelet/{pods,plugins} and
      # /run/k3s, remove CNI state. Failures must not block shutdown.
      k3s-killall.sh || true

      # Log out the CSI iSCSI sessions while the network is still up.
      iscsiadm -m session 2>/dev/null \
        | sed -n 's/^tcp: \[[0-9]*\] \([^ ,]*\),[0-9]* \(iqn[^ ]*\) .*/\1 \2/p' \
        | grep ':csi-' \
        | while read -r portal target; do
            iscsiadm -m node -p "$portal" -T "$target" --logout || true
          done
      exit 0
    '';
  };
}
