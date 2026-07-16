#!/bin/sh
set -eu

CONFIG="${1:-/etc/openclash/speed-select/config}"
. "$CONFIG"

[ "$LOW_MIN_ACTIVE_SECONDS" = 2 ]
[ "$LOW_MIN_BYTES" = 262144 ]

qualifies_low()
{
    bytes="$1"
    active="$2"
    bps="$3"
    [ "$active" -ge "$LOW_MIN_ACTIVE_SECONDS" ] &&
        [ "$bytes" -ge "$LOW_MIN_BYTES" ] &&
        [ "$bps" -lt "$YOUTUBE_TARGET_BYTES_PER_SEC" ]
}

append_low()
{
    bytes="$1"
    active="$2"
    now="$3"
    if [ -n "$state" ] && printf '%s' "$state" | jq -e \
        --arg node test-node --arg source 10.10.10.150 --argjson now "$now" \
        --argjson gap "$LOW_STREAK_MAX_GAP_SECONDS" \
        '.node==$node and .source_ip==$source and (($now-.last_epoch) <= $gap)' \
        >/dev/null 2>&1; then
        state="$(printf '%s' "$state" | jq -c \
            --argjson now "$now" --argjson bytes "$bytes" --argjson active "$active" \
            --argjson needed "$LOW_REQUIRED_WINDOWS" \
            '.last_epoch=$now | .samples=((.samples+[{bytes:$bytes,active:$active}]) | .[-$needed:])')"
    else
        state="$(jq -nc --arg node test-node --arg source 10.10.10.150 \
            --argjson now "$now" --argjson bytes "$bytes" --argjson active "$active" \
            '{node:$node,source_ip:$source,last_epoch:$now,samples:[{bytes:$bytes,active:$active}]}')"
    fi
}

# Replay the phone samples that the old 4-second/1-MiB gate rejected.
state=''
qualifies_low 534750 3 178250
append_low 534750 3 1000
[ "$(printf '%s' "$state" | jq -r '.samples|length')" = 1 ]

# An inconclusive/pause-like window must not erase or refresh valid evidence.
before="$state"
if qualifies_low 0 0 0; then
    exit 1
fi
[ "$state" = "$before" ]

qualifies_low 478281 3 159427
append_low 478281 3 1060
qualifies_low 420650 2 210325
append_low 420650 2 1120
[ "$(printf '%s' "$state" | jq -r '.samples|length')" = "$LOW_REQUIRED_WINDOWS" ]

# Very small or one-second bursts remain inconclusive.
if qualifies_low 200000 3 66666 || qualifies_low 500000 1 500000; then
    exit 1
fi

echo 'V1.2 low-threshold replay checks passed'
