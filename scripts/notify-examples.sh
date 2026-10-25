#!/usr/bin/env bash
#
# notify-examples.sh: example notifiers for plex-proxy-watchdog.sh.
#
# Copy to e.g. ~/bin/notify.sh, keep ONE backend uncommented, chmod 700, and
# set NOTIFY_CMD to its path. Called as: notify.sh "<subject>" "<body>"
# Keep tokens in this file (mode 700) or the env file (mode 600), never in git.
#
set -u
subject="$1"
body="${2:-}"

# --- ntfy (https://ntfy.sh or self-hosted) ----------------------------------
NTFY_TOPIC_URL="https://ntfy.sh/your-long-random-topic"
curl -fsS --max-time 15 -H "Title: $subject" -d "$body" "$NTFY_TOPIC_URL" >/dev/null

# --- Telegram bot -------------------------------------------------------------
# TG_TOKEN="123456:ABC..."   TG_CHAT="123456789"
# curl -fsS --max-time 15 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
#      --data-urlencode "chat_id=${TG_CHAT}" \
#      --data-urlencode "text=${subject}
# ${body}" >/dev/null

# --- Pushover -----------------------------------------------------------------
# PO_TOKEN="..."   PO_USER="..."
# curl -fsS --max-time 15 https://api.pushover.net/1/messages.json \
#      --form-string "token=$PO_TOKEN" --form-string "user=$PO_USER" \
#      --form-string "title=$subject" --form-string "message=$body" >/dev/null

# --- Email via SMTP (curl built with SMTP support) ----------------------------
# Some NAS builds of curl have no SMTP; use python3 smtplib there instead.
# printf 'Subject: %s\n\n%s\n' "$subject" "$body" | \
#   curl -fsS --ssl-reqd --url "smtps://smtp.example.com:465" \
#        --user "you@example.com:APP_PASSWORD" \
#        --mail-from "you@example.com" --mail-rcpt "you@example.com" -T - >/dev/null
