#!/usr/bin/env bash
# usage-stats.sh PRICING_JSON CONFIG_DIR...: token use and estimated cost from the
# transcripts of the last month, as the `usage` object in docs/DESIGN.md (without
# `updated`). Days are local calendar days, the week runs Monday to Sunday, and the
# month starts on the 1st. Assistant lines repeat once per content block, so each
# message id + request id counts once (the last copy, which carries the final usage).
# Reads local files only: no network, no token. Replaces the counting half of
# get-claude-usage (jrohland/noctalia-v5-claudecode via claude-cockpit, MIT).
dir=$(dirname "$0")
pricing=$(cat "${1:?usage: usage-stats.sh PRICING_JSON CONFIG_DIR...}" 2>/dev/null) || pricing='{}'
printf '%s' "$pricing" | jq -e 'type == "object"' >/dev/null 2>&1 || pricing='{}'
shift
dow=$(date +%u)
days=$(for i in 0 1 2 3 4 5 6; do date -d "$((dow - 1 - i)) days ago" +%F; done | jq -Rsc 'split("\n")[:7]')

for cfg in "$@"; do
  [ -d "$cfg/projects" ] && find "$cfg/projects" -name '*.jsonl' -mtime -32 -exec grep -h -F '"type":"assistant"' {} + 2>/dev/null
done \
  | jq -L "$dir" -nRc --argjson p "$pricing" --argjson days "$days" \
      --arg today "$(date +%F)" --arg month "$(date +%Y-%m-01)" '
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
    | { daily: [$days[] as $d | $week | map(select(.day == $d) | .tokens) | add // 0],
        dailyCost: [$days[] as $d | $week | map(select(.day == $d) | .cost) | add // 0],
        todayTokens: ($tod | map(.tokens) | add // 0), todayCost: ($tod | map(.cost) | add // 0),
        weekTokens: ($week | map(.tokens) | add // 0), weekCost: ($week | map(.cost) | add // 0),
        monthTokens: ($mon | map(.tokens) | add // 0), monthCost: ($mon | map(.cost) | add // 0),
        weekMessages: ($week | length), weekSessions: ($week | map(.session) | unique | length),
        weekModels: ($week | group_by(.model | split("-")[1] // .)
          | map({ key: (.[0].model | split("-")[1] // .), value: (map(.tokens) | add) })
          | map(select(.key != "" and .key != "<synthetic>")) | from_entries) }'
