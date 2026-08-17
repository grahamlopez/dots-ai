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
cur_read=$(echo "$DATA"  | jq -r '.context_window.total_input_tokens  // 0')
cur_write=$(echo "$DATA" | jq -r '.context_window.total_output_tokens // 0')
cur_cache_read=$(echo "$DATA"  | jq -r '.context_window.current_usage.cache_read_input_tokens     // 0')
cur_cache_write=$(echo "$DATA" | jq -r '.context_window.current_usage.cache_creation_input_tokens  // 0')
cur_cost=$(echo "$DATA" | jq -r '.cost.total_cost_usd // 0')
cur_dur_ms=$(echo "$DATA" | jq -r '.cost.total_duration_ms // 0')

ctx_pct=$(echo "$DATA"  | jq -r '.context_window.used_percentage     // 0' | cut -d. -f1)
ctx_size=$(echo "$DATA" | jq -r '.context_window.context_window_size // 200000')

# ── Accumulate across resumes ───────────────────────────────────────
# Track per-session state in a temp file. When current values drop
# below last-seen values, a resume happened — bank the last-seen totals.
state_dir="$HOME/.claude/statusline-state"
[[ -d "$state_dir" ]] || mkdir -p "$state_dir"
state_file="${state_dir}/${session_id}"

base_read=0 base_write=0 base_cr=0 base_cw=0 base_cost=0 base_dur=0
last_read=0 last_write=0 last_cr=0 last_cw=0 last_cost=0 last_dur=0

if [[ -f "$state_file" ]]; then
  eval "$(jq -r '
    "base_read=\(.base_read) base_write=\(.base_write) base_cr=\(.base_cr) base_cw=\(.base_cw)",
    "base_cost=\(.base_cost) base_dur=\(.base_dur)",
    "last_read=\(.last_read) last_write=\(.last_write) last_cr=\(.last_cr) last_cw=\(.last_cw)",
    "last_cost=\(.last_cost) last_dur=\(.last_dur)"
  ' "$state_file" 2>/dev/null)" 2>/dev/null || true
fi

# Detect reset: if any cumulative counter dropped, bank last-seen values
if (( cur_read < last_read )) || (( cur_write < last_write )); then
  base_read=$(( base_read + last_read ))
  base_write=$(( base_write + last_write ))
  base_cr=$(( base_cr + last_cr ))
  base_cw=$(( base_cw + last_cw ))
  base_dur=$(( base_dur + last_dur ))
  # cost is float, use awk
  base_cost=$(awk "BEGIN{printf \"%.6f\", $base_cost + $last_cost}")
fi

# Save current state
jq -n \
  --argjson br "$base_read"  --argjson bw "$base_write" \
  --argjson bcr "$base_cr"   --argjson bcw "$base_cw" \
  --arg     bc "$base_cost"  --argjson bd "$base_dur" \
  --argjson lr "$cur_read"   --argjson lw "$cur_write" \
  --argjson lcr "$cur_cache_read" --argjson lcw "$cur_cache_write" \
  --arg     lc "$cur_cost"   --argjson ld "$cur_dur_ms" \
  '{base_read:$br, base_write:$bw, base_cr:$bcr, base_cw:$bcw,
    base_cost:($bc|tonumber), base_dur:$bd,
    last_read:$lr, last_write:$lw, last_cr:$lcr, last_cw:$lcw,
    last_cost:($lc|tonumber), last_dur:$ld}' > "$state_file" 2>/dev/null

# Totals = baseline + current
read_tok=$(( base_read + cur_read ))
write_tok=$(( base_write + cur_write ))
cache_read=$(( base_cr + cur_cache_read ))
cache_write=$(( base_cw + cur_cache_write ))
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

# ── Context meter bar ───────────────────────────────────────────────
bar_width=20
filled=$(( ctx_pct * bar_width / 100 ))
empty=$(( bar_width - filled ))

if   (( ctx_pct >= 85 )); then BAR_CLR="$RED"
elif (( ctx_pct >= 60 )); then BAR_CLR="$YLW"
else                           BAR_CLR="$GRN"
fi

bar="${BAR_CLR}"
for (( i=0; i<filled; i++ )); do bar+="█"; done
bar+="${GRY}"
for (( i=0; i<empty;  i++ )); do bar+="░"; done
bar+="${RST}"

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
  "${GRY}ctx ${RST}${bar} ${BOLD}${BAR_CLR}${ctx_pct}%%${RST} ${DIM}(${ctx_size_k}k)${RST}" \
  "${GRY} │ ${RST}" \
  "${DIM}${session_short}${RST}" \
  "${GRY} │ ${RST}" \
  "${DIM}${dur_str}${RST}"
echo
