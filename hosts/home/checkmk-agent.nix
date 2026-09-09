# T12 (txtsamu/claude-research#20): Checkmk host-monitoring agent on home.
#
# Not the checkmk *app* (that's already on home's k3s from T14, serving
# monitor.lan) - this is the per-host agent that reports `home`'s own
# system metrics (CPU/mem/disk/etc.) to that same server, same as the
# `warp` host entry it replaces.
#
# warp-vm's setup is two cooperating pieces, both faithfully replicated
# here rather than reinvented:
#   - check_mk_agent: a plain, mostly-portable bash script (2.3k lines,
#     stock Checkmk agent, no local/custom plugins on warp-vm to port)
#     that gathers the actual metrics. Socket-activated per Checkmk's own
#     convention: a Unix socket (Accept=true) feeds each connection into
#     a fresh `check_mk_agent` run, plus a standing root service for
#     "async" (slow/background) sections.
#   - cmk-agent-ctl: the Checkmk 2.x agent controller, a statically
#     linked Rust binary (confirmed via `ldd` - "statically linked", so
#     none of T9/T11's NixOS-FHS-dynamic-linking problems apply here) that
#     listens on TCP 6556 and bridges to the Unix socket above.
#     warp-vm's copy runs in "legacy pull" mode (an
#     `allow-legacy-pull` marker file, no TLS registration) - matches
#     every other host in Checkmk's inventory (plain IP-based `cmk-agent`
#     tag, no per-host registration secret to migrate).
#
# Both binaries are fetched from the Checkmk *server's* own built-in
# agent-download endpoint (http://monitor.lan/cmk/check_mk/agents/...)
# rather than vendored into this repo - guarantees an exact version
# match with the server by construction, and confirmed byte-identical
# (sha256) against warp-vm's installed copies before writing this.
{ pkgs, ... }:
let
  checkMkAgentSrc = pkgs.fetchurl {
    url = "http://monitor.lan/cmk/check_mk/agents/check_mk_agent.linux";
    hash = "sha256-MOK9T8Dc2GBTGudkNk9+w46/PrvNwVkoEfilwvLgqeU=";
  };

  # Only local change from upstream: the shebang. Debian's package
  # assumes /bin/bash exists at a fixed FHS path; NixOS has no such
  # path, so point it at the real store path instead. Everything else
  # in the script resolves commands via PATH (confirmed by grepping for
  # hardcoded /usr,/bin,/sbin paths beforehand - only the shebang and an
  # `inpath timeout` check turned up, and the latter is already
  # PATH-based), so this is the only edit needed.
  checkMkAgent = pkgs.runCommand "check_mk_agent" { } ''
    cp ${checkMkAgentSrc} $out
    chmod +w $out
    sed -i '1s|^#!/bin/bash|#!${pkgs.bash}/bin/bash|' $out
    chmod +x $out
  '';

  cmkAgentCtl = pkgs.fetchurl {
    url = "http://monitor.lan/cmk/check_mk/agents/linux/cmk-agent-ctl";
    # `executable = true` makes fetchurl hash the file recursively (NAR
    # mode, includes the exec bit) rather than as flat content, so this
    # doesn't match a plain `sha256sum` of the downloaded bytes (that
    # flat hash - MOK9T8...->  no, ptZFFM...==  - was verified byte-
    # identical to warp-vm's installed copy beforehand; this is nix's
    # own recursive-NAR hash of that same content, taken from its first
    # build's error output).
    hash = "sha256-y4r1peilcedbvNGQAaJNdFSYj+02tDfTYlg3pcMxSqU=";
    executable = true;
  };
in
{
  users.groups.cmk-agent = { };
  users.users.cmk-agent = {
    isSystemUser = true;
    group = "cmk-agent";
    # Real bug hit standing this up: cmk-agent-ctl resolves its config
    # (cmk-agent-ctl.toml) and connection-registry (registered_connections.json,
    # pre_configured_connections.json) paths relative to the running
    # user's *home directory*, not a hardcoded /var/lib/cmk-agent path -
    # confirmed via `RUST_LOG=debug`, which showed it silently reading
    # (and finding nothing at) /var/empty/registered_connections.json.
    # NixOS system users default to /var/empty; warp-vm's Debian package
    # sets this user's home to /var/lib/cmk-agent explicitly (confirmed
    # via `getent passwd`), which is what makes all the state files below
    # actually get found.
    home = "/var/lib/cmk-agent";
  };

  # Placed at the same literal FHS paths Checkmk's own binaries assume
  # (cmk-agent-ctl doesn't take a configurable state-dir flag - it's
  # compiled to look at /var/lib/cmk-agent). NixOS's root is a normal
  # writable filesystem here, so this is no different from any other
  # tmpfiles-managed directory/symlink.
  systemd.tmpfiles.rules = [
    "L+ /usr/bin/check_mk_agent - - - - ${checkMkAgent}"
    "L+ /usr/bin/cmk-agent-ctl - - - - ${cmkAgentCtl}"
    "d /usr/lib/check_mk_agent/plugins 0755 root root -"
    "d /usr/lib/check_mk_agent/local 0755 root root -"
    "d /etc/check_mk 0755 root root -"
    "d /var/lib/check_mk_agent 0755 root root -"
    "d /var/log/check_mk_agent 0755 root root -"
    "d /var/lib/cmk-agent 0750 cmk-agent cmk-agent -"
    # Enables cmk-agent-ctl's legacy (unregistered, unencrypted) pull
    # mode - matches every other host in Checkmk's inventory, none of
    # which use TLS registration. Content doesn't matter (cmk-agent-ctl
    # only checks for the file's existence), an empty file is fine.
    "f /var/lib/cmk-agent/allow-legacy-pull 0644 cmk-agent cmk-agent -"
    # Real bug hit standing this up: without this file, `cmk-agent-ctl
    # daemon` starts and stays "active (running)" - no crash, no error
    # logged - but never actually binds port 6556. warp-vm's copy of
    # this file holds the (registration-free) connection-state schema
    # cmk-agent-ctl expects to find on disk; it needs to exist, even
    # with all three keys empty, for the daemon to proceed to opening
    # its pull listener.
    # `F` (not `f`) - the empty file this same rule created in the
    # previous, broken activation won't get overwritten by a mere `f`
    # (which only sets content on first creation); `F` always
    # (re)writes the given content.
    "F /var/lib/cmk-agent/registered_connections.json 0600 cmk-agent cmk-agent - {\"push\":{},\"pull\":{},\"pull_imported\":[]}"
  ];

  systemd.sockets.check-mk-agent = {
    description = "Local Checkmk agent socket";
    listenStreams = [ "/run/check-mk-agent.socket" ];
    socketConfig = {
      SocketUser = "cmk-agent";
      SocketMode = "0240";
      Accept = true;
    };
    wantedBy = [ "sockets.target" ];
  };

  # Template unit: systemd spawns one instance per connection accepted
  # on the socket above (Accept=true on the paired .socket unit).
  systemd.services."check-mk-agent@" = {
    description = "Checkmk agent";
    environment = {
      MK_RUN_ASYNC_PARTS = "false";
      MK_READ_REMOTE = "true";
    };
    # warp-vm's Debian image has /usr/bin/python3 on the default PATH,
    # which the agent script auto-detects and reports as
    # `FailedPythonReason: ` (empty = found). Confirmed via a live raw
    # socket read that home reported "No suitable python installation
    # found" without this - a real capability gap vs. warp-vm (matters
    # if any Python-based local/plugin script is ever added later, even
    # though neither host has one today).
    path = [ pkgs.python3 ];
    serviceConfig = {
      ExecStart = "-${checkMkAgent}";
      Type = "simple";
      User = "root";
      StandardInput = "socket";
    };
  };

  # Standing root service for slow/background ("async") sections -
  # matches warp-vm's check-mk-agent-async.service exactly.
  systemd.services.check-mk-agent-async = {
    description = "Checkmk agent - Asynchronous background tasks";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      MK_RUN_SYNC_PARTS = "false";
      MK_LOOP_INTERVAL = "60";
    };
    path = [ pkgs.python3 ];
    serviceConfig = {
      ExecStart = checkMkAgent;
      Type = "simple";
      User = "root";
    };
  };

  # The actual TCP listener (port 6556) - bridges to the Unix socket
  # above. Statically linked, so no NixOS FHS/dynamic-linking wrapper
  # needed (unlike T9/T11's finds).
  systemd.services.cmk-agent-ctl-daemon = {
    description = "Checkmk agent controller daemon";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${cmkAgentCtl} daemon";
      Type = "simple";
      User = "cmk-agent";
      Restart = "on-failure";
      UMask = "0077";
    };
  };

  networking.firewall.allowedTCPPorts = [ 6556 ];
}
