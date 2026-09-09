# T3 (txtsamu/claude-research#11): Technitium DNS on home.
#
# Native NixOS module (services.technitium-dns-server), not the Podman
# container warp-vm runs - plan's §1.2 correction confirmed this module is
# real, so it drops Podman from `home` entirely for this service. Data
# directory is fixed at /var/lib/technitium-dns-server (systemd
# DynamicUser + StateDirectory) - existing zone/auth/blocklist data is
# ported wholesale by copying warp-vm's data dir in after first boot and
# chowning to the dynamic UID systemd assigned, not recreated by hand. See
# the ticket's resolution comment for the exact steps.
#
# DNS_SERVER_ADMIN_PASSWORD isn't a module option - the native module has no
# env-passthrough option at all, only the Docker image's entrypoint script
# did that injection. The underlying technitium-dns-server binary itself
# still reads it from the process environment on first-run bootstrap
# (same binary either way). EnvironmentFile is read by systemd's manager
# (root) before the DynamicUser process is spawned, so a normal
# root-owned agenix secret works here despite DynamicUser - no special
# permissions needed.
{ config, ... }:
{
  services.technitium-dns-server = {
    enable = true;
    openFirewall = true;
  };

  systemd.services.technitium-dns-server.serviceConfig.EnvironmentFile =
    config.age.secrets.technitium-admin-password.path;
}
