# Disk hygiene for logs on `home` (98 GB root, 73% full on 2026-11-06).
# Found while chasing disk usage: the persistent journal had grown to ~1 GB and
# Technitium's daily query logs to ~840 MB (59 files, one day alone 131 MB),
# neither with any retention.
_: {
  # Cap the persistent journal. journald counts archived files against this
  # limit and rotates itself, so no logrotate is needed for it.
  services.journald.extraConfig = ''
    SystemMaxUse=300M
    MaxRetentionSec=1month
  '';

  # Technitium (DynamicUser, logs under /var/log/private/technitium) writes one
  # file per day and never prunes. "e" = adjust an existing dir, and
  # systemd-tmpfiles-clean (daily timer) deletes entries older than 14 days.
  systemd.tmpfiles.rules = [ "e /var/log/private/technitium/dns - - - 14d" ];
}
