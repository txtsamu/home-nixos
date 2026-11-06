# tg-notify: deliver text (and MEDIA: attachments) to one Telegram chat.
#
# Used by hosts/home/scheduled-jobs.nix (packaged with writePython3Bin, so
# there is no shebang here). Standard library only.
#
#   tg-notify [--title TITLE] [--plain] [--no-media] CHAT_ID [TEXT]
#
# TEXT defaults to stdin. The bot token is read ONLY from the systemd
# credential "telegram-token" ($CREDENTIALS_DIRECTORY/telegram-token); it is
# never taken from the command line or the environment and is never printed.
#
# Behaviour:
#   - text is split into messages of at most 4000 UTF-16 units (Telegram's
#     limit is 4096), preferably at a newline;
#   - light Markdown (**bold**, `code`, ``` blocks, # headings, [t](url)) is
#     rendered as Telegram HTML; if Telegram rejects the markup (HTTP 400)
#     the same chunk is re-sent as plain text;
#   - lines of the form "MEDIA:/abs/path" are removed from the text and the
#     file is uploaded afterwards with sendDocument (the convention the
#     Hermes cron scripts use);
#   - 429 / 5xx / network errors are retried a few times.
#
# Exit status: 0 delivered, 2 usage error, 3 no usable token (warning
# printed, nothing sent), 4 delivery failed.
import argparse
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import uuid

API_BASE = os.environ.get("TG_NOTIFY_API_BASE", "https://api.telegram.org").rstrip("/")
LIMIT = 4000
EXIT_USAGE, EXIT_NO_TOKEN, EXIT_FAILED = 2, 3, 4
MEDIA_RE = re.compile(r"^[ \t]*MEDIA:[ \t]*(\S.*?)[ \t]*$", re.M)


def log(msg):
    print("tg-notify: " + msg, file=sys.stderr)


def read_token():
    cred_dir = os.environ.get("CREDENTIALS_DIRECTORY")
    if not cred_dir:
        log("WARNING: no systemd credential directory; message NOT delivered")
        return None
    try:
        with open(os.path.join(cred_dir, "telegram-token"), encoding="utf-8") as fh:
            token = fh.read().strip()
    except OSError:
        token = ""
    if not token:
        log(
            "WARNING: Telegram bot token is empty or missing (credential "
            "telegram-token); message NOT delivered. Put the token in the "
            "credential file named in hosts/home/scheduled-jobs.nix."
        )
        return None
    if not re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]+", token):
        log("WARNING: Telegram bot token has an unexpected format; message NOT delivered")
        return None
    return token


def utf16_len(s):
    return len(s.encode("utf-16-le", errors="surrogatepass")) // 2


def split_text(text, limit=LIMIT):
    chunks = []
    rest = text
    while rest:
        if utf16_len(rest) <= limit:
            chunks.append(rest)
            break
        units, cut = 0, len(rest)
        for i, ch in enumerate(rest):
            units += 2 if ord(ch) > 0xFFFF else 1
            if units > limit:
                cut = i
                break
        window = rest[:cut]
        pos = window.rfind("\n")
        if pos < cut // 2:
            pos = window.rfind(" ")
        if pos < cut // 2:
            pos = cut
        chunk = rest[:pos].rstrip()
        if chunk:
            chunks.append(chunk)
        rest = rest[pos:].lstrip("\n ")
    return chunks


def md_to_html(text):
    out = []
    parts = re.split(r"(```.*?```|`[^`\n]+`)", text, flags=re.S)
    for i, part in enumerate(parts):
        if i % 2:
            if part.startswith("```"):
                body = re.sub(r"^```[^\n]*\n?", "", part)[:-3].rstrip("\n")
                out.append("<pre>" + html.escape(body, quote=False) + "</pre>")
            else:
                out.append("<code>" + html.escape(part[1:-1], quote=False) + "</code>")
            continue
        s = html.escape(part, quote=False)
        s = re.sub(r"^#{1,6}[ \t]+(.+?)[ \t]*$", r"<b>\1</b>", s, flags=re.M)
        s = re.sub(r"\*\*([^*\n]+?)\*\*", r"<b>\1</b>", s)
        s = re.sub(
            r"\[([^\]\n]+)\]\((https?://[^)\s\"]+)\)", r'<a href="\2">\1</a>', s
        )
        out.append(s)
    return "".join(out)


class Telegram:
    def __init__(self, token):
        self.token = token

    def call(self, method, body, content_type, attempts=4):
        """POST to the Bot API. Returns (http_status, description)."""
        url = "%s/bot%s/%s" % (API_BASE, self.token, method)
        status, desc = 0, "no response"
        for attempt in range(attempts):
            req = urllib.request.Request(
                url, data=body, headers={"Content-Type": content_type}, method="POST"
            )
            retry_after = 0
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    return resp.status, "ok"
            except urllib.error.HTTPError as exc:
                status = exc.code
                try:
                    payload = json.loads(exc.read().decode("utf-8", "replace"))
                    desc = str(payload.get("description", "error"))
                    retry_after = int(
                        payload.get("parameters", {}).get("retry_after", 0) or 0
                    )
                except (ValueError, AttributeError, TypeError):
                    desc = "HTTP %d" % exc.code
                if status != 429 and status < 500:
                    return status, desc
            except (urllib.error.URLError, OSError, TimeoutError) as exc:
                # str(exc) never contains the URL for these, so no token leak.
                status, desc = 0, type(exc).__name__
            if attempt + 1 < attempts:
                time.sleep(min(max(retry_after, 2 ** (attempt + 1)), 60))
        return status, desc

    def send_message(self, chat, text, parse_mode=None):
        payload = {"chat_id": chat, "text": text, "disable_web_page_preview": True}
        if parse_mode:
            payload["parse_mode"] = parse_mode
        body = json.dumps(payload).encode("utf-8")
        return self.call("sendMessage", body, "application/json")

    def send_document(self, chat, path):
        boundary = uuid.uuid4().hex
        name = os.path.basename(path).replace('"', "")
        with open(path, "rb") as fh:
            data = fh.read()
        head = (
            '--%s\r\nContent-Disposition: form-data; name="chat_id"\r\n\r\n%s\r\n'
            '--%s\r\nContent-Disposition: form-data; name="document"; filename="%s"\r\n'
            "Content-Type: application/octet-stream\r\n\r\n"
        ) % (boundary, chat, boundary, name)
        body = head.encode("utf-8") + data + ("\r\n--%s--\r\n" % boundary).encode()
        return self.call(
            "sendDocument", body, "multipart/form-data; boundary=" + boundary
        )


def main():
    ap = argparse.ArgumentParser(description="Send text/attachments to a Telegram chat")
    ap.add_argument("chat_id")
    ap.add_argument("text", nargs="?", help="message text (default: read stdin)")
    ap.add_argument("--title", default="", help="first line of the first message")
    ap.add_argument("--plain", action="store_true", help="no Markdown rendering")
    ap.add_argument("--no-media", action="store_true", help="do not treat MEDIA: lines")
    args = ap.parse_args()

    if not re.fullmatch(r"-?[0-9]+", args.chat_id):
        log("chat id must be a number")
        return EXIT_USAGE
    text = args.text if args.text is not None else sys.stdin.read()
    text = text.strip()

    media = []
    if not args.no_media:
        for m in MEDIA_RE.finditer(text):
            media.append(os.path.expanduser(m.group(1)))
        if media:
            text = re.sub(r"\n{3,}", "\n\n", MEDIA_RE.sub("", text)).strip()

    chunks = split_text(text) if text else []
    if args.title:
        if chunks:
            chunks[0] = args.title + "\n\n" + chunks[0]
        else:
            chunks = [args.title]
    if not chunks and not media:
        return 0

    token = read_token()
    if token is None:
        return EXIT_NO_TOKEN
    tg = Telegram(token)
    failed = False

    for idx, chunk in enumerate(chunks):
        status, desc = 0, ""
        if not args.plain:
            status, desc = tg.send_message(args.chat_id, md_to_html(chunk), "HTML")
        if args.plain or status == 400:
            status, desc = tg.send_message(args.chat_id, chunk)
        if status != 200:
            log("sendMessage part %d/%d failed: %s %s" % (idx + 1, len(chunks), status, desc))
            failed = True

    for path in media:
        if not os.path.isfile(path):
            log("attachment not found: " + os.path.basename(path))
            tg.send_message(args.chat_id, "(attachment missing: %s)" % os.path.basename(path))
            failed = True
            continue
        try:
            status, desc = tg.send_document(args.chat_id, path)
        except OSError as exc:
            status, desc = 0, type(exc).__name__
        if status != 200:
            log("sendDocument %s failed: %s %s" % (os.path.basename(path), status, desc))
            failed = True

    return EXIT_FAILED if failed else 0


if __name__ == "__main__":
    sys.exit(main())
