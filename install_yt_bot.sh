#!/usr/bin/env bash
set -euo pipefail

# ========= pretty print =========
c(){ printf "\033[%sm%s\033[0m\n" "$1" "$2"; }
ok(){ c "32" "✔ $1"; }
info(){ c "36" "➜ $1"; }
warn(){ c "33" "⚠ $1"; }
err(){ c "31" "✖ $1"; }

# ========= root check =========
if [[ $EUID -ne 0 ]]; then
  err "Run as root: sudo bash $0"
  exit 1
fi

# ========= pick run user & home =========
RUN_USER="${SUDO_USER:-$(whoami)}"
RUN_USER_HOME="$(getent passwd "$RUN_USER" | awk -F: '{print $6}')"
[[ -z "${RUN_USER_HOME}" ]] && RUN_USER_HOME="$HOME"

DEFAULT_INSTALL_DIR="${RUN_USER_HOME}/yt-bot"

echo
info "YouTube/Web video downloader bot installer"
echo "Detected user         : $RUN_USER"
echo "Detected user HOME    : $RUN_USER_HOME"
read -r -p "Install directory [${DEFAULT_INSTALL_DIR}]: " INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"

SAVE_DIR="${INSTALL_DIR}/recordings"
BOT_PY="${INSTALL_DIR}/youtube_recorder_bot.py"
SERVICE="/etc/systemd/system/youtube_bot.service"

mkdir -p "${SAVE_DIR}"
chown -R "${RUN_USER}:${RUN_USER}" "${INSTALL_DIR}"

# ========= inputs =========
echo
read -r -p "Enter Telegram BOT TOKEN: " BOT_TOKEN
[[ -z "${BOT_TOKEN}" ]] && { err "Bot token required"; exit 1; }

RCLONE_REMOTE_DEFAULT="onedrive"
RCLONE_FOLDER_DEFAULT="YouTube_Backup"
read -r -p "rclone remote name for OneDrive [${RCLONE_REMOTE_DEFAULT}]: " RCLONE_REMOTE
RCLONE_REMOTE="${RCLONE_REMOTE:-$RCLONE_REMOTE_DEFAULT}"
read -r -p "OneDrive target folder [${RCLONE_FOLDER_DEFAULT}]: " RCLONE_FOLDER
RCLONE_FOLDER="${RCLONE_FOLDER:-$RCLONE_FOLDER_DEFAULT}"

# ========= packages =========
info "APT update & install packages..."
apt-get update -y
apt-get install -y python3 python3-pip yt-dlp ffmpeg rclone curl

info "Install Python libs..."
python3 -m pip install -U pyTelegramBotAPI --break-system-packages >/dev/null

# ========= rclone onedrive config via token JSON =========
if ! rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}:" ; then
  warn "rclone remote '${RCLONE_REMOTE}:' not found. We'll create it."

  cat <<'TIP'

==> On a PC/Mac with a browser:
    1) Install rclone (winget/choco/brew or download)
    2) Run:
         rclone authorize "onedrive"
       - Sign in to Microsoft and allow access
       - Copy the LONG one-line JSON printed in the terminal

==> Paste that JSON below (single line).

TIP
  echo
  read -r -p "Paste OneDrive token JSON: " TOKEN_JSON
  if [[ -z "${TOKEN_JSON}" || "${TOKEN_JSON:0:1}" != "{" ]]; then
    err "Invalid token JSON. Aborting."
    exit 1
  fi

  info "Creating rclone remote '${RCLONE_REMOTE}'..."
  rclone config create "${RCLONE_REMOTE}" onedrive token "${TOKEN_JSON}" drive_type personal >/dev/null
  ok "rclone remote '${RCLONE_REMOTE}:' created."
else
  ok "rclone remote '${RCLONE_REMOTE}:' already exists."
fi

# ensure target folder exists
rclone mkdir "${RCLONE_REMOTE}:/${RCLONE_FOLDER}" >/dev/null || true

# ========= write bot file =========
info "Writing bot to ${BOT_PY}"
cat > "${BOT_PY}" <<PY
# -*- coding: utf-8 -*-
import os, re, json, signal, threading, subprocess, datetime as dt, time, logging
import urllib.parse as urlparse
import telebot

TOKEN = "${BOT_TOKEN}"
SAVE_DIR = "${SAVE_DIR}"
os.makedirs(SAVE_DIR, exist_ok=True)

RCLONE_REMOTE = "${RCLONE_REMOTE}"
REMOTE_DIR = "${RCLONE_FOLDER}"

telebot.logger.setLevel(logging.INFO)
log = logging.getLogger("ytbot"); log.setLevel(logging.INFO)
_handler = logging.StreamHandler()
_handler.setFormatter(logging.Formatter("[%(asctime)s] %(levelname)s - %(message)s"))
log.addHandler(_handler)

bot = telebot.TeleBot(TOKEN)
current_proc = None
current_title = None

def sanitize(name: str) -> str:
    import re as _re
    return _re.sub(r'[\\\\/*?:"<>|]', "", (name or "").strip()) or "video"

def is_m3u8(url: str) -> bool:
    return url.split("?")[0].lower().endswith(".m3u8")

def guess_name_from_url(url: str, default_ext: str="mp4") -> str:
    u = urlparse.urlparse(url); name = os.path.basename(u.path) or "video"
    name = sanitize(name);  return name if "." in name else f"{name}.{default_ext}"

def get_meta(url: str) -> dict:
    raw = subprocess.check_output(["yt-dlp","--dump-json",url])
    return json.loads(raw.decode("utf-8","ignore"))

def is_live(meta: dict) -> bool:
    return bool(meta.get("is_live") or meta.get("live_status")=="is_live")

def yt_dlp_download(url: str):
    tmpl = os.path.join(SAVE_DIR,"%(title)s.%(ext)s")
    cmd = ["yt-dlp","-o",tmpl,"--no-part",url]; log.info("yt-dlp: %s"," ".join(cmd))
    subprocess.run(cmd, check=True)

def ffmpeg_record_from_stream(stream_url: str, title: str) -> str:
    ts = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    outp = os.path.join(SAVE_DIR,f"{sanitize(title)}_{ts}.mp4")
    cmd = ["ffmpeg","-nostdin","-y","-i",stream_url,"-c","copy","-f","mp4",outp]
    log.info("ffmpeg: %s"," ".join(cmd)); subprocess.run(cmd, check=True); return outp

def start_youtube_live(url: str, title: str):
    stream = subprocess.check_output(["yt-dlp","-g",url]).decode().splitlines()[-1]
    ts = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    outp = os.path.join(SAVE_DIR,f"{sanitize(title)}_{ts}.mp4")
    cmd = ["ffmpeg","-nostdin","-y","-i",stream,"-c","copy","-f","mp4",outp]
    log.info("ffmpeg(LIVE): %s"," ".join(cmd))
    proc = subprocess.Popen(cmd, preexec_fn=os.setsid); return proc, outp

def curl_download(url: str, out_path: str):
    cmd = ["curl","-L","-o",out_path,url]; log.info("curl: %s"," ".join(cmd))
    subprocess.run(cmd, check=True)

def stop_live() -> bool:
    global current_proc, current_title
    try:
        if current_proc and current_proc.poll() is None:
            os.killpg(os.getpgid(current_proc.pid), signal.SIGTERM)
            current_proc.wait(timeout=10); log.info("live stopped (pid %s)",current_proc.pid)
            current_proc=None; current_title=None; return True
        subprocess.run(["pkill","-f","ffmpeg"], check=False); return True
    except Exception as e:
        log.error("stop_live error: %s",e); return False

def upload_and_delete_path(local_path: str):
    if not os.path.exists(local_path): return
    try:
        if os.path.isdir(local_path):
            remote=f"{RCLONE_REMOTE}:{REMOTE_DIR}/{os.path.basename(local_path)}"
            subprocess.run(["rclone","copy",local_path,remote,"--transfers=4","--checkers=8","--fast-list"],check=True)
            subprocess.run(["rm","-rf",local_path],check=True)
        else:
            remote=f"{RCLONE_REMOTE}:{REMOTE_DIR}/{os.path.basename(local_path)}"
            subprocess.run(["rclone","copyto",local_path,remote],check=True); os.remove(local_path)
        log.info("uploaded & deleted: %s",local_path)
    except subprocess.CalledProcessError as e:
        log.error("[upload] rclone error: %s",e)

@bot.message_handler(commands=["start","help"])
def h_start(m):
    bot.reply_to(m,"Send a video URL. After job -> OneDrive upload -> local delete.\\n/status | /stop")

@bot.message_handler(commands=["status"])
def h_status(m):
    if current_proc and current_proc.poll() is None:
        bot.reply_to(m,f"LIVE recording (pid {current_proc.pid}): {current_title or 'unknown'}")
    else:
        bot.reply_to(m,"Idle")

@bot.message_handler(commands=["stop"])
def h_stop(m):
    bot.reply_to(m,"Stopped." if stop_live() else "Nothing to stop.")

@bot.message_handler(content_types=["text"])
def h_text(m):
    text=(m.text or "").strip(); mat=re.search(r"(https?://[^\\s]+)",text)
    if not mat: return
    url=mat.group(1)
    def worker():
        global current_proc,current_title
        try:
            bot.send_message(m.chat.id,"Checking metadata...")
            meta=None; title=None
            try:
                meta=get_meta(url); title=sanitize(meta.get("title","video"))
            except subprocess.CalledProcessError:
                title=sanitize(guess_name_from_url(url)); meta=None
            if meta and is_live(meta):
                if current_proc and current_proc.poll() is None:
                    bot.send_message(m.chat.id,"Already recording. Use /stop first."); return
                current_title=title; bot.send_message(m.chat.id,f"Start LIVE: {title}")
                current_proc, live_path = start_youtube_live(url,title)
                ret=current_proc.wait(); current_proc=None; current_title=None
                if os.path.exists(live_path):
                    bot.send_message(m.chat.id,f"Uploading: {os.path.basename(live_path)}")
                    upload_and_delete_path(live_path)
                    bot.send_message(m.chat.id,"Upload complete and local file removed.")
                bot.send_message(m.chat.id,f"Live finished (code {ret})."); return
            bot.send_message(m.chat.id,f"Start download: {title}")
            before=set(os.listdir(SAVE_DIR))
            try:
                yt_dlp_download(url)
                after=set(os.listdir(SAVE_DIR))
                new_files=[os.path.join(SAVE_DIR,f) for f in (after-before)]
                if not new_files: raise RuntimeError("No new file detected after yt-dlp")
                for fp in new_files:
                    bot.send_message(m.chat.id,f"Uploading: {os.path.basename(fp)}")
                    upload_and_delete_path(fp)
                bot.send_message(m.chat.id,"Upload complete and local file(s) removed."); return
            except Exception as e:
                log.warning("yt-dlp failed, fallback: %s",e)
            if is_m3u8(url):
                bot.send_message(m.chat.id,f"Recording m3u8: {title}")
                outp=ffmpeg_record_from_stream(url,title)
                bot.send_message(m.chat.id,f"Uploading: {os.path.basename(outp)}")
                upload_and_delete_path(outp)
                bot.send_message(m.chat.id,"Upload complete and local file removed."); return
            ts=dt.datetime.now().strftime("%Y%m%d_%H%M%S")
            base=guess_name_from_url(url); outp=os.path.join(SAVE_DIR,f"{ts}_{sanitize(base)}")
            bot.send_message(m.chat.id,f"Direct download: {os.path.basename(outp)}")
            curl_download(url,outp)
            bot.send_message(m.chat.id,f"Uploading: {os.path.basename(outp)}")
            upload_and_delete_path(outp)
            bot.send_message(m.chat.id,"Upload complete and local file removed.")
        except subprocess.CalledProcessError as e:
            bot.send_message(m.chat.id,f"Run error: {e}"); log.error("subprocess error: %s",e)
        except Exception as e:
            bot.send_message(m.chat.id,f"Unknown error: {e}"); log.error("unknown error: %s",e)
    threading.Thread(target=worker,daemon=True).start()

if __name__=="__main__":
    print("Bot running..."); os.environ["PYTHONUNBUFFERED"]="1"
    try: bot.delete_webhook(drop_pending_updates=True)
    except Exception as e: log.warning("delete_webhook error: %s",e)
    while True:
        try: bot.infinity_polling(skip_pending=True, timeout=30, long_polling_timeout=30)
        except KeyboardInterrupt: print("Bye"); break
        except Exception as e: log.error("polling error: %s (retry in 5s)",e); time.sleep(5)
PY

chmod 644 "${BOT_PY}"
chown -R "${RUN_USER}:${RUN_USER}" "${INSTALL_DIR}"

# ========= systemd unit =========
info "Creating systemd service: ${SERVICE}"
cat > "${SERVICE}" <<UNIT
[Unit]
Description=YouTube Recorder Telegram Bot
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 -u ${BOT_PY}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=LANG=C.UTF-8
Environment=LC_ALL=C.UTF-8
Environment=PYTHONUNBUFFERED=1
Environment=PATH=/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable youtube_bot.service
systemctl restart youtube_bot.service

ok "Service started."
echo
info "Check : systemctl status youtube_bot --no-pager"
info "Logs  : journalctl -u youtube_bot -f"
ok "Install completed!!"
