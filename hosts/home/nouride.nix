{ pkgs, ... }:
let
  dir = "/srv/nouride";
in
{
  systemd.tmpfiles.rules = [
    "d /usr/sbin 0755 root root -"
    "L+ /usr/sbin/useradd - - - - ${pkgs.shadow}/bin/useradd"
    "L+ /usr/sbin/usermod - - - - ${pkgs.shadow}/bin/usermod"
    "L+ /usr/sbin/groupadd - - - - ${pkgs.shadow}/bin/groupadd"
    "L+ /usr/sbin/nologin - - - - ${pkgs.shadow}/bin/nologin"
    "L+ /usr/bin/id - - - - ${pkgs.coreutils}/bin/id"
    "L+ /usr/bin/find - - - - ${pkgs.findutils}/bin/find"
    "L+ /usr/bin/chmod - - - - ${pkgs.coreutils}/bin/chmod"
    "L+ /usr/bin/chgrp - - - - ${pkgs.coreutils}/bin/chgrp"
    "L+ /usr/bin/sh - - - - ${pkgs.bash}/bin/sh"
    "L+ /usr/bin/tar - - - - ${pkgs.gnutar}/bin/tar"
    "L+ /usr/bin/git - - - - ${pkgs.git}/bin/git"
  ];

  users.groups.nouride.gid = 994;
  users.groups.nr-agents.gid = 993;
  users.groups.nr-creds.gid = 992;

  users.users.nouride = {
    uid = 996;
    isSystemUser = true;
    group = "nouride";
    home = "${dir}/.nouride/home";
    shell = "/run/current-system/sw/bin/nologin";
  };

  systemd.services.nouride = {
    description = "Nouride multi-agent runtime";
    documentation = [ "https://github.com/nouverse/nouride" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ "/run/current-system/sw" ];

    unitConfig = {
      StartLimitBurst = 5;
      StartLimitIntervalSec = 120;
    };

    environment = {
      NOURIDE_SERVICE_KIND = "systemd";
      NOURIDE_CGROUP = "delegated";
      HOME = "${dir}/.nouride/home";
    };

    serviceConfig = {
      Type = "simple";
      User = "nouride";
      WorkingDirectory = dir;
      UMask = "0027";

      ExecStartPre = [
        (
          "-/bin/sh -c 'd=\"/srv/nouride\"; p=\"$$d/.nouride-pending-update\"; "
          + "[ -f \"$$p\" ] || exit 0; "
          + "n=$$(( $$(cat \"$$p.attempts\" 2>/dev/null || echo 0) + 1 )); echo \"$$n\" > \"$$p.attempts\"; "
          + "[ \"$$n\" -le 3 ] && exit 0; "
          + "for f in nouride dashboard skills frontend run config.example.toml; do "
          + "[ -e \"$$d/.nouride-previous/$$f\" ] || continue; rm -rf \"$$d/$$f.failed\"; "
          + "[ -e \"$$d/$$f\" ] && mv \"$$d/$$f\" \"$$d/$$f.failed\"; "
          + "mv \"$$d/.nouride-previous/$$f\" \"$$d/$$f\"; done; "
          + "mv \"$$p\" \"$$d/.nouride-rolled-back\"; rm -f \"$$p.attempts\"; "
          + "echo \"nouride: the update did not come up; restored the previous version\" >&2; exit 0'"
        )
      ];
      ExecStart = "${dir}/nouride start";
      EnvironmentFile = [
        "${dir}/.env"
        "-/etc/nouride/nouride.env"
      ];

      Restart = "always";
      RestartSec = 5;
      TimeoutStopSec = 45;
      KillSignal = "SIGTERM";
      KillMode = "mixed";

      MemoryHigh = "80%";
      OOMPolicy = "continue";
      Delegate = "yes";

      NoNewPrivileges = true;
      TemporaryFileSystem = [
        "/tmp:size=1073741824,mode=1777"
        "/var/tmp:size=268435456,mode=1777"
      ];
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = [ dir ];
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = "private";
      RestrictSUIDSGID = true;
      RestrictNamespaces = true;
      LockPersonality = true;
      CapabilityBoundingSet = "";
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
      RestrictRealtime = true;

      StandardOutput = "journal";
      StandardError = "journal";
      SyslogIdentifier = "nouride";
    };
  };

  systemd.sockets.nouride-run = {
    description = "Nouride agents' commands (socket)";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "/run/nouride-run.sock" ];
    socketConfig = {
      SocketUser = "root";
      SocketGroup = "nouride";
      SocketMode = "0660";
      Accept = "yes";
      RemoveOnStop = "yes";
      MaxConnections = 64;
    };
  };

  systemd.services."nouride-run@" = {
    description = "Nouride agent command";
    path = [ "/run/current-system/sw" ];
    serviceConfig = {
      Type = "simple";
      ExecStart =
        "/usr/local/lib/nouride-run/nouride-run serve "
        + "--workspace ${dir}/.nouride/workspace "
        + "--reads ${dir}/.nouride/agents --reads ${dir}/.nouride/jobs "
        + "--reads ${dir}/.nouride/attachments --reads ${dir}/.nouride/tool-output "
        + "--credentials ${dir}/.nouride/credentials --service-user nouride";
      StandardInput = "socket";
      StandardOutput = "socket";
      StandardError = "journal";
      SyslogIdentifier = "nouride-run";
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = [
        "/etc"
        "-${dir}/.nouride/workspace"
        "-${dir}/.nouride/agents"
        "-${dir}/.nouride/jobs"
        "-${dir}/.nouride/attachments"
        "-${dir}/.nouride/tool-output"
        "-${dir}/.nouride/credentials"
      ];
      CapabilityBoundingSet = [
        "CAP_SETUID"
        "CAP_SETGID"
        "CAP_CHOWN"
        "CAP_FOWNER"
        "CAP_FSETID"
        "CAP_DAC_OVERRIDE"
        "CAP_DAC_READ_SEARCH"
        "CAP_KILL"
        "CAP_SYS_PTRACE"
        "CAP_SYS_ADMIN"
        "CAP_SYS_CHROOT"
      ];
      RestrictNamespaces = "mnt";
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
      LockPersonality = true;
      RestrictRealtime = true;
    };
  };
}
