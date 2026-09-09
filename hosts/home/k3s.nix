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
    ];
  };

  environment.systemPackages = with pkgs; [ kubectl kubernetes-helm ];

  networking.firewall.allowedTCPPorts = [ 6443 ];
}
