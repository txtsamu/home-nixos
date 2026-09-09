# T10 (txtsamu/claude-research#18): tiktok-bot on home.
#
# `/opt/tiktok-bot` is a fresh `git clone` of the real repo (private -
# github.com/txtsamu/tiktok-bot) as the ticket asked, not a verbatim copy
# like evomem/camofox - but the repo itself was ~1361 lines of real,
# working fixes behind what's actually running, never pushed from
# warp-vm (no VCS backup at all until this ticket: committed + pushed
# from warp-vm's live tiktok_bot.py before cloning, see the ticket's
# resolution comment). Runtime state (10 cookie files, watchlist.json,
# watchdb.sqlite3, scripts/, ig_sessions/) copied in separately -
# .gitignored, not part of the repo.
#
# Own dedicated venv (/opt/tiktok-bot-venv), not sharing home's existing
# /opt/hermes-venv (T8) - warp-vm's shared-venv setup is exactly what
# caused T8's documented f2/websockets version conflict in the first
# place (f2 wants websockets<13, hermes wants newer). Three paths
# hardcoded to /opt/hermes-venv in tiktok_bot.py (HERMES_PIP_BIN,
# GALLERY_DL_BIN, YTDLP_BIN) were patched locally on home to point at
# the new venv - a host-specific adaptation, not pushed back to the
# shared repo (warp-vm still genuinely uses /opt/hermes-venv today).
#
# Real bugs hit building the venv:
# - instagrapi's PyPI sdist is missing requirements.txt its own setup.py
#   expects (a packaging bug in the published release, not a pip/NixOS
#   issue) - installed from its GitHub source instead
#   (git+https://github.com/subzeroid/instagrapi.git), which fixed it.
#   Not actually a regression either way: instagrapi isn't installed
#   anywhere on warp-vm right now, so Instagram commands are already
#   non-functional there - this venv has it working, which is strictly
#   better.
# - patches/apply.sh (meant to reapply the f2 DeviceIdManager fallback
#   patch after a venv rebuild) hardcodes a python3.11 site-packages
#   path; this venv is python3.13. Applied the one-line fix directly
#   (gen_real_msToken -> gen_false_msToken in the except block) instead
#   of fighting the script's version assumption.
{ ... }:
{
  fileSystems."/mnt/photos" = {
    device = "192.168.50.10:/mnt/data/photos";
    fsType = "nfs4";
    options = [ "_netdev" "nofail" "x-systemd.automount" "x-systemd.idle-timeout=0" ];
  };

  systemd.services.tiktok-bot = {
    description = "TikTok Bulk Downloader Telegram Bot";
    after = [ "network-online.target" "camofox-browser.service" "mnt-photos.automount" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = "/mnt/photos";
    environment = {
      PYTHONUNBUFFERED = "1";
      # camofox-browser (T9) runs on this same host now - CAMOFOX_URL's
      # own default (http://localhost:9377) already resolves correctly,
      # no override needed.
    };
    serviceConfig = {
      Type = "simple";
      WorkingDirectory = "/opt/tiktok-bot";
      EnvironmentFile = "/run/agenix/camofox-api-key";
      ExecStart = "/opt/tiktok-bot-venv/bin/python3 /opt/tiktok-bot/tiktok_bot.py";
      Restart = "always";
      RestartSec = 10;
    };
  };
}
