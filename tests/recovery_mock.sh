#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/oc-media-recovery-test.$$"
MOCK_BIN="$TMP/bin"
export MOCK_STATE="$TMP/media_now"
export MOCK_RUNTIME="$TMP/runtime.yaml"
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$MOCK_BIN" "$TMP/persist" "$TMP/volatile"

cat > "$MOCK_BIN/uci" <<'EOF'
#!/bin/sh
echo "$MOCK_RUNTIME"
EOF

cat > "$MOCK_BIN/ruby" <<'EOF'
#!/bin/sh
for last do :; done
case "$last" in
    external-controller) printf '127.0.0.1:9090' ;;
    secret) : ;;
esac
EOF

cat > "$MOCK_BIN/logger" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$MOCK_BIN/sync" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$MOCK_BIN/curl" <<'EOF'
#!/bin/sh
method=GET
data=''
url=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -X) method="$2"; shift 2 ;;
        -d) data="$2"; shift 2 ;;
        -H|--connect-timeout) shift 2 ;;
        -f|-s|-S|-fsS) shift ;;
        http://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    */version)
        printf '{}\n'
        ;;
    */proxies/MEDIA)
        if [ "$method" = PUT ]; then
            printf '%s' "$data" | jq -r '.name' > "$MOCK_STATE"
        else
            jq -nc --arg now "$(cat "$MOCK_STATE")" '{name:"MEDIA",now:$now,all:["old","new","third"]}'
        fi
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$MOCK_BIN/uci" "$MOCK_BIN/ruby" "$MOCK_BIN/logger" "$MOCK_BIN/sync" "$MOCK_BIN/curl"
: > "$MOCK_RUNTIME"

CONFIG="$TMP/config"
cat > "$CONFIG" <<EOF
ENABLED=0
PERSIST_DIR='$TMP/persist'
VOLATILE_DIR='$TMP/volatile'
EVENT_LOG='$TMP/persist/events.jsonl'
PENDING_TIMEOUT_SECONDS=1
LOG_MAX_BYTES=1048576
EOF

run_script()
{
    if [ "${DEBUG_RECOVERY_TEST:-0}" = 1 ]; then
        PATH="$MOCK_BIN:$PATH" CONFIG="$CONFIG" sh -x "$ROOT/oc-media-speed-select-v1"
    else
        PATH="$MOCK_BIN:$PATH" CONFIG="$CONFIG" "$ROOT/oc-media-speed-select-v1"
    fi
    if [ -s "$TMP/persist/events.jsonl" ]; then
        jq -e . "$TMP/persist/events.jsonl" >/dev/null
    fi
}

# Disabled with no pending must not mutate MEDIA.
printf 'new\n' > "$MOCK_STATE"
run_script
[ "$(cat "$MOCK_STATE")" = new ]

# Disabled still recovers an expired transaction owned by new_node.
started_at=$(( $(date +%s) - 10 ))
jq -nc --arg old old --arg new new --argjson started "$started_at" \
    '{version:1,run_id:"test",old_node:$old,new_node:$new,source_ip:"10.0.0.2",started_at:$started}' \
    > "$TMP/persist/challenge_pending"
run_script
[ "$(cat "$MOCK_STATE")" = old ]
[ ! -e "$TMP/persist/challenge_pending" ]

# A third selector value is external control and must never be overwritten.
printf 'third\n' > "$MOCK_STATE"
jq -nc --arg old old --arg new new --argjson started "$started_at" \
    '{version:1,run_id:"test",old_node:$old,new_node:$new,source_ip:"10.0.0.2",started_at:$started}' \
    > "$TMP/persist/challenge_pending"
run_script
[ "$(cat "$MOCK_STATE")" = third ]
[ ! -e "$TMP/persist/challenge_pending" ]

echo 'pending recovery mock checks passed'
