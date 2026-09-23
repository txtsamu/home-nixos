# T4 (txtsamu/claude-research#12): Caddy on home.
#
# Native NixOS module (services.caddy), replacing warp-vm's Podman quadlet -
# same "drop Podman where a native module exists" call as dns.nix (T3).
#
# Originally ported from warp-vm's live /root/caddy/Caddyfile on 2026-09-09
# (T4) with every migrated app's upstream deliberately left pointed at
# warp-vm's pre-migration cluster IPs - repointing those was explicitly
# T14-T18's job as each app actually moved, not T4's.
#
# T19 update (cutover): re-synced against warp-vm's live Caddyfile, which
# is the config I've kept up to date across every T14-T18 repoint (T14-T16
# initially missed doing this in the same ticket and broke warp-vm's own
# live Caddy for real users - see the plan doc's process-gotcha note - T17
# onward did it correctly). This was the actual stale-config bug the user
# flagged and asked to leave for this ticket: every migrated app below was
# still carrying its *pre-migration* IP until now.
#
# `dns.lan`'s 127.0.0.1:5380 upstream needed no change either time - it
# hits whichever host's own Technitium web UI is running locally, same
# relative-localhost meaning on warp-vm or home.
#
# `syncyomi.lan` is intentionally still absent - out of scope since T4's
# original port (plan doc: "18 minus syncyomi.lan = 17 in scope"). It
# stays warp-vm-only and will stop resolving once warp-vm is decommissioned
# (T20) - a known, previously-decided gap, not an oversight.
#
# Refactor (config audit): the 17 sites used to be 17 hand-copied
# `extraConfig` blocks, each repeating the same `tls internal` + proxy
# policy. They are now generated from two name -> upstream maps plus the one
# site that genuinely differs, so TLS/header policy is defined once and a
# site cannot drift by copy-paste. The rendered Caddyfile is byte-identical
# to what the hand-written version produced (verified by building the
# toplevel and diffing /etc/caddy/caddy_config against the live file).
{ lib, ... }:
let
  # Plain-HTTP backends: Caddy terminates TLS with its internal CA
  # (`globalConfig = "local_certs"` below) and proxies to the app.
  #
  # jellyfin/grafana/bastion are still warp-vm's original k3s cluster IPs,
  # unaffected by T14-T18; they were already flagged as pre-existing-down
  # elsewhere in this migration's work, unrelated to T4.
  httpUpstreams = {
    "jellyfin.lan" = "192.168.50.227:8096";
    "grafana.lan" = "192.168.50.224:3000";
    "bastion.lan" = "192.168.50.232:80";

    # Migrated apps (T14-T18) - home's actual MetalLB LoadBalancer IPs,
    # matching warp-vm's live Caddyfile exactly.
    "nextcloud.lan" = "192.168.50.250:80";
    "immich.lan" = "192.168.50.251:2283";
    "uptime.lan" = "192.168.50.247:3001";
    "bookstack.lan" = "192.168.50.241:80";
    "openwebui.lan" = "192.168.50.245:8080";
    "copyparty.lan" = "192.168.50.242:3923";
    "mihon.lan" = "192.168.50.248:4567";

    # Perses dashboard (metrics visualization on top of the VictoriaMetrics
    # instance from home-k8s-resource-rightsizing-victoriametrics.md).
    # Same ClusterIP-direct pattern as rancher.lan - plain HTTP backend, no
    # TLS transport block needed.
    "perses.lan" = "10.43.155.107:8080";

    # ComfyUI (Qwen-Image 2.1 GGUF) runs on the fedora desktop
    # (192.168.50.20), not in k3s - it needs the RX 7800 XT and `home` has
    # no GPU. Plain HTTP backend; Caddy proxies its websocket (/ws)
    # transparently.
    "comfy.lan" = "192.168.50.20:8188";

    # Technitium's own web UI on this host - 127.0.0.1 keeps its local
    # meaning regardless of which host runs Caddy.
    "dns.lan" = "127.0.0.1:5380";
  };

  # Backends that speak TLS themselves and need Host passthrough with the
  # certificate check skipped (self-signed or internal-CA certs).
  #
  # Real bug found post-cutover (2026-09-10): rancher.lan pointed at
  # warp-vm's own Rancher (LoadBalancer IP .220), which went away when
  # warp-vm was shut down in T19. home has its own Rancher (bootstrapped as
  # part of the platform layer in T13) but it was only ever given a
  # ClusterIP, never exposed via a MetalLB LoadBalancer IP - so this points
  # directly at that ClusterIP, confirmed reachable from the host network
  # (kube-proxy's rules apply node-wide, not just inside pod netns).
  tlsUpstreams = {
    "rancher.lan" = "https://10.43.126.48";

    # External infra, not part of this migration at all - unaffected.
    "nas.lan" = "https://192.168.50.10";
    "px1.lan" = "https://192.168.50.30:8006";
    "px2.lan" = "https://192.168.50.50:8006";
  };
in
{
  services.caddy = {
    enable = true;
    globalConfig = "local_certs";

    virtualHosts =
      lib.mapAttrs
        (name: upstream: {
          extraConfig = ''
            tls internal
            reverse_proxy ${upstream}
          '';
        })
        httpUpstreams
      // lib.mapAttrs
        (name: upstream: {
          extraConfig = ''
            tls internal
            reverse_proxy ${upstream} {
              header_up Host {host}
              transport http {
                tls_insecure_skip_verify
              }
            }
          '';
        })
        tlsUpstreams
      // {
        # Checkmk's UI is served under /cmk/ - same permanent redirect
        # warp-vm had (it is the one site whose body genuinely differs).
        "monitor.lan".extraConfig = ''
          tls internal
          redir / /cmk/ permanent
          reverse_proxy 192.168.50.240:5000
        '';
      };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
