#!/usr/bin/env bash
#
# geo-allow-refresh.sh: rebuild the geo_allow ipset from country CIDR blocks.
#
# Runs on the cloud VM as root, daily from cron:
#   17 4 * * * root /usr/local/sbin/geo-allow-refresh.sh >/dev/null 2>&1
#
# Pair it with an iptables rule such as:
#   iptables -I INPUT <N> -p tcp --dport 443 -m set --match-set geo_allow src -j ACCEPT
# Never apply it to port 80: Let's Encrypt validates from several continents.
#
# Failure policy: LAST-GOOD WINS. Every zone file is downloaded and checked
# before the live set is touched. Any failure exits non-zero and leaves the
# existing set in place, so a bad download can neither lock out real users
# nor silently drop the filter.
#
set -euo pipefail

# Lowercase ISO 3166-1 alpha-2 codes, space-separated. Override via env.
COUNTRIES="${COUNTRIES:-us}"

SET="geo_allow"
TMP="geo_allow_tmp"
BASE="https://www.ipdeny.com/ipblocks/data/countries"
MIN_LINES=100          # a zone file smaller than this is assumed truncated
MAXELEM=300000         # ipset default is 65536: too small, silently truncates

log()  { logger -t geo-allow "$*"; echo "$*"; }
fail() { log "FAILED: $*"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 1. download everything first; don't touch the live set until all succeed ---
for c in $COUNTRIES; do
    curl -fsS --max-time 60 --retry 3 --retry-delay 5 \
         "$BASE/${c}.zone" -o "$WORK/${c}.zone" \
      || fail "could not download ${c}.zone"

    lines="$(grep -cE '^[0-9]+\.' "$WORK/${c}.zone" || true)"
    [ "$lines" -ge "$MIN_LINES" ] \
      || fail "${c}.zone looks truncated (${lines} CIDRs, expected >= ${MIN_LINES})"
    log "${c}: ${lines} CIDRs"
done

# --- 2. build the replacement set in one restore pass (fast; add-in-a-loop is not) ---
ipset destroy "$TMP" 2>/dev/null || true
{
    echo "create $TMP hash:net family inet maxelem $MAXELEM"
    for c in $COUNTRIES; do
        grep -E '^[0-9]+\.' "$WORK/${c}.zone" | sed "s|^|add $TMP |"
    done
} | ipset restore || fail "ipset restore failed"

new_count="$(ipset list "$TMP" | sed -n 's/^Number of entries: //p')"
[ "${new_count:-0}" -ge "$MIN_LINES" ] || fail "built set is implausibly small (${new_count})"

# --- 3. atomic swap, then persist (netfilter-persistent loads this at boot) ---
ipset create "$SET" hash:net family inet maxelem "$MAXELEM" -exist
ipset swap "$TMP" "$SET"
ipset destroy "$TMP"

mkdir -p /etc/iptables
ipset save > /etc/iptables/ipsets

log "geo_allow refreshed: ${new_count} CIDRs (${COUNTRIES})"
