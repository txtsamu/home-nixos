# T4 (txtsamu/claude-research#12): Caddy on home.
#
# Native NixOS module (services.caddy), replacing warp-vm's Podman quadlet -
# same "drop Podman where a native module exists" call as dns.nix (T3).
# Each virtualHost's body is kept as near-verbatim Caddyfile syntax (via
# extraConfig) rather than hand-translated to some other shape, to minimize
# the chance of silently changing behavior mid-port.
#
# Ported from warp-vm's live /root/caddy/Caddyfile as of 2026-09-09. Real
# discrepancy found: the plan doc's inventory says "18 minus syncyomi.lan =
# 17 in scope", but the live file only has 17 blocks total (16 in scope
# after dropping syncyomi.lan) - one block seems to have been removed
# between the plan's inventory and now (the file's own history of drifting
# .bak copies, noted in the plan, makes this unsurprising). Going with what's
# actually live, not the doc's stale count.
#
# Upstreams are left pointed at warp-vm's cluster IPs (192.168.50.22x-23x,
# still the live/authoritative backends) exactly as warp-vm's own Caddy has
# them - repointing to home's own k3s is T14-T18's job as apps actually
# move, not this ticket's. dns.lan's 127.0.0.1:5380 upstream is the one
# exception that's already "correct" on home as-is: it hits home's own
# Technitium web UI (T3), not warp-vm's - same relative-localhost meaning
# on either host.
{ ... }:
{
  services.caddy = {
    enable = true;
    globalConfig = "local_certs";

    virtualHosts."jellyfin.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.227:8096
    '';

    virtualHosts."nextcloud.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.233:80
    '';

    virtualHosts."immich.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.234:2283
    '';

    virtualHosts."grafana.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.224:3000
    '';

    virtualHosts."uptime.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.223:3001
    '';

    virtualHosts."bastion.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.232:80
    '';

    virtualHosts."bookstack.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.225:80
    '';

    virtualHosts."openwebui.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.228:8080
    '';

    virtualHosts."copyparty.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.226:3923
    '';

    virtualHosts."mihon.lan".extraConfig = ''
      tls internal
      reverse_proxy 192.168.50.229:4567
    '';

    virtualHosts."rancher.lan".extraConfig = ''
      tls internal
      reverse_proxy https://192.168.50.220 {
        header_up Host {host}
        transport http {
          tls_insecure_skip_verify
        }
      }
    '';

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

    virtualHosts."monitor.lan".extraConfig = ''
      tls internal
      redir / /cmk/ permanent
      reverse_proxy 192.168.50.221:5000
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
