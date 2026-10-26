#!/usr/bin/env bash
# usage-stats.sh PRICING_JSON CONFIG_DIR...: token use and estimated cost from the
# transcripts of the last 30 days, as the `usage` object in docs/DESIGN.md (without
# `updated`). Days are local calendar days; "7 days" and "30 days" end today, so the chart
# is never a lone Monday bar. Assistant lines repeat once per content block, so each
# message id + request id counts once (the last copy, which carries the final usage).
# The five costliest sessions of the last 7 days get their title and project.
# Reads local files only: no network, no token. Replaces the counting half of
# get-claude-usage (jrohland/noctalia-v5-claudecode via claude-cockpit, MIT).
dir=$(dirname "$0")
pricing=$(cat "${1:?usage: usage-stats.sh PRICING_JSON CONFIG_DIR...}" 2>/dev/null) || pricing='{}'
printf '%s' "$pricing" | jq -e 'type == "object"' >/dev/null 2>&1 || pricing='{}'
shift
days=$(for i in 6 5 4 3 2 1 0; do date -d "$i days ago" +%F; done | jq -Rsc 'split("\n")[:7]')
labels=$(for i in 6 5 4 3 2 1 0; do date -d "$i days ago" +%a; done | jq -Rsc 'split("\n")[:7]')

for cfg in "$@"; do
  [ -d "$cfg/projects" ] && find "$cfg/projects" -name '*.jsonl' -mtime -31 -exec grep -h -F '"type":"assistant"' {} + 2>/dev/null
done \
  | jq -L "$dir" -nRc --argjson p "$pricing" --argjson days "$days" --argjson labels "$labels" \
      --arg today "$(date +%F)" --arg month "$(date -d '29 days ago' +%F)" '
    include "pricing";
    def tokens: (.input_tokens // 0) + (.output_tokens // 0)
      + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0);
    def cost($m): price($m) as $r | if $r == null then 0 else
      (.input_tokens // 0) * $r.input + (.output_tokens // 0) * $r.output
      + (.cache_read_input_tokens // 0) * $r.cache_read
      + (.cache_creation_input_tokens // 0) * $r.cache_write end;
    reduce (inputs | fromjson? | select(.type == "assistant" and (.message.usage | type) == "object")) as $o ({};
      .[($o.message.id // $o.uuid // "") + ":" + ($o.requestId // "")] =
        { day: ($o.timestamp // "" | sub("\\.[0-9]+"; "") | fromdateiso8601? // 0 | strflocaltime("%Y-%m-%d")),
          model: ($o.message.model // ""), session: ($o.sessionId // ""),
          tokens: ($o.message.usage | tokens), cost: ($o.message.usage | cost($o.message.model)) })
    | [.[]] as $all
    | ($all | map(select(.day >= $days[0]))) as $week
    | ($all | map(select(.day >= $month))) as $mon
    | ($all | map(select(.day == $today))) as $tod
    | { days: $labels,
        daily: [$days[] as $d | $week | map(select(.day == $d) | .tokens) | add // 0],
        dailyCost: [$days[] as $d | $week | map(select(.day == $d) | .cost) | add // 0],
        todayTokens: ($tod | map(.tokens) | add // 0), todayCost: ($tod | map(.cost) | add // 0),
        d7Tokens: ($week | map(.tokens) | add // 0), d7Cost: ($week | map(.cost) | add // 0),
        d30Tokens: ($mon | map(.tokens) | add // 0), d30Cost: ($mon | map(.cost) | add // 0),
        d7Messages: ($week | length), d7Sessions: ($week | map(.session) | unique | length),
        d7Models: ($week | group_by(.model | split("-")[1] // .)
          | map({ key: (.[0].model | split("-")[1] // .), value: (map(.tokens) | add) })
          | map(select(.key != "" and .key != "<synthetic>")) | from_entries),
        topSessions: ($week | group_by(.session)
          | map({ id: .[0].session, cost: (map(.cost) | add), tokens: (map(.tokens) | add) })
          | sort_by(-.cost) | .[:5]) }' \
  | { read -r usage
      # Title and project of each top session, from its transcript.
      top=$(printf '%s' "$usage" | jq -r '.topSessions[].id')
      for id in $top; do
        [[ "$id" =~ ^[0-9a-fA-F-]+$ ]] || continue
        f=$(for cfg in "$@"; do find "$cfg/projects" -mindepth 2 -maxdepth 2 -name "$id.jsonl" -print -quit 2>/dev/null; done | head -n 1)
        [ -n "$f" ] || continue
        { grep -m1 -F '"cwd":"' -- "$f"; grep -F '"type":"ai-title"' -- "$f" | tail -n 1; } \
          | jq -sc --arg id "$id" '{ id: $id, cwd: (map(select(.cwd)) | first | .cwd // ""),
              title: (map(select(.aiTitle)) | last | .aiTitle // "") }'
      done | jq -sc --argjson u "$usage" '(map({ (.id): . }) | add // {}) as $meta
        | $u | .topSessions |= map(. + ($meta[.id] // {}))'
    }
