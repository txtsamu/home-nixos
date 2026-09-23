# Base config for `home` (T1: provisioning skeleton).
# Every later ticket (T2-T20 in txtsamu/claude-research#10-#28) adds a module
# under ./ and imports it below - dns.nix, proxy.nix, tunnel.nix, vpn.nix,
# mcp.nix, tiktok-bot.nix, evomem.nix, k3s.nix, secrets.nix.
{ lib, pkgs, ... }:
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

  # Deliberate trade-off on the public fallbacks: they are only reached when
  # Technitium itself is down, and during that window DNS filtering is bypassed
  # (no blocklists). Kept as-is because resolution surviving a resolver
  # restart matters more here than blocking during that window.
  #
  # LAN short names: Technitium's zone is a *suffix* (`nas.lan` exists, bare
  # `nas` is NXDOMAIN) and the MikroTik DHCP network hands out no `search`
  # domain, so bare names can only come from here - nsswitch consults `files`
  # before `dns`. Same list every other homelab host keeps in /etc/hosts:
  # ranked by IP, one name per line, sections kept. Source of truth is a live
  # peer (`ssh moo@192.168.50.20 cat /etc/hosts`) - re-pull and diff before
  # editing, a name at an IP does get replaced.
  networking.extraHosts = ''
    ### Home Network Hosts ###
    192.168.50.1    mikrotik
    192.168.50.10   nas
    192.168.50.20   fedora
    192.168.50.30   px1
    192.168.50.40   arm1
    192.168.50.41   arm2
    192.168.50.42   arm3
    192.168.50.43   arm4
    192.168.50.50   px2

    ### VPS ###
    103.134.154.180 vpz
  '';
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
    # Key material lives in ./keys/admin.pub (not inlined) so the same file can
    # be handed to a new user or rotated with a one-file diff. Both accounts
    # currently share it - split it per user if a second operator is added.
    openssh.authorizedKeys.keyFiles = [ ./keys/admin.pub ];
  };
  users.users.root.openssh.authorizedKeys.keyFiles = [ ./keys/admin.pub ];
  security.sudo.wheelNeedsPassword = false;

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # 8G swapfile on the root disk (38G free at the time this was added,
  # 16GiB physical RAM, real overcommit already observed - Checkmk flags
  # memory CRIT at 157% committed across all containers). A host-level
  # safety net against OOM-killer thrashing under bursty load, not meant
  # to be worked hard continuously.
  #
  # Real gotcha this needed pairing with: k3s.nix's kubelet-arg below.
  # kubelet refuses to start at all on a node with swap enabled unless
  # explicitly told to tolerate it (`--fail-swap-on=false`) - adding a
  # swapfile without that flag would have broken the whole cluster again,
  # the same class of "one change, unexpected blast radius" as the T19
  # node-IP/MetalLB incident. Deliberately *not* enabling the NodeSwap
  # feature gate alongside it - that would let individual pod cgroups use
  # swap directly, which is still rough in current k3s/kubelet (real
  # upstream reports of pods ignoring configured swap limits) and isn't
  # needed for the actual goal here (host-level headroom, not per-pod
  # swap accounting).
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 8 * 1024;
    }
  ];

  # Flakes and nix-command: this host is *built* with
  # `nixos-rebuild switch --flake github:txtsamu/home-nixos#home`, but Nix
  # disables both features by default. Without this block every `nix`
  # invocation on the box needs explicit --extra-experimental-features flags,
  # so plain `nix flake check`, `nix run` and `nix profile install` (and any
  # script wrapping them) fail on what looks like a broken install.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Dedupe identical files across the store as they are written.
  nix.settings.auto-optimise-store = true;

  # Automatic store cleanup. Nothing collected the store before this
  # (`nix-gc.service` was never enabled, /nix/store had grown to 4.9G with /
  # at 60%). Weekly; generations older than 30 days go, the running system
  # and its boot entry are never collected.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # `moo` is the operator account - every switch is run as `sudo nixos-rebuild`
  # from it. trusted-users lets it use flake registries/substituters and build
  # directly instead of being treated as an untrusted user. `root` is already
  # in the module default, so only moo needs adding here.
  nix.settings.trusted-users = [ "moo" ];

  environment.systemPackages = with pkgs; [ git vim curl fastfetch htop btop ];

  system.stateVersion = "26.05";
}
