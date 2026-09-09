# T4 (txtsamu/claude-research#12): Caddy on home.
#
# Native NixOS module (services.caddy), replacing warp-vm's Podman quadlet -
# same "drop Podman where a native module exists" call as dns.nix (T3).
# Each virtualHost's body is kept as near-verbatim Caddyfile syntax (via
# extraConfig) rather than hand-translated to some other shape, to minimize
# the chance of silently changing behavior mid-port.
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
{ ... }:
{
  services.caddy = {
    enable = true;
    globalConfig = "local_certs";

    # Not migrated - still warp-vm's original k3s cluster IPs, unaffected
    # by T14-T18. jellyfin/grafana/bastion/rancher were already flagged as
    # pre-existing-down elsewhere in this migration's work, unrelated to
    # this ticket.
    virtualHosts."jellyfin.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.227:8096
    '';

    virtualHosts."grafana.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.224:3000
    '';

    virtualHosts."bastion.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.232:80
    '';

    # Real bug found post-cutover (2026-09-10): this pointed at warp-vm's
    # own Rancher (LoadBalancer IP .220), which went away when warp-vm was
    # shut down in T19. home has its own Rancher (bootstrapped as part of
    # the platform layer in T13) but it was only ever given a ClusterIP,
    # never exposed via a MetalLB LoadBalancer IP - repointed directly at
    # that ClusterIP instead, confirmed reachable from the host network
    # (kube-proxy's rules apply node-wide, not just inside pod netns).
    virtualHosts."rancher.lan".extraConfig = ''
      tls internal
      reverse_proxy https://10.43.126.48 {
        header_up Host {host}
        transport http {
          tls_insecure_skip_verify
        }
      }
    '';

    # Migrated apps (T14-T18) - upstreams corrected to home's actual
    # MetalLB LoadBalancer IPs, matching warp-vm's live Caddyfile exactly.
    virtualHosts."nextcloud.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.250:80
    '';

    virtualHosts."immich.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.251:2283
    '';

    virtualHosts."uptime.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.247:3001
    '';

    virtualHosts."bookstack.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.241:80
    '';

    virtualHosts."openwebui.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.245:8080
    '';

    virtualHosts."copyparty.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.242:3923
    '';

    virtualHosts."mihon.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.248:4567
    '';

    virtualHosts."monitor.lan".extraConfig = ''
      tls internal
      redir / /cmk/ permanent
      reverse_proxy 192.168.50.240:5000
    '';

    # External infra, not part of this migration at all - unaffected.
    virtualHosts."nas.lan".extraConfig = ''
      tls internal
      reverse_proxy https://192.168.50.10 {
        header_up Host {host}
        transport http {
          tls_insecure_skip_verify
        }
      }
    '';

    virtualHosts."px1.lan".extraConfig = ''
      tls internal
      reverse_proxy https://192.168.50.30:8006 {
        header_up Host {host}
        transport http {
          tls_insecure_skip_verify
        }
      }
    '';

    virtualHosts."px2.lan".extraConfig = ''
      tls internal
      reverse_proxy https://192.168.50.50:8006 {
        header_up Host {host}
        transport http {
          tls_insecure_skip_verify
        }
      }
    '';

    virtualHosts."dns.lan".extraConfig = ''
      tls internal
      reverse_proxy 127.0.0.1:5380
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
