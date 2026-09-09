# Base config for `home` (T1: provisioning skeleton).
# Every later ticket (T2-T20 in txtsamu/claude-research#10-#28) adds a module
# under ./ and imports it below - dns.nix, proxy.nix, tunnel.nix, vpn.nix,
# mcp.nix, tiktok-bot.nix, evomem.nix, k3s.nix, secrets.nix.
{ lib, pkgs, ... }:
let
  adminSshKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDd++c52S6U85veuAyNZ6j40u///FYsrLvZC0+N5VrIINOGNMUwQMOj7TORwuc+HP1f7PMkh7PqewE92OxSHtW6gyG++7TQg1QIfyqvoCpsqpDviSMF+NM35axDPeBVP/wzf5QzhSiguOKsj02rw66sfpS3nYnBll/SeKQwvpkfv9xGVYqJfmkvU5DLMpGh2Bg9hnwK+VTpjMignPvhrLRX4i+sUB3WtZWFUafmACLikzgnnUsX5L7ZcRvGJgaPMjTPy9yin/WIDFgSvLcSGqXkyh8mdVA/HrkzwhFhG161A/j+CrNbAdR1bSKJC3r2dW8V1u8b9eu31G8bIlqc2xVvlNpGRtsh94owYqCWYLE11srb0AesoVBo4T/9wAWl+MBRX9Y+rBetS09JzpgXeZGUJDwpyjlSWjLabKNcPyOpyU4Q1FoBAkbTarKrZ1p+a2xxrk4q7gEV1YpWtvv8N7jXCLpVBNtewRWfSA76a5ed+0jDyuSVkFZW4oOgrtmHBVs= administrator@WIN-EQ6G9ODFLE0";
in
{
  imports = [
    ./secrets.nix    # T2  - done
    ./dns.nix        # T3  - done
    ./proxy.nix      # T4  - done
    ./tunnel.nix     # T5  - done
    ./vpn.nix        # T6  - done
    ./evomem.nix     # T7  - done
    ./mcp.nix        # T8  - done
    ./camofox.nix    # T9  - done
    ./headroom.nix   # T11 - done
    ./tiktok-bot.nix # T10 - done
    ./k3s.nix        # T13 - done
    ./checkmk-agent.nix # T12 - done
  ];

  # Fix for initrd hang on boot: this VM uses a virtio-scsi-pci controller
  # (Proxmox `scsihw: virtio-scsi-pci`), so the initrd needs virtio_scsi
  # loaded early or /dev/disk/by-partlabel/disk-main-root never appears.
  # Hand-written config, never ran nixos-generate-config to auto-detect this.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "sd_mod"
    "sr_mod"
  ];

  # Matches warp-vm. Real bug hit standing up T13 (k3s): leaving this unset
  # means NixOS never creates /etc/localtime at all (not even a UTC
  # symlink), and containerd's default bind-mount of the host's
  # /etc/localtime into every pod then fails outright ("error mounting
  # /etc/localtime to rootfs ... not a directory") - broke democratic-csi's
  # node pod specifically. Needed on any NixOS host that runs k3s/containerd,
  # not just this one.
  time.timeZone = "Asia/Jakarta";

  networking.hostName = "home";
  # Predictable interface names disabled to match warp-vm's `eth0` (its cloud
  # image also disables them) - avoids depending on virtio PCI enumeration.
  networking.usePredictableInterfaceNames = false;
  networking.useDHCP = false;
  networking.interfaces.eth0.ipv4.addresses = [
    {
      # T19 (txtsamu/claude-research#27): cutover. This was the temp
      # parallel-build IP 192.168.50.202 (plan §4 phase 2-3) until every
      # service on `home` was verified working; now the real, permanent
      # LAN IP, taken over from `warp-vm` once its own remaining services
      # (technitium/caddy/cloudflared/netbird/evomem/hermes/proxmox-mcp)
      # were stopped and its network interface brought down to free it.
      address = "192.168.50.200";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = "192.168.50.1";
  # Primary LAN resolver first; public fallbacks after it.
  #
  # Real bug found while working T3 (txtsamu/claude-research#11): this was
  # "192.168.50.80" until now, carried over from T1's bootstrap-time
  # /etc/resolv.conf without ever being verified against the live service.
  # .80 doesn't answer DNS at all (times out) - warp-vm's actual Technitium
  # instance listens on warp-vm's own primary IP, .200 (host networking,
  # confirmed via `nslookup nas.lan 192.168.50.200`). The T1-era quirk about
  # accepting LAN queries but silently failing public-domain lookups (see
  # #9) was real and is still worth remembering once `home`'s own
  # Technitium (T3) is what everyone actually queries - just filed under
  # the wrong IP until this fix.
  networking.nameservers = [ "192.168.50.200" "1.1.1.1" "8.8.8.8" ];
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  services.qemuGuest.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
      KbdInteractiveAuthentication = false;
    };
  };

  users.mutableUsers = false;
  users.users.moo = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ adminSshKey ];
  };
  users.users.root.openssh.authorizedKeys.keys = [ adminSshKey ];
  security.sudo.wheelNeedsPassword = false;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  environment.systemPackages = with pkgs; [ git vim curl fastfetch htop btop ];

  system.stateVersion = "26.05";
}
