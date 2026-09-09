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
    ./secrets.nix    # T2  - stub, real content lands with T2
    ./dns.nix        # T3  - stub
    ./proxy.nix      # T4  - stub
    ./tunnel.nix     # T5  - stub
    ./vpn.nix        # T6  - stub
    ./evomem.nix     # T7  - stub
    ./mcp.nix        # T8  - stub
    ./tiktok-bot.nix # T9/T10 - stub
    ./k3s.nix        # T13 - stub
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

  networking.hostName = "home";
  # Predictable interface names disabled to match warp-vm's `eth0` (its cloud
  # image also disables them) - avoids depending on virtio PCI enumeration.
  networking.usePredictableInterfaceNames = false;
  networking.useDHCP = false;
  networking.interfaces.eth0.ipv4.addresses = [
    {
      # TEMP IP for parallel build/verification (plan §4 phase 2-3).
      # Cutover ticket (T19, txtsamu/claude-research#27) moves this to
      # warp-vm's current 192.168.50.200/24 once every service is verified.
      address = "192.168.50.202";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = "192.168.50.1";
  networking.nameservers = [ "192.168.50.80" ];
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

  environment.systemPackages = with pkgs; [ git vim curl fastfetch ];

  system.stateVersion = "26.05";
}
