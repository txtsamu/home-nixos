# Declarative provisioning for the out-of-store app artifacts (hermes,
# proxmox-mcp-plus, tiktok-bot, headroom-proxy, camofox-browser).
#
# Before this module, /opt/* and /root/camofox-browser were placed by hand
# (T7-T11) and the units only pointed at them - a reinstall from this flake
# gave you units that crash-loop. Two kinds of oneshot now own them:
#
#   provision-src-<name>   git clone (+ local patch, + post step) when the
#                          directory is missing. A no-op on an existing
#                          checkout - never touches a live tree, so
#                          `hermes update` etc. keep working as before.
#
#   provision-venv-<name>  uv venv on the *Nix* python313. Healthy venv
#                          (base interpreter == this generation's python):
#                          snapshot `uv pip freeze` to
#                          /var/lib/provision-venvs/<name>.lock and exit.
#                          Missing, or base python changed (nixpkgs bump):
#                          rebuild from that snapshot (fallback: the lock
#                          committed under ./venvs/), --no-deps so the exact
#                          pinned set comes back, rolling back to the old
#                          venv if the install fails.
#
# Why the python check matters: the venvs symlink to one specific
# /nix/store python. With nix.gc enabled (configuration.nix), a nixpkgs
# bump would otherwise leave them pointing at a garbage-collected
# interpreter. Referencing `python` in these scripts also keeps the current
# one in the system closure, i.e. GC-rooted.
#
# The app units only `wants` their provisioners (not `requires`), so a
# failed provision - e.g. no network at boot - never blocks an already-
# working service from starting.
#
# Not covered (state, not code - restore from backup): /root/.hermes,
# tiktok-bot's cookies/watchlist/sqlite, ~moo/.headroom, evomem's iSCSI LUN.
{ lib, pkgs, ... }:
let
  python = pkgs.python313;
  uv = "${pkgs.uv}/bin/uv";
  lockDir = "/var/lib/provision-venvs";

  sources = {
    hermes = {
      dir = "/opt/hermes-source";
      # Same remote layout as the live checkout: origin = upstream (what
      # `hermes update` pulls from), fork = txtsamu's fork.
      url = "https://github.com/NousResearch/hermes-agent.git";
      rev = "9e6f02538e9594978c569b31fadbf4ea532dad27";
      post = "git remote add fork https://github.com/txtsamu/hermes-agent.git && ${pkgs.nodejs_22}/bin/npm ci --no-audit --no-fund";
    };
    camofox = {
      dir = "/root/camofox-browser";
      url = "https://github.com/jo-inc/camofox-browser.git";
      rev = "af3a2505fc3853e976ad261b2ca0cfc445054d33";
      patch = ./patches/camofox-browser-local.patch;
      # npm ci + the Camoufox browser download (~1.2G into
      # /root/.cache/camoufox) - both need an FHS env, same as the service.
      post = "${pkgs.steam-run}/bin/steam-run ${pkgs.nodejs_22}/bin/npm ci --no-audit --no-fund && ${pkgs.steam-run}/bin/steam-run ${pkgs.nodejs_22}/bin/npx camoufox-js fetch";
    };
    tiktok-bot = {
      dir = "/opt/tiktok-bot";
      # Private repo: a fresh clone needs GitHub credentials that this host
      # doesn't hold, so on a reinstall this unit fails loudly - clone it by
      # hand (or restore from backup), then `systemctl restart
      # provision-src-tiktok-bot` applies nothing further since the dir exists.
      url = "https://github.com/txtsamu/tiktok-bot.git";
      rev = "a3e7f1eb03adb1e60f6b428c0d9767760351d68b";
      patch = ./patches/tiktok-bot-local.patch;
    };
  };

  venvs = {
    hermes = {
      path = "/opt/hermes-venv";
      lock = ./venvs/hermes.txt; # contains `-e file:///opt/hermes-source`
      after = [ "provision-src-hermes.service" ];
    };
    proxmox = {
      path = "/opt/proxmox-venv";
      lock = ./venvs/proxmox.txt;
    };
    headroom = {
      path = "/opt/headroom-proxy/venv";
      lock = ./venvs/headroom.txt;
    };
    tiktok-bot = {
      path = "/opt/tiktok-bot-venv";
      lock = ./venvs/tiktok-bot.txt;
      after = [ "provision-src-tiktok-bot.service" ];
      # f2 DeviceIdManager fallback fix, i.e. the tiktok-bot repo's
      # patches/f2-device-id-manager-fallback.patch. Done with sed rather than
      # `patch`: that script hardcodes python3.11, and f2's utils.py ships
      # with CRLF line endings, which makes `patch` reject the hunk.
      postInstall = ''
        ${pkgs.gnused}/bin/sed -i \
          '/except Exception as e:/{n;s/_MSTOKEN = TokenManager.gen_real_msToken()/_MSTOKEN = TokenManager.gen_false_msToken()/}' \
          "$venv"/lib/python3*/site-packages/f2/apps/tiktok/utils.py
      '';
    };
  };

  mkSrc = name: s: {
    description = "Provision ${name} source checkout at ${s.dir}";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.git
      pkgs.coreutils
    ];
    environment.HOME = "/root";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      dir=${s.dir}
      if [ -e "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
        exit 0
      fi
      git clone ${s.url} "$dir"
      git -C "$dir" checkout -q ${s.rev}
      ${lib.optionalString (s ? patch) ''git -C "$dir" apply ${s.patch}''}
      ${lib.optionalString (s ? post) ''cd "$dir" && ${s.post}''}
    '';
  };

  mkVenv = name: v: {
    description = "Provision ${name} Python venv at ${v.path}";
    after = [ "network-online.target" ] ++ (v.after or [ ]);
    wants = [ "network-online.target" ] ++ (v.after or [ ]);
    path = [ pkgs.coreutils ];
    environment = {
      UV_CACHE_DIR = "/var/cache/provision-venvs";
      UV_PYTHON_DOWNLOADS = "never";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      venv=${v.path}
      snapshot=${lockDir}/${name}.lock
      mkdir -p ${lockDir}

      have=$(readlink -f "$venv/bin/python" 2>/dev/null || true)
      case "$have" in
        ${python}/*)
          # Healthy: refresh the snapshot so a later rebuild restores what's
          # really installed (incl. `hermes update` / manual pip changes).
          if ${uv} pip freeze --python "$venv/bin/python" > "$snapshot.tmp" && [ -s "$snapshot.tmp" ]; then
            mv "$snapshot.tmp" "$snapshot"
          else
            rm -f "$snapshot.tmp"
          fi
          exit 0
          ;;
      esac

      lock=$snapshot
      [ -s "$lock" ] || lock=${v.lock}
      echo "(re)building $venv on ${python} from $lock"

      mkdir -p "$(dirname "$venv")"
      rm -rf "$venv.old"
      if [ -e "$venv" ]; then mv "$venv" "$venv.old"; fi
      if ${uv} venv --seed --python ${python}/bin/python3 "$venv" \
        && ${uv} pip install --python "$venv/bin/python" --no-deps -r "$lock" \
        ${lib.optionalString (v ? postInstall) "&& { ${v.postInstall} }"}
      then
        rm -rf "$venv.old"
      else
        echo "venv build failed, restoring previous venv" >&2
        rm -rf "$venv"
        if [ -e "$venv.old" ]; then mv "$venv.old" "$venv"; fi
        exit 1
      fi
    '';
  };
in
{
  systemd.services =
    lib.mapAttrs' (n: s: lib.nameValuePair "provision-src-${n}" (mkSrc n s)) sources
    // lib.mapAttrs' (n: v: lib.nameValuePair "provision-venv-${n}" (mkVenv n v)) venvs
    # Soft-order each app after what it runs from.
    //
      lib.mapAttrs
        (_: deps: {
          wants = deps;
          after = deps;
        })
        {
          hermes-gateway = [ "provision-venv-hermes.service" ];
          hermes-mcp = [ "provision-venv-hermes.service" ];
          proxmox-mcp-plus = [ "provision-venv-proxmox.service" ];
          headroom-proxy = [ "provision-venv-headroom.service" ];
          tiktok-bot = [ "provision-venv-tiktok-bot.service" ];
          camofox-browser = [ "provision-src-camofox.service" ];
        };
}
