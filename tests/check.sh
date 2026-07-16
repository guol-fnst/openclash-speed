#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/oc-media-speed-select-v1"
PATCHER="$ROOT/oc_media_patch_v1.rb"
CONFIG="$ROOT/config.example"

sh -n "$SCRIPT"
if command -v busybox >/dev/null 2>&1; then
    busybox ash -n "$SCRIPT"
fi

enabled="$(sed -n 's/^ENABLED=//p' "$CONFIG")"
[ "$enabled" = 0 ]
max_bytes="$(sed -n 's/^BENCH_MAX_BYTES=//p' "$CONFIG")"
[ "$max_bytes" = 12582912 ]
fast_bytes="$(sed -n 's/^FAST_POSITIVE_MIN_BYTES=//p' "$CONFIG")"
[ "$fast_bytes" = 4194304 ]
low_active="$(sed -n 's/^LOW_MIN_ACTIVE_SECONDS=//p' "$CONFIG")"
[ "$low_active" = 2 ]
low_bytes="$(sed -n 's/^LOW_MIN_BYTES=//p' "$CONFIG")"
[ "$low_bytes" = 262144 ]
stall_enabled="$(sed -n 's/^STALL_PROBE_ENABLED=//p' "$CONFIG")"
[ "$stall_enabled" = 1 ]
inconclusive_count="$(sed -n 's/^INCONCLUSIVE_REQUIRED_COUNT=//p' "$CONFIG")"
[ "$inconclusive_count" = 2 ]
"$ROOT/tests/low_threshold_v12.sh" "$CONFIG"

# V1.1 deliberately emits one semantic event per normal passive window. The
# old duplicate insufficient event name must not return.
if grep -F 'event passive_sample_insufficient' "$SCRIPT" >/dev/null; then
    echo 'duplicate passive_sample_insufficient event still present' >&2
    exit 1
fi

# Positive and negative evidence are intentionally asymmetric.
fast_positive()
{
    bytes="$1"
    active="$2"
    bps="$3"
    [ "$bytes" -ge 4194304 ] && [ "$active" -ge 1 ] && [ "$bps" -ge 1000000 ]
}
fast_positive 17458375 2 8729187
fast_positive 9802266 1 9802266
if fast_positive 1464479 1 1464479; then
    echo 'small one-second burst unexpectedly became fast-positive evidence' >&2
    exit 1
fi

# KEEP formula boundary checks, expressed independently of router/API code.
keep()
{
    old="$1"
    new="$2"
    target="$3"
    [ "$new" -ge "$target" ] || {
        [ "$new" -ge $((old * 120 / 100)) ] &&
        [ "$new" -ge $((old + 125000)) ]
    }
}

keep 125000 312500 1000000       # 1 Mbps -> 2.5 Mbps: material improvement
keep 900000 1000000 1000000      # reaches target without 20% improvement
if keep 500000 590000 1000000; then
    echo 'decision test unexpectedly kept insufficient improvement' >&2
    exit 1
fi

# The Ruby portion is exercised when Ruby is available (on the router it is).
if command -v ruby >/dev/null 2>&1; then
    tmp="${TMPDIR:-/tmp}/oc-media-sample.$$"
    trap 'rm -f "$tmp"' EXIT INT TERM
    cp "$ROOT/tests/sample.yaml" "$tmp"
    ruby -c "$PATCHER" >/dev/null
    ruby "$PATCHER" "$tmp" >/dev/null
    ruby -ryaml -e '
      c=YAML.load_file(ARGV[0]);
      abort unless c["listeners"].any?{|x| x["name"]=="unrelated"};
      b=c["listeners"].find{|x| x["name"]=="bench-in"};
      abort unless b && b["port"]==7898 && b["proxy"]=="BENCH" && b["users"]==[];
      abort unless c["proxy-groups"].find{|x| x["name"]=="MEDIA"}["proxies"]==["新加坡 A","美国 B"];
      abort unless c.dig("profile","store-selected")==true;
      rules=c["rules"];
      reject_i=rules.index("DOMAIN,ads.example,🛑 全球拦截");
      media_i=rules.index("DOMAIN-SUFFIX,youtube.com,MEDIA");
      legacy_i=rules.index("DOMAIN-SUFFIX,youtube.com,旧媒体组");
      abort unless reject_i < media_i && media_i < legacy_i;
    ' "$tmp"
    # A second pass must be idempotent.
    ruby "$PATCHER" "$tmp" >/dev/null
    ruby -ryaml -e '
      c=YAML.load_file(ARGV[0]);
      abort unless c["listeners"].count{|x| x["name"]=="bench-in"}==1;
      abort unless c["proxy-groups"].count{|x| x["name"]=="MEDIA"}==1;
      abort unless c["proxy-groups"].count{|x| x["name"]=="BENCH"}==1;
    ' "$tmp"
fi

# The overwrite hook parses only the numeric port and never sources the full
# speed-selector config into OpenClash's shell environment.
parsed_port="$(sed -n 's/^[[:space:]]*BENCH_PROXY_PORT=\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$CONFIG" | tail -n 1)"
[ "$parsed_port" = 7898 ]
if grep -F '. "$OC_MEDIA_CONFIG"' "$ROOT/openclash_custom_overwrite.snippet" >/dev/null; then
    echo 'overwrite snippet still sources the whole config' >&2
    exit 1
fi

"$ROOT/tests/recovery_mock.sh"
"$ROOT/tests/jq_compat.sh"

echo 'offline checks passed'
