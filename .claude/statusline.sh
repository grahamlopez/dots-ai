#!/usr/bin/env bash
# Claude Code statusline — always-visible footer
# Reads JSON session data from stdin

set -euo pipefail

DATA=$(cat)

# ── Extract fields ──────────────────────────────────────────────────
model=$(echo "$DATA" | jq -r '.model.display_name // "—"')
model_id=$(echo "$DATA" | jq -r '.model.id // ""')
session_id=$(echo "$DATA" | jq -r '.session_id // ""')
session_short=${session_id:0:8}

# ── Thinking effort (not in statusline JSON, read from settings) ───
effort="medium"  # default
for f in "$HOME/.claude/settings.json" ".claude/settings.json" ".claude/settings.local.json"; do
  if [[ -f "$f" ]]; then
    val=$(jq -r '.effortLevel // empty' "$f" 2>/dev/null)
    if [[ -n "$val" ]]; then effort="$val"; fi
  fi
done
# env var overrides
if [[ -n "${CLAUDE_CODE_EFFORT_LEVEL:-}" ]]; then
  effort="$CLAUDE_CODE_EFFORT_LEVEL"
fi

# ── Raw values from current run ─────────────────────────────────────
# NOTE: .context_window.* describes the CURRENT context window (what the last
# request carried), not session totals — it rises and falls every turn. Real
# cumulative token counts come from the transcript below. Only .cost.* is
# genuinely cumulative, and only within one CLI process.
cur_cost=$(echo "$DATA"   | jq -r '.cost.total_cost_usd    // 0')
cur_dur_ms=$(echo "$DATA" | jq -r '.cost.total_duration_ms // 0')
transcript=$(echo "$DATA" | jq -r '.transcript_path        // ""')

ctx_pct=$(echo "$DATA"  | jq -r '.context_window.used_percentage     // 0' | cut -d. -f1)
ctx_size=$(echo "$DATA" | jq -r '.context_window.context_window_size // 200000')

# ── Rate limits (5h / 7d usage windows) ─────────────────────────────
lim5_pct=$(echo "$DATA"   | jq -r '.rate_limits.five_hour.used_percentage // empty' | cut -d. -f1)
lim5_reset=$(echo "$DATA" | jq -r '.rate_limits.five_hour.resets_at       // empty' | cut -d. -f1)
lim7_pct=$(echo "$DATA"   | jq -r '.rate_limits.seven_day.used_percentage // empty' | cut -d. -f1)
lim7_reset=$(echo "$DATA" | jq -r '.rate_limits.seven_day.resets_at       // empty' | cut -d. -f1)

# ── Session totals ──────────────────────────────────────────────────
# Tokens: summed from the transcript, which is the only cumulative record.
#   One API request writes several assistant entries (thinking / text / each
#   tool_use), all repeating the SAME usage object — so dedupe by requestId
#   or the totals inflate ~3x. Streamed, not slurped, and cached on file size
#   (transcripts only grow) so repeated renders cost nothing.
# Cost/duration: taken from .cost.*, which resets when the CLI process
#   restarts. Bank the last-seen values only when a counter that is strictly
#   monotonic within a process actually drops — that means a real resume.
state_dir="$HOME/.claude/statusline-state"
[[ -d "$state_dir" ]] || mkdir -p "$state_dir"
state_file="${state_dir}/${session_id}"

# ── Rate-limit cache (shared by all sessions) ───────────────────────
# The CLI only reports rate_limits once it has made an API request in this
# process, so a freshly opened session has none — yet that is exactly when
# you want to know what is left. The window is account-wide, so cache the
# last reading globally and reuse it, flagged as stale with "~".
rl_cache="${state_dir}/rate-limits.json"
rl_stale=0
if [[ -n "$lim5_pct" ]]; then
  jq -n --arg p5 "$lim5_pct" --arg r5 "$lim5_reset" \
        --arg p7 "$lim7_pct" --arg r7 "$lim7_reset" \
    '{five_pct:$p5, five_reset:$r5, seven_pct:$p7, seven_reset:$r7}' \
    > "${rl_cache}.$$" 2>/dev/null && mv -f "${rl_cache}.$$" "$rl_cache" 2>/dev/null
  rm -f "${rl_cache}.$$" 2>/dev/null
elif [[ -f "$rl_cache" ]]; then
  eval "$(jq -r '
    "lim5_pct=\(.five_pct // "" | @sh) lim5_reset=\(.five_reset // "" | @sh)",
    "lim7_pct=\(.seven_pct // "" | @sh) lim7_reset=\(.seven_reset // "" | @sh)"
  ' "$rl_cache" 2>/dev/null)" 2>/dev/null || true
  rl_stale=1
  # A cached window whose reset time has passed has rolled over: the number
  # is no longer meaningful, so report unknown rather than guess.
  now_s=$(date +%s)
  [[ -n "$lim5_reset" ]] && (( lim5_reset <= now_s )) && lim5_pct="" 
  [[ -n "$lim7_reset" ]] && (( lim7_reset <= now_s )) && lim7_pct=""
fi

base_cost=0 base_dur=0 last_cost=0 last_dur=0
tok_size=-1 tok_in=0 tok_out=0 tok_cr=0 tok_cw=0

if [[ -f "$state_file" ]]; then
  eval "$(jq -r '
    "base_cost=\(.base_cost // 0) base_dur=\(.base_dur // 0)",
    "last_cost=\(.last_cost // 0) last_dur=\(.last_dur // 0)",
    "tok_size=\(.tok_size // -1) tok_in=\(.tok_in // 0) tok_out=\(.tok_out // 0)",
    "tok_cr=\(.tok_cr // 0) tok_cw=\(.tok_cw // 0)"
  ' "$state_file" 2>/dev/null)" 2>/dev/null || true
fi

# Resume detection: cost and duration only ever climb inside one process.
resumed=0
if (( cur_dur_ms < last_dur )); then resumed=1; fi
if awk "BEGIN{exit !($cur_cost < $last_cost - 0.000001)}"; then resumed=1; fi
if (( resumed )); then
  base_cost=$(awk "BEGIN{printf \"%.6f\", $base_cost + $last_cost}")
  base_dur=$(( base_dur + last_dur ))
fi

# Re-scan the transcript only when it has grown since the last render.
cur_size=0
[[ -f "$transcript" ]] && cur_size=$(stat -c %s "$transcript" 2>/dev/null || echo 0)
if [[ -f "$transcript" ]] && (( cur_size != tok_size )); then
  read -r tok_in tok_out tok_cr tok_cw <<<"$(
    jq -rc 'select(.type == "assistant" and .message.usage != null)
            | [ (.requestId // .uuid // "?"),
                (.message.usage.input_tokens                // 0),
                (.message.usage.output_tokens               // 0),
                (.message.usage.cache_read_input_tokens     // 0),
                (.message.usage.cache_creation_input_tokens // 0) ]
            | @tsv' "$transcript" 2>/dev/null \
    | awk -F'\t' '!seen[$1]++ { i+=$2; o+=$3; cr+=$4; cw+=$5 }
                   END { printf "%d %d %d %d", i+0, o+0, cr+0, cw+0 }'
  )"
  : "${tok_in:=0}" "${tok_out:=0}" "${tok_cr:=0}" "${tok_cw:=0}"
  tok_size=$cur_size
fi

# Save state
jq -n \
  --arg     bc "$base_cost" --argjson bd "$base_dur" \
  --arg     lc "$cur_cost"  --argjson ld "$cur_dur_ms" \
  --argjson ts "$tok_size"  --argjson ti "$tok_in" --argjson to "$tok_out" \
  --argjson tcr "$tok_cr"   --argjson tcw "$tok_cw" \
  '{base_cost:($bc|tonumber), base_dur:$bd,
    last_cost:($lc|tonumber), last_dur:$ld,
    tok_size:$ts, tok_in:$ti, tok_out:$to, tok_cr:$tcr, tok_cw:$tcw}' \
  > "$state_file" 2>/dev/null || true

read_tok=$tok_in
write_tok=$tok_out
cache_read=$tok_cr
cache_write=$tok_cw
cost=$(awk "BEGIN{printf \"%.6f\", $base_cost + $cur_cost}")
dur_ms=$(( base_dur + cur_dur_ms ))

# ── Helpers ─────────────────────────────────────────────────────────
RST='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
# palette
WHT='\033[97m'
GRN='\033[32m'
YLW='\033[33m'
RED='\033[31m'
CYN='\033[36m'
MAG='\033[35m'
BLU='\033[34m'
GRY='\033[90m'

fmt_tokens() {
  local n=$1
  if   (( n >= 1000000 )); then printf "%.1fM" "$(echo "scale=1; $n/1000000" | bc)"
  elif (( n >= 1000 ));    then printf "%.1fk" "$(echo "scale=1; $n/1000"    | bc)"
  else printf "%d" "$n"
  fi
}

# ── Meter bars ──────────────────────────────────────────────────────
# pct_color <pct> -> sets PCT_CLR
pct_color() {
  local p=$1
  if   (( p >= 85 )); then PCT_CLR="$RED"
  elif (( p >= 60 )); then PCT_CLR="$YLW"
  else                     PCT_CLR="$GRN"
  fi
}

# make_bar <pct> <width> <color> -> echoes bar
make_bar() {
  local p=$1 width=$2 clr=$3 i out
  (( p > 100 )) && p=100
  (( p < 0   )) && p=0
  local filled=$(( p * width / 100 ))
  local empty=$(( width - filled ))
  out="$clr"
  for (( i=0; i<filled; i++ )); do out+="█"; done
  out+="${GRY}"
  for (( i=0; i<empty;  i++ )); do out+="░"; done
  out+="${RST}"
  printf '%s' "$out"
}

# countdown <epoch> -> echoes e.g. 2h13m, 47m, 30s
countdown() {
  local target=$1 now left h m
  now=$(date +%s)
  left=$(( target - now ))
  (( left < 0 )) && left=0
  h=$(( left / 3600 ))
  m=$(( (left % 3600) / 60 ))
  if   (( h >= 24 )); then printf '%dd%dh' "$(( h / 24 ))" "$(( h % 24 ))"
  elif (( h > 0 ));  then printf '%dh%02dm' "$h" "$m"
  elif (( m > 0 ));  then printf '%dm' "$m"
  else                    printf '%ds' "$left"
  fi
}

bar_width=20
pct_color "$ctx_pct"; BAR_CLR="$PCT_CLR"
bar=$(make_bar "$ctx_pct" "$bar_width" "$BAR_CLR")

# ── Session duration ────────────────────────────────────────────────
dur_s=$(( dur_ms / 1000 ))
dur_m=$(( dur_s  / 60   ))
dur_h=$(( dur_m  / 60   ))
if   (( dur_h > 0 )); then dur_str="${dur_h}h$((dur_m % 60))m"
elif (( dur_m > 0 )); then dur_str="${dur_m}m$((dur_s % 60))s"
else                       dur_str="${dur_s}s"
fi

# ── Format cost ─────────────────────────────────────────────────────
cost_str=$(printf '$%.2f' "$cost")

# ── Build lines ─────────────────────────────────────────────────────
r=$(fmt_tokens "$read_tok")
w=$(fmt_tokens "$write_tok")
cr=$(fmt_tokens "$cache_read")
cw=$(fmt_tokens "$cache_write")

# Line 1: model · thinking · tokens · cost
printf '%b' \
  "${BOLD}${CYN}${model}${RST}" \
  "${GRY} │ ${RST}" \
  "${MAG}${effort}${RST}" \
  "${GRY} │ ${RST}" \
  "${BLU}r:${RST}${WHT}${r} ${BLU}w:${RST}${WHT}${w} " \
  "${BLU}cr:${RST}${WHT}${cr} ${BLU}cw:${RST}${WHT}${cw}${RST}" \
  "${GRY} │ ${RST}" \
  "${GRN}${cost_str}${RST}"
echo

# Line 2: context bar · session · duration
ctx_size_k=$(( ctx_size / 1000 ))
printf '%b' \
  "${GRY}ctx ${RST}${bar} ${BOLD}${BAR_CLR}${ctx_pct}%${RST} ${DIM}(${ctx_size_k}k)${RST}" \
  "${GRY} │ ${RST}" \
  "${DIM}${session_short}${RST}" \
  "${GRY} │ ${RST}" \
  "${DIM}${dur_str}${RST}"
echo

# Line 3: usage windows (5h / 7d), live or from the shared cache
if [[ -n "$lim5_pct" || -n "$lim7_pct" || $rl_stale -eq 1 ]]; then
  mark=""; (( rl_stale )) && mark="~"

  if [[ -n "$lim5_pct" ]]; then
    pct_color "$lim5_pct"; L5_CLR="$PCT_CLR"
    lim5_bar=$(make_bar "$lim5_pct" "$bar_width" "$L5_CLR")
    reset5=""
    [[ -n "$lim5_reset" ]] && reset5=" ${DIM}↻$(countdown "$lim5_reset")${RST}"
    printf '%b' \
      "${GRY}5h  ${RST}${lim5_bar} ${BOLD}${L5_CLR}${mark}${lim5_pct}%${RST}${reset5}"
  else
    printf '%b' "${GRY}5h  ${RST}$(make_bar 0 "$bar_width" "$GRY") ${DIM}—${RST}"
  fi

  if [[ -n "$lim7_pct" ]]; then
    pct_color "$lim7_pct"; L7_CLR="$PCT_CLR"
    reset7=""
    [[ -n "$lim7_reset" ]] && reset7=" ${DIM}↻$(countdown "$lim7_reset")${RST}"
    printf '%b' \
      "${GRY} │ ${RST}" \
      "${GRY}7d ${RST}${BOLD}${L7_CLR}${mark}${lim7_pct}%${RST}${reset7}"
  fi
  echo
fi
