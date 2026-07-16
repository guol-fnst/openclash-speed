#!/bin/sh
set -eu

sample='{"connections":[{"id":"c1","download":3000,"upload":300,"chains":["node-a","MEDIA"],"metadata":{"host":"R1.GOOGLEVIDEO.COM","sourceIP":"10.0.0.2"}},{"id":"c2","download":5000,"upload":200,"chains":["node-a","MEDIA"],"metadata":{"host":"r2.googlevideo.com","sourceIP":"10.0.0.2"}}]}'

# Functions/operators used by passive sampling and the activity gate.
printf '%s' "$sample" | jq -e --arg group MEDIA --arg node node-a '
  def gv: (.metadata.host // "" | ascii_downcase) as $h |
    ($h == "googlevideo.com" or ($h | endswith(".googlevideo.com")));
  any(.connections[]?;
    gv and (((.chains // []) | index($group)) != null) and (((.chains // []) | index($node)) != null))
' >/dev/null

old='{"c1":{"download":1000,"upload":100,"source":"10.0.0.2"}}'
printf '%s' "$sample" | jq -e --arg group MEDIA --arg node node-a --argjson old "$old" '
  def gv: (.metadata.host // "" | ascii_downcase) as $h |
    ($h == "googlevideo.com" or ($h | endswith(".googlevideo.com")));
  [.connections[]? | select(gv) |
    select((((.chains // []) | index($group)) != null) and (((.chains // []) | index($node)) != null))] as $c |
  [$c[] | . as $x | ($old[$x.id] // null) as $p |
    {id:$x.id,source:($x.metadata.sourceIP // ""),is_new:($p==null),
     download_delta:(if $p==null then ($x.download // 0) else (($x.download // 0)-($p.download // 0)) end),
     upload_delta:(if $p==null then ($x.upload // 0) else (($x.upload // 0)-($p.upload // 0)) end)}] as $d |
  {map:($c | map({key:.id,value:{download:(.download // 0),upload:(.upload // 0),source:(.metadata.sourceIP // "")}}) | from_entries),
   bytes:([$d[].download_delta | select(.>0)] | add // 0),
   upload_bytes:([$d[].upload_delta | select(.>0)] | add // 0),
   new_ids:([$d[] | select(.is_new) | .id] | unique),
   source_ips:([$d[] | select(.download_delta>0) | .source | select(length>0)] | unique),
   activity_source_ips:([$d[] | select(.is_new or .download_delta>0 or .upload_delta>0) | .source | select(length>0)] | unique)} |
  .bytes == 7000 and .upload_bytes == 400 and .new_ids == ["c2"] and
  .source_ips == ["10.0.0.2"] and .activity_source_ips == ["10.0.0.2"] and
  .map.c1.download == 3000 and .map.c2.upload == 200
' >/dev/null

# X activity gate: include x.com/twitter.com/twimg.com subdomains only when the
# connection belongs to MEDIA and the currently selected node.
x_sample='{"connections":[{"chains":["node-a","MEDIA"],"metadata":{"host":"api.x.com","sourceIP":"10.0.0.3"}},{"chains":["node-a","MEDIA"],"metadata":{"host":"video.twimg.com","sourceIP":"10.0.0.3"}},{"chains":["node-b","MEDIA"],"metadata":{"host":"x.com","sourceIP":"10.0.0.4"}},{"chains":["node-a","OTHER"],"metadata":{"host":"twitter.com","sourceIP":"10.0.0.5"}}]}'
printf '%s' "$x_sample" | jq -e --arg group MEDIA --arg node node-a '
  def xtraffic: (.metadata.host // "" | ascii_downcase) as $h |
    ($h == "x.com" or ($h | endswith(".x.com")) or
     $h == "twitter.com" or ($h | endswith(".twitter.com")) or
     $h == "twimg.com" or ($h | endswith(".twimg.com")));
  [.connections[]? | select(xtraffic) |
    select((((.chains // []) | index($group)) != null) and (((.chains // []) | index($node)) != null)) |
    (.metadata.sourceIP // "") | select(length>0)] | unique == ["10.0.0.3"]
' >/dev/null

# X activity sample: per-source download deltas over two snapshots. An existing
# connection contributes only its positive delta, a connection first seen in the
# second snapshot contributes its full download, and an idle connection with a
# zero delta from another source is dropped.
x_old='{"cx1":{"download":1000,"source":"10.0.0.7"},"cx3":{"download":5000,"source":"10.0.0.9"}}'
x_snapshot='{"connections":[{"id":"cx1","download":4000,"chains":["node-a","MEDIA"],"metadata":{"host":"api.x.com","sourceIP":"10.0.0.7"}},{"id":"cx2","download":2000,"chains":["node-a","MEDIA"],"metadata":{"host":"video.twimg.com","sourceIP":"10.0.0.7"}},{"id":"cx3","download":5100,"chains":["node-a","MEDIA"],"metadata":{"host":"x.com","sourceIP":"10.0.0.9"}}]}'
printf '%s' "$x_snapshot" | jq -e --arg group MEDIA --arg node node-a --argjson old "$x_old" --argjson min 4096 '
  def xtraffic: (.metadata.host // "" | ascii_downcase) as $h |
    ($h == "x.com" or ($h | endswith(".x.com")) or
     $h == "twitter.com" or ($h | endswith(".twitter.com")) or
     $h == "twimg.com" or ($h | endswith(".twimg.com")));
  [.connections[]? | select(xtraffic) |
    select((((.chains // []) | index($group)) != null) and (((.chains // []) | index($node)) != null)) |
    . as $x | ($old[$x.id] // null) as $p |
    {source:($x.metadata.sourceIP // ""),
     delta:(if $p==null then ($x.download // 0) else (($x.download // 0)-($p.download // 0)) end)}]
  | [.[] | select(.delta>0 and (.source|length>0))] as $active
  | ([$active[].source] | unique) as $sources
  | ([$sources[] as $s | {key:$s,value:([$active[] | select(.source==$s) | .delta] | add)}]
     | from_entries | with_entries(select(.value >= $min)))
  | . == {"10.0.0.7":5000}
' >/dev/null

# State-file operations used by streaks, penalties and pending validation.
jq -ne --argjson needed 3 '
  ([1,2,3,4] | .[-$needed:]) == [2,3,4] and
  ({a:{until:10},b:{until:30}} | with_entries(select(.value.until > 20))) == {b:{until:30}} and
  ((12|floor) == 12)
' >/dev/null

echo 'router jq compatibility checks passed'
