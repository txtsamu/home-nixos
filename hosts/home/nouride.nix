# Nouride: the agent daemon from nouverse/nouride, installed by its own installer
# into /srv/nouride and supervised here.
#
# Why the units are written out by hand instead of the ones the installer drops in:
# `install.sh` copies `nouride.service`, `nouride-run.socket` and `nouride-run@.service`
# into /etc/systemd/system and runs `systemctl enable --now nouride`. On NixOS that
# directory is a symlink into the store (`/etc/static/systemd/system`), so the copy
# fails with "Read-only file system" and the daemon is left installed but not started.
# The unit text below is that same file, translated key by key, so nothing about how
# Nouride runs changes on this host: same user, same sandbox, same shutdown order.
#
# The service account and its groups have to be declared even though the installer
# makes them itself: this host runs `users.mutableUsers = false`, so activation
# rewrites /etc/passwd from this file and an account made with `useradd` disappears
# on the next switch (the first attempt at this failed exactly that way, unit and all,
# with status 217/USER). The ids are pinned to the ones the installer picked, which is
# what /srv/nouride is already owned by, so no chown is needed.
#
# The per-agent accounts Nouride makes at run time (nr-<agent>) are wiped the same way.
# It re-makes them when an agent needs one, so a rebuild costs nothing but a chown of
# that agent's folders on its next command.
#
# Upgrades still come from Nouride itself: `nouride update` replaces /srv/nouride/nouride
# and restarts the unit. When the installer's unit template changes in a release,
# `nouride service diff` prints what this file is missing, and the fix is a line here.
{ ... }:
let
  dir = "/srv/nouride";
in
{
  users.groups.nouride.gid = 994;
  # The group an agent's folders are given, so a command running as one agent's user
  # cannot read another's. Root is not in it.
  users.groups.nr-agents.gid = 993;

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
    # Chat gateways and LLM endpoints are all remote, so starting before the network is
    # up just produces a reconnect storm in the log.
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ "/run/current-system/sw" ];

    # Give up after five failures in two minutes, and stay failed: without a limit,
    # Restart=always retries for ever and a config the daemon refuses becomes a silent
    # loop that reads as "still starting". In unitConfig, not serviceConfig: systemd
    # moved these in v230 and ignores them where they used to live.
    unitConfig = {
      StartLimitBurst = 5;
      StartLimitIntervalSec = 120;
    };

    environment = {
      # The systemd unit's own PATH is a bare /usr/bin:/bin, which on NixOS holds nothing:
      # the daemon shells out to find/stat/chown when it makes the shared HOME runnable by
      # each agent, and a bare PATH made that step log "exec: find: not found" and give up.
      PATH = "${dir}/.nouride/bin:${dir}/.nouride/opt/python/bin:/run/current-system/sw/bin:/run/current-system/sw/sbin";
      NOURIDE_SERVICE_KIND = "systemd";
      NOURIDE_CGROUP = "delegated";
      # ProtectHome below makes the real home read-only, so HOME points at the writable
      # directory instead: ssh known_hosts, git config and tool caches live under it.
      HOME = "${dir}/.nouride/home";
    };

    serviceConfig = {
      Type = "simple";
      User = "nouride";
      WorkingDirectory = dir;
      # Nothing it creates is readable by other users unless it says so: the systemd
      # default, 0022, made every file world-readable for the moment before a chmod.
      UMask = "0027";

      # While an update is unconfirmed, count the starts and, on the fourth, put the
      # previous version back (modules/update/confirm.ts). Outside the binary on purpose:
      # a new binary that crashes at once cannot rescue itself.
      ExecStartPre = [
        ("-/bin/sh -c 'd=\"/srv/nouride\"; p=\"$$d/.nouride-pending-update\"; "
          + "[ -f \"$$p\" ] || exit 0; "
          + "n=$$(( $$(cat \"$$p.attempts\" 2>/dev/null || echo 0) + 1 )); echo \"$$n\" > \"$$p.attempts\"; "
          + "[ \"$$n\" -le 3 ] && exit 0; "
          + "for f in nouride dashboard skills frontend run config.example.toml; do "
          + "[ -e \"$$d/.nouride-previous/$$f\" ] || continue; rm -rf \"$$d/$$f.failed\"; "
          + "[ -e \"$$d/$$f\" ] && mv \"$$d/$$f\" \"$$d/$$f.failed\"; "
          + "mv \"$$d/.nouride-previous/$$f\" \"$$d/$$f\"; done; "
          + "mv \"$$p\" \"$$d/.nouride-rolled-back\"; rm -f \"$$p.attempts\"; "
          + "echo \"nouride: the update did not come up; restored the previous version\" >&2; exit 0'")
      ];
      ExecStart = "${dir}/nouride start";
      EnvironmentFile = [ "${dir}/.env" "-/etc/nouride/nouride.env" ];

      Restart = "always";
      RestartSec = 5;
      # In-flight turns are saved on SIGTERM; killing it early loses context.
      TimeoutStopSec = 45;
      KillSignal = "SIGTERM";
      # The signal goes to the daemon alone; it stops its own children in order. The
      # default sends SIGTERM to every process at once, which killed a command a turn
      # was running at the start of the shutdown, and MCP servers before the turns
      # still calling them.
      KillMode = "mixed";

      # Soft ceiling for the daemon and everything it spawns: throttle, never kill.
      # The installer writes 13360332800 bytes, 80% of this host's RAM; the percentage
      # says the same thing and survives a RAM change.
      MemoryHigh = "80%";
      # A command the kernel kills for memory is killed alone: the daemon stays up.
      OOMPolicy = "continue";
      # The daemon splits its own cgroup in two: itself, protected, and what agents run,
      # capped below MemoryHigh, so a command that eats the machine is what dies.
      Delegate = "yes";

      # Hardening. The daemon runs commands on this host by design, which is exactly why
      # the blast radius of the daemon itself should be bounded.
      NoNewPrivileges = true;
      # A tmpfs is RAM, sized from the host's memory, not the container's: a 1.2 GB
      # clone into /tmp is what these two numbers stand in front of.
      TemporaryFileSystem = [
        "/tmp:size=1073741824,mode=1777"
        "/var/tmp:size=268435456,mode=1777"
      ];
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      # The one path it must write: data/ and agents/ live here.
      ReadWritePaths = [ dir ];
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = "private";
      RestrictSUIDSGID = true;
      RestrictNamespaces = true;
      LockPersonality = true;
      # No capabilities, so none can be gained by any path NoNewPrivileges does not
      # already close. An unprivileged account holds none to lose.
      CapabilityBoundingSet = "";
      # Unix (D-Bus, nouride-pkg, ssh-agent), IPv4, IPv6 and netlink, which address
      # lookup and `ip` read through. Raw packet sockets need a capability this account
      # never has, so nothing that worked is closed.
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

  # Where the daemon asks for an agent's command to run as that agent's own user. Only
  # root and the service group may connect, and no agent is in that group, so an agent
  # cannot ask for another agent's user. Each connection starts one nouride-run@ process
  # as root; the rules compiled into that binary decide what it may do.
  systemd.sockets.nouride-run = {
    description = "Nouride agents' commands (socket)";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "/run/nouride-run.sock" ];
    socketConfig = {
      SocketUser = "root";
      SocketGroup = "nouride";
      SocketMode = "0660";
      Accept = "yes";
      # Gone when stopped: the daemon reads "is the helper here" from this file, and one
      # left behind would say ready while every command was refused.
      RemoveOnStop = "yes";
      MaxConnections = 64;
    };
  };

  # One agent's command, started by the socket above. Root, and without the daemon's
  # sandbox, because changing user needs it. Its log: `journalctl -t nouride-run`.
  systemd.services."nouride-run@" = {
    description = "Nouride agent command";
    serviceConfig = {
      Type = "simple";
      ExecStart = "/usr/local/lib/nouride-run/nouride-run serve "
        + "--workspace ${dir}/.nouride/workspace "
        + "--reads ${dir}/.nouride/agents --reads ${dir}/.nouride/jobs "
        + "--reads ${dir}/.nouride/attachments --reads ${dir}/.nouride/tool-output "
        + "--credentials ${dir}/.nouride/credentials --service-user nouride";
      StandardInput = "socket";
      StandardOutput = "socket";
      StandardError = "journal";
      SyslogIdentifier = "nouride-run";
      # Everything but /etc (users and groups) and the folders it gives their owners and
      # groups stays read-only to it. The command it starts is the agent's, and its own
      # user's rights are what decide what that may write.
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      # /etc for users and groups; the rest are the folders it gives their owners and
      # groups. A folder not made yet is skipped (`-`), not a unit that fails to start.
      ReadWritePaths = [
        "/etc"
        "-${dir}/.nouride/workspace"
        "-${dir}/.nouride/agents"
        "-${dir}/.nouride/jobs"
        "-${dir}/.nouride/attachments"
        "-${dir}/.nouride/tool-output"
        "-${dir}/.nouride/credentials"
      ];
      # SYS_PTRACE, SYS_ADMIN and SYS_CHROOT to enter the daemon's mount namespace;
      # FSETID so a folder can be given a setgid bit for a group root is not in.
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
