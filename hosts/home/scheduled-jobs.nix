# Script-type Hermes cron jobs as plain root systemd timers.
#
# PURPOSE
#   The Telegram bot and cron are moving off Hermes. Hermes keeps running, but
#   its cron jobs get paused, so the eight "no_agent" script jobs (the script
#   IS the job, no LLM) run from here instead: one oneshot service + timer per
#   job, stdout delivered to Telegram by `tg-notify`, mirroring what the
#   Hermes scheduler did (cron/scheduler.py `_run_no_agent_job`,
#   cron/scheduler_script.py `_run_job_script`):
#     - cwd = /root/.hermes/scripts, no stdin, 1 h timeout
#     - *.sh / *.bash run with bash, anything else with the Hermes venv python
#     - stdout (trimmed): empty -> nothing is sent; non-empty -> sent verbatim
#       to the job's chat; a last line that is JSON {"wakeAgent": false} is
#       also silent
#     - non-zero exit / timeout -> one short failure notice to the chat
#     - deliver=local jobs run but never message anybody
#   The three agent jobs (session report, backup autofix, efficiency
#   research) are NOT here.
#
# JOB MAP (Hermes job id -> unit scheduled-job-<name>, in WIB = time.timeZone)
#   8fdeb489eb44  proxmox-backup-status           daily 04:00
#   e023bde2da85  claude-code-session-import      daily 01:00
#   19a4de80a8f4  evomem-claude-sync              every 5 min (feeds evomem)
#   3c8b5d4a784a  camofox-auto-update             Sundays 03:00 (other chat)
#   2cc0bc49ffec  mattpocock-skills-sync          daily 02:00
#   2e735e03ced2  pas-btech-chat-html             06:00 and 18:00
#   8b1593485678  pas-btech-media-safety-archive  every 6 h, deliver=local
#   96694a24d519  research-archive-sync-watchdog  daily 04:45
#
# TELEGRAM CREDENTIAL (created by hand, never in git)
#   The bot token is passed with LoadCredential=telegram-token:
#   /var/lib/scheduled-jobs/telegram-bot-token. tmpfiles creates that file
#   EMPTY (root, 0600) if it does not exist, so the units never fail on a
#   missing credential. Fill it once after deploy:
#       install -m 0600 /dev/null /var/lib/scheduled-jobs/telegram-bot-token
#       printf '%s' '<bot token>' > /var/lib/scheduled-jobs/telegram-bot-token
#   (a bare "123456:ABC..." line; surrounding whitespace is ignored). While it
#   is empty the jobs still run; each run logs "WARNING: ... message NOT
#   delivered" to the journal and the unit stays successful. The token is only
#   handed to tg-notify; the job scripts do not see it.
#
# TELEGRAM CHAT IDS (also by hand, never in git: this repo is public)
#   Jobs name their target chat by alias, `main` or `other`. The aliases are
#   resolved at run time from /var/lib/scheduled-jobs/chat-ids (root, 0600,
#   created empty by tmpfiles), one `alias=<numeric chat id>` per line:
#       printf 'main=<id>\nother=<id>\n' > /var/lib/scheduled-jobs/chat-ids
#   An alias that is missing there means "message NOT delivered" (logged), the
#   job itself still runs.
#
# GOING LIVE: the matching Hermes jobs MUST be paused, or every job runs
#   twice (and the 5-minute evomem sync races itself):
#       hermes cron pause 8fdeb489eb44 e023bde2da85 19a4de80a8f4 \
#           3c8b5d4a784a 2cc0bc49ffec 2e735e03ced2 8b1593485678 96694a24d519
#   (one id at a time if the CLI takes only one). Check afterwards with
#   `systemctl list-timers 'scheduled-job-*'`.
#
# REMOVING IT: delete the import in configuration.nix and this file plus
#   tg-notify.py, switch, then optionally `rm -r /var/lib/scheduled-jobs`.
#   Resume the Hermes jobs with `hermes cron resume <id>` if wanted.
#
# NOT REPLICATED: Hermes redacts secrets from script output before delivery
#   and saves every run under its own cron output directory. Here a run's
#   stdout/stderr go to the journal (`journalctl -u scheduled-job-<name>`)
#   and nothing is redacted. Hermes also sends images as photos; tg-notify
#   sends every MEDIA: file as a document.
{ lib, pkgs, ... }:
let
  scriptsDir = "/root/.hermes/scripts";
  stateDir = "/var/lib/scheduled-jobs";
  tokenFile = "${stateDir}/telegram-bot-token";
  hermesVenv = "/opt/hermes-venv";

  # _DEFAULT_SCRIPT_TIMEOUT in Hermes cron/scheduler.py (no override is set
  # in its config or environment on this host).
  scriptTimeout = 3600;

  # PATH the Hermes gateway (mcp.nix `basePath`) hands its cron scripts: the
  # scripts call bare python3, git, npm, rsync, ssh, kubectl, systemctl.
  jobPath = lib.concatStringsSep ":" [
    "${hermesVenv}/bin"
    "${pkgs.nodejs_22}/bin"
    "/opt/hermes-source/node_modules/.bin"
    "/run/current-system/sw/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
  ];

  tg-notify = pkgs.writers.writePython3Bin "tg-notify" {
    # flake8 style checks are not worth failing a build over.
    doCheck = false;
  } (builtins.readFile ./tg-notify.py);

  runner = pkgs.writeShellApplication {
    name = "scheduled-job-run";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.jq
      pkgs.util-linux
      tg-notify
    ];
    text = ''
      # scheduled-job-run <job-id> <job-name> <script> <chat-id|local>
      # Env (all optional, defaults = production): JOB_SCRIPTS_DIR,
      # JOB_STATE_DIR, JOB_TIMEOUT, JOB_PATH, JOB_PYTHON.
      id=$1
      name=$2
      script=$3
      chat=$4
      scriptsDir=''${JOB_SCRIPTS_DIR:-${scriptsDir}}
      stateDir=''${JOB_STATE_DIR:-${stateDir}}
      timeoutSec=''${JOB_TIMEOUT:-${toString scriptTimeout}}
      jobPath=''${JOB_PATH:-${jobPath}}
      python=''${JOB_PYTHON:-${hermesVenv}/bin/python}

      # One run at a time per job. fd 9 is closed for the script itself so a
      # daemon it leaves behind cannot keep the lock.
      exec 9>"$stateDir/$id.lock"
      if ! flock -n 9; then
        echo "previous run of $name still in progress, skipping this tick"
        exit 0
      fi

      deliver() { # stdin = text; delivery trouble never changes the job result
        if [ "$chat" = local ]; then
          cat >/dev/null
          return 0
        fi
        local drc=0 target=$chat
        if ! [[ $chat =~ ^-?[0-9]+$ ]]; then
          target=$(grep -m1 "^$chat=" "$stateDir/chat-ids" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
          if [ -z "$target" ]; then
            cat >/dev/null
            echo "WARNING: chat alias '$chat' not set in $stateDir/chat-ids, message for $name NOT delivered" >&2
            return 0
          fi
        fi
        tg-notify "$target" || drc=$?
        case $drc in
          0) ;;
          3) echo "WARNING: no Telegram bot token, message for $name NOT delivered" >&2 ;;
          *) echo "WARNING: Telegram delivery for $name failed (tg-notify exit $drc)" >&2 ;;
        esac
      }

      trim() { # python str.strip() on stdin
        local s
        s=$(cat)
        s=''${s#"''${s%%[![:space:]]*}"}
        printf '%s' "''${s%"''${s##*[![:space:]]}"}"
      }

      fail() { # fail <detail> : log, send the short notice, exit 1
        echo "FAILED: $1" >&2
        printf '%s' "⚠️ Cron '$name' failed: $1. Unit scheduled-job-$name, see journalctl -u scheduled-job-$name" | deliver
        exit 1
      }

      path=$(realpath -m -- "$scriptsDir/$script")
      [ -f "$path" ] || fail "Script not found: $path"
      case $script in
        *.sh | *.bash)
          interp=$(export PATH="$jobPath"; command -v bash) || fail "bash not found on PATH"
          ;;
        *) interp=$python ;;
      esac

      cd "$scriptsDir"
      errf=$(mktemp "$stateDir/$id.XXXXXX.err")
      trap 'rm -f "$errf"' EXIT

      rc=0
      out=$(timeout --kill-after=10 "$timeoutSec" \
        env -u CREDENTIALS_DIRECTORY PATH="$jobPath" "$interp" "$path" \
        9>&- 2>"$errf") || rc=$?
      out=$(printf '%s' "$out" | trim)
      err=$(trim <"$errf")

      [ -z "$err" ] || printf '%s\n' "$err" >&2
      [ -z "$out" ] || printf '%s\n' "$out"

      if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 124 ] || { [ "$rc" -eq 137 ] && [ "$SECONDS" -ge "$timeoutSec" ]; }; then
          fail "its script timed out after ''${timeoutSec}s"
        fi
        # Same shape as Hermes: one line, whitespace squeezed, 180 chars max.
        detail=$(printf 'Script exited with code %s%s%s' "$rc" \
          "''${err:+ stderr: $err}" "''${out:+ stdout: $out}" | tr -s '[:space:]' ' ')
        detail=''${detail:0:177}
        fail "$detail"
      fi

      [ -n "$out" ] || exit 0
      last=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 1 || true)
      if printf '%s' "$last" | jq -e 'type == "object" and .wakeAgent == false' >/dev/null 2>&1; then
        echo "wakeAgent=false gate, nothing to deliver"
        exit 0
      fi
      printf '%s' "$out" | deliver
    '';
  };

  # chat: alias (see chat-ids above) of the Telegram chat receiving stdout
  # (null = deliver=local).
  # calendar: OnCalendar in the host time zone; null = every 5 minutes.
  jobs = {
    proxmox-backup-status = {
      id = "8fdeb489eb44";
      script = "proxmox_backup_report.py";
      chat = "main";
      calendar = "*-*-* 04:00:00";
    };
    claude-code-session-import = {
      id = "e023bde2da85";
      script = "claude_import_watchdog.sh";
      chat = "main";
      calendar = "*-*-* 01:00:00";
    };
    evomem-claude-sync = {
      id = "19a4de80a8f4";
      script = "pull_evomem_sync_cron.py";
      chat = "main";
      calendar = null;
    };
    camofox-auto-update = {
      id = "3c8b5d4a784a";
      script = "camofox_auto_update.sh";
      chat = "other";
      calendar = "Sun *-*-* 03:00:00";
    };
    mattpocock-skills-sync = {
      id = "2cc0bc49ffec";
      script = "mattpocock_skills_sync.py";
      chat = "main";
      calendar = "*-*-* 02:00:00";
    };
    pas-btech-chat-html = {
      id = "2e735e03ced2";
      script = "gowa_chat_digest.sh";
      chat = "main";
      calendar = "*-*-* 06,18:00:00";
    };
    pas-btech-media-safety-archive = {
      id = "8b1593485678";
      script = "gowa_archive.sh";
      chat = null;
      calendar = "*-*-* 00/6:00:00";
    };
    research-archive-sync-watchdog = {
      id = "96694a24d519";
      script = "sync_hermes_research.sh";
      chat = "main";
      calendar = "*-*-* 04:45:00";
    };
  };

  unitName = name: "scheduled-job-${name}";
in
{
  environment.systemPackages = [ tg-notify ];

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 root root -"
    # Placeholder so LoadCredential below always has a file to load; the
    # real content is written by hand (see the header comment).
    "f ${tokenFile} 0600 root root -"
    "f ${stateDir}/chat-ids 0600 root root -"
  ];

  systemd.services = lib.mapAttrs' (
    name: job:
    lib.nameValuePair (unitName name) {
      description = "Hermes cron job ${name} (${job.id}) as a systemd job";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # Never restart a run that is in progress because of a rebuild switch.
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        WorkingDirectory = scriptsDir;
        ExecStart = lib.escapeShellArgs [
          "${runner}/bin/scheduled-job-run"
          job.id
          name
          job.script
          (if job.chat == null then "local" else job.chat)
        ];
        # Hermes' script timeout plus room for the failure notice.
        TimeoutStartSec = scriptTimeout + 300;
        LoadCredential = "telegram-token:${tokenFile}";
        Environment = [
          "HOME=/root"
          "USER=root"
          "LOGNAME=root"
          "PATH=${jobPath}"
          "VIRTUAL_ENV=${hermesVenv}"
          "HERMES_HOME=/root/.hermes"
          "HERMES_DISABLE_LAZY_INSTALLS=1"
        ];
        # Light sandbox: these are root maintenance scripts that restart
        # services, write under /root and /opt and talk to the network, so
        # only the kernel-facing knobs are closed.
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
      };
    }
  ) jobs;

  systemd.timers = lib.mapAttrs' (
    name: job:
    lib.nameValuePair (unitName name) {
      description = "Schedule for Hermes cron job ${name} (${job.id})";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        AccuracySec = "1s";
      }
      // (
        if job.calendar == null then
          {
            OnBootSec = "2min";
            OnUnitActiveSec = "5min";
          }
        else
          {
            OnCalendar = job.calendar;
            # Do not replay missed runs after downtime/boot.
            Persistent = false;
          }
      );
    }
  ) jobs;
}
