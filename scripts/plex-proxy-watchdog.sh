#!/usr/bin/env bash
#
# plex-proxy-watchdog.sh: is remote Plex reachable the way a viewer reaches it?
#
# Run it on a machine OTHER than the cloud VM (a box can't report its own
# death). The Plex host is ideal: the probe goes out your home internet, to the
# VM, through Caddy, and back over the tunnel, so one request covers stale DNS,
# VM down, Caddy down, tunnel down, expired Tailscale key and a bad certificate.
#
# Checks:
#   1. https://$PLEX_URL/identity returns a body containing machineIdentifier
#   2. TLS certificate has more than $CERT_WARN_DAYS days left
#   3. (optional) the VM's Tailscale peer is present and not offline
#
# Alerting is state-aware: alert after $FAIL_THRESHOLD consecutive failures,
# repeat at most every $REPEAT_SEC while still down, send a recovery message.
#
# Usage:
#   plex-proxy-watchdog.sh            normal run (cron: */5 * * * *)
#   plex-proxy-watchdog.sh --test     send a test notification
#   plex-proxy-watchdog.sh --status   print current state
#   DRY_RUN=1 plex-proxy-watchdog.sh  check and log, never notify
#
# Needs: bash, curl, openssl, GNU date. Config: ~/.plex-proxy-watchdog.env
#
set -uo pipefail
# No `set -e`: a failed check must be recorded, not abort the script.

ENV_FILE="${ENV_FILE:-$HOME/.plex-proxy-watchdog.env}"
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

PLEX_URL="${PLEX_URL:-plex.example.com}"     # hostname only, no scheme
CERT_WARN_DAYS="${CERT_WARN_DAYS:-14}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-2}"        # consecutive failures before alerting
REPEAT_SEC="${REPEAT_SEC:-21600}"            # 6h between repeat alerts while down
CERT_REPEAT_SEC="${CERT_REPEAT_SEC:-86400}"  # 24h between certificate warnings
TAILSCALE_BIN="${TAILSCALE_BIN:-tailscale}"  # Synology: /var/packages/Tailscale/target/bin/tailscale
TS_PEER="${TS_PEER:-}"                       # VM's tailnet hostname; empty = skip check 3
# Command that delivers a notification. Called as: $NOTIFY_CMD "<subject>" "<body>"
NOTIFY_CMD="${NOTIFY_CMD:-}"
STATE_DIR="${STATE_DIR:-$HOME/.plex-proxy-watchdog}"
LOG="${LOG:-$STATE_DIR/watchdog.log}"
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "$STATE_DIR"
now="$(date +%s)"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

get_state() { cat "$STATE_DIR/$1" 2>/dev/null || echo "${2:-0}"; }
set_state() { echo "$2" > "$STATE_DIR/$1"; }

notify() {
    local subject="$1" body="$2"
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY_RUN would notify: $subject"
        return 0
    fi
    if [ -z "$NOTIFY_CMD" ]; then
        log "NOTIFY_CMD not set; would notify: $subject"
        return 0
    fi
    # Never let a broken notifier kill the watchdog.
    $NOTIFY_CMD "$subject" "$body" >> "$LOG" 2>&1 || log "notify failed (exit $?)"
}

# --- checks ---------------------------------------------------------------
# Bash-native matching, not `printf | grep -q`: with pipefail, grep -q exits
# on the first match, printf dies of SIGPIPE, and the pipeline "fails"
# because the match succeeded. That shows up as an intermittent false DOWN.

check_https() {
    local body
    body="$(curl -fsS --max-time 20 "https://$PLEX_URL/identity" 2>&1)" || {
        detail="https: curl failed: ${body:0:200}"
        return 1
    }
    [[ "$body" == *machineIdentifier* ]] || {
        detail="https: 200 but no machineIdentifier in response"
        return 1
    }
}

cert_days_left() {
    local end end_s
    end="$(echo | openssl s_client -connect "$PLEX_URL:443" -servername "$PLEX_URL" 2>/dev/null \
           | openssl x509 -noout -enddate 2>/dev/null)" || return 1
    end="${end#notAfter=}"
    [ -n "$end" ] || return 1
    end_s="$(date -d "$end" +%s 2>/dev/null)" || return 1
    echo $(( (end_s - now) / 86400 ))
}

check_tailscale() {
    [ -n "$TS_PEER" ] || return 0
    local status line
    status="$("$TAILSCALE_BIN" status 2>&1)" || {
        detail="tailscale: status command failed: ${status:0:200}"
        return 1
    }
    line="$(while IFS= read -r l; do [[ "$l" == *" $TS_PEER "* ]] && { echo "$l"; break; }; done <<< "$status")"
    [ -n "$line" ] || { detail="tailscale: peer $TS_PEER not in netmap"; return 1; }
    [[ "$line" == *offline* ]] && { detail="tailscale: peer $TS_PEER offline"; return 1; }
    return 0
}

# --- modes ------------------------------------------------------------------

case "${1:-}" in
    --test)
        DRY_RUN=0
        notify "[plex-proxy] test" "Test notification from $(hostname) at $(date)."
        echo "sent (see $LOG if nothing arrived)"
        exit 0 ;;
    --status)
        echo "fails=$(get_state fails) down=$(get_state down) last_alert=$(get_state last_alert) cert_last_warn=$(get_state cert_last_warn)"
        tail -n 5 "$LOG" 2>/dev/null
        exit 0 ;;
esac

# --- run --------------------------------------------------------------------

detail=""
ok=1
check_https     || ok=0
[ "$ok" = 1 ] && { check_tailscale || ok=0; }

days="$(cert_days_left)" || days="?"
log "PROBE https_ok=$ok cert_days=$days ${detail:+detail=\"$detail\"}"

fails="$(get_state fails)"
down="$(get_state down)"
last_alert="$(get_state last_alert)"

if [ "$ok" = 1 ]; then
    if [ "$down" = 1 ]; then
        notify "[plex-proxy] RECOVERED" "Remote Plex at https://$PLEX_URL is reachable again."
        log "RECOVERED"
    fi
    set_state fails 0
    set_state down 0
else
    fails=$((fails + 1))
    set_state fails "$fails"
    if [ "$fails" -ge "$FAIL_THRESHOLD" ]; then
        if [ "$down" != 1 ] || [ $((now - last_alert)) -ge "$REPEAT_SEC" ]; then
            notify "[plex-proxy] DOWN" "Remote Plex at https://$PLEX_URL failed $fails checks in a row. $detail"
            set_state last_alert "$now"
            log "ALERT DOWN fails=$fails"
        fi
        set_state down 1
    fi
fi

# Certificate warning, throttled separately (catches silent ACME renewal failure).
if [[ "$days" =~ ^-?[0-9]+$ ]] && [ "$days" -lt "$CERT_WARN_DAYS" ]; then
    cert_last="$(get_state cert_last_warn)"
    if [ $((now - cert_last)) -ge "$CERT_REPEAT_SEC" ]; then
        notify "[plex-proxy] certificate expires in $days days" \
            "TLS certificate for $PLEX_URL has $days days left. Caddy should renew at ~30 days; check 'journalctl -u caddy' on the VM and that port 80 is open to the world."
        set_state cert_last_warn "$now"
    fi
fi

exit 0
