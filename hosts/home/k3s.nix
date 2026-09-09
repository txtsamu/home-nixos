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
{ pkgs, ... }:
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
    ];
  };

  environment.systemPackages = with pkgs; [ kubectl kubernetes-helm ];

  networking.firewall.allowedTCPPorts = [ 6443 ];

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

  # democratic-csi's node plugin hostPath-mounts this in (iscsiDirHostPath in
  # its Helm values, matching warp-vm's convention) - unlike Debian, NixOS
  # doesn't create /var/iscsi implicitly, so the node pod's mount silently
  # fails without it (real bug hit standing this up: FailedMount, "/var/iscsi
  # is not a directory").
  systemd.tmpfiles.rules = [ "d /var/iscsi 0755 root root -" ];
}
