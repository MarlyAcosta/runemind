# Ritual interface for Runemind: colors, runes, trees, prompts, spinners and progress bars.
# Sourced by bin/rune and install.sh. Compatible with bash 3.2 (macOS) and later.
# Glyphs and palette are read by the scripts that source this file.
# shellcheck shell=bash disable=SC2034

RM_TTY=0
[ -t 1 ] && RM_TTY=1

rm_detect_color() {
  if [ -n "${NO_COLOR:-}" ] || [ "$RM_TTY" = 0 ] || [ "${TERM:-dumb}" = dumb ]; then
    echo none; return
  fi
  case "${COLORTERM:-}" in truecolor|24bit) echo truecolor; return ;; esac
  case "${TERM_PROGRAM:-}" in iTerm.app|WezTerm|vscode|ghostty) echo truecolor; return ;; esac
  [ -n "${WT_SESSION:-}" ] && { echo truecolor; return; }
  local n
  n="$(tput colors 2>/dev/null || echo 8)"
  if [ "${n:-8}" -ge 256 ]; then echo 256; else echo 8; fi
}
RM_COLOR="${RUNEMIND_COLOR:-$(rm_detect_color)}"

rm_detect_runes() {
  [ "${RUNEMIND_RUNES:-}" = 0 ] && { echo 0; return; }
  [ "${RUNEMIND_RUNES:-}" = 1 ] && { echo 1; return; }
  if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/runemind/config" ] && grep -q '^runes=0' "${XDG_CONFIG_HOME:-$HOME/.config}/runemind/config"; then
    echo 0; return
  fi
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *UTF-8*|*utf8*|*UTF8*|*utf-8*) echo 1 ;; *) echo 0 ;; esac
}
RM_RUNES="$(rm_detect_runes)"

if [ "$RM_RUNES" = 1 ]; then
  RM_FUTHARK=(ᚠ ᚢ ᚦ ᚨ ᚱ ᚲ ᚷ ᚹ ᚺ ᚾ ᛁ ᛃ ᛇ ᛈ ᛉ ᛊ ᛏ ᛒ ᛖ ᛗ ᛚ ᛜ ᛞ ᛟ)
  G_DONE="ᛋ"; G_TODO="ᚲ"; G_FAIL="ᚾ"; G_STAR="✦"; G_SEAL="ᛉ"; G_ROOT="ᚱ"; G_PICK="◆"; G_SKIP="◇"
  G_RUNES_FWD="ᚱ ᚢ ᚾ ᛖ ᛗ ᛁ ᚾ ᛞ"; G_RUNES_BACK="ᛞ ᚾ ᛁ ᛗ ᛖ ᚾ ᚢ ᚱ"
  G_SPARKS=(✦ ✧ ⋆ ✶); G_FULL="▰"; G_EMPTY="▱"; G_CORNER="✧"
else
  RM_FUTHARK=('|' '/' '-' '\\')
  G_DONE="✓"; G_TODO="○"; G_FAIL="✗"; G_STAR="*"; G_SEAL="!"; G_ROOT="*"; G_PICK="◆"; G_SKIP="◇"
  G_RUNES_FWD="R U N E M I N D"; G_RUNES_BACK="D N I M E N U R"
  G_SPARKS=('*' '+' 'x' '+'); G_FULL="#"; G_EMPTY="-"; G_CORNER="+"
fi

# Palette (r g b)
P_BLUE="79 195 255"; P_GOLD="242 199 92"; P_DIM="108 120 149"; P_WHITE="255 255 255"
P_RED="255 122 122"; P_AMBER="255 181 71"; P_MAG="255 79 216"; P_GREEN="94 230 160"; P_DARK="38 48 76"

rm_esc() {
  # rm_esc r g b -> foreground escape for the current color mode
  case "$RM_COLOR" in
    none) return ;;
    truecolor) printf '\033[38;2;%d;%d;%dm' "$1" "$2" "$3" ;;
    256) printf '\033[38;5;%dm' $(( 16 + 36 * (($1 * 5 + 127) / 255) + 6 * (($2 * 5 + 127) / 255) + (($3 * 5 + 127) / 255) )) ;;
    *)
      if [ "$1" -gt 200 ] && [ "$2" -gt 150 ] && [ "$3" -lt 140 ]; then printf '\033[33m'
      elif [ "$1" -gt 200 ] && [ "$3" -gt 150 ] && [ "$2" -lt 140 ]; then printf '\033[35m'
      elif [ "$1" -gt 200 ] && [ "$2" -lt 160 ]; then printf '\033[31m'
      elif [ "$3" -gt 200 ]; then printf '\033[36m'
      elif [ "$2" -gt 200 ]; then printf '\033[32m'
      else printf '\033[90m'; fi ;;
  esac
}
rm_reset() { [ "$RM_COLOR" = none ] || printf '\033[0m'; }
rm_bold() { [ "$RM_COLOR" = none ] || printf '\033[1m'; }

# rm_c "r g b" text  -> colored text
rm_c() { local rgb="$1"; shift; printf '%s%s%s' "$(rm_esc $rgb)" "$*" "$(rm_reset)"; }
rm_dim() { rm_c "$P_DIM" "$*"; }
rm_gold() { rm_c "$P_GOLD" "$*"; }
rm_blue() { rm_c "$P_BLUE" "$*"; }
rm_strong() { printf '%s%s%s' "$(rm_bold)" "$*" "$(rm_reset)"; }

# rm_grad text [from] [to] -> per-character gradient
rm_grad() {
  local text="$1" from="${2:-$P_BLUE}" to="${3:-$P_GOLD}"
  if [ "$RM_COLOR" = none ] || [ "$RM_COLOR" = 8 ]; then printf '%s' "$text"; return; fi
  set -- $from; local r1=$1 g1=$2 b1=$3
  set -- $to; local r2=$1 g2=$2 b2=$3
  local len=${#text} n i=0 ch out=""
  n=$(( len > 1 ? len - 1 : 1 ))
  while [ "$i" -lt "$len" ]; do
    ch="${text:$i:1}"
    if [ "$ch" = " " ]; then out="$out "; else
      out="$out$(rm_esc $(( r1 + (r2 - r1) * i / n )) $(( g1 + (g2 - g1) * i / n )) $(( b1 + (b2 - b1) * i / n )))$ch"
    fi
    i=$((i + 1))
  done
  printf '%s%s' "$out" "$(rm_reset)"
}

rm_rune_at() { printf '%s' "${RM_FUTHARK[$(( $1 % ${#RM_FUTHARK[@]} ))]}"; }

# ---------- Building blocks ----------

rm_line() { printf '%s\n' "$*"; }
rm_head() { rm_line "  $(rm_gold "$G_STAR") $(rm_strong "$1")${2:+   $(rm_dim "$2")}"; }
rm_root() { rm_line "  $(rm_gold "${1:-$G_ROOT}")$(rm_dim "━━┓")${2:+ $(rm_dim "$2")}"; }
rm_branch() { rm_line "     $(rm_dim "┣━") $*"; }
rm_last() { rm_line "     $(rm_dim "┗━") $*"; }
rm_cont() { rm_line "     $(rm_dim "┃")  $*"; }
rm_done_txt() { printf '%s %s%s' "$(rm_gold "$G_DONE")" "$1" "${2:+  $(rm_dim "$2")}"; }
rm_todo_txt() { printf '%s%s' "$(rm_dim "$G_TODO $1")" "${2:+  $(rm_dim "$2")}"; }
rm_fail_txt() { printf '%s %s  %s' "$(rm_c "$P_RED" "$G_FAIL")" "$(rm_strong "$1")" "$(rm_c "$P_MAG" "${2:-la runa se quebró}")"; }
rm_warn() { rm_line "  $(rm_c "$P_AMBER" "!") $*"; }
rm_info() { rm_line "  $(rm_dim "·") $*"; }

rm_frame() {
  if [ "$1" = top ]; then
    rm_line "  $(rm_gold "$G_CORNER") $(rm_gold "$G_RUNES_FWD") $(rm_dim "────────────") $(rm_gold "$G_CORNER")"
  else
    rm_line "  $(rm_gold "$G_CORNER") $(rm_dim "────────────") $(rm_gold "$G_RUNES_BACK") $(rm_gold "$G_CORNER")"
  fi
}

rm_logo() {
  local r0="█▀█ █ █ █▄ █ █▀▀ █▀▄▀█ █ █▄ █ █▀▄"
  local r1="█▀▄ █▄█ █ ▀█ ██▄ █ ▀ █ █ █ ▀█ █▄▀"
  rm_frame top
  if [ "$RM_RUNES" = 1 ]; then
    rm_line "  $(rm_grad "$r0")"
    rm_line "  $(rm_grad "$r1")"
  else
    rm_line "  $(rm_grad "R U N E M I N D")"
  fi
  rm_frame bottom
  rm_line "      $(rm_dim "·") $(rm_grad "${1:-el conocimiento de tus agentes, grabado en runas}" "143 208 255" "$P_GOLD") $(rm_dim "·")"
}

rm_seal() {
  # rm_seal "title" line...
  local title="$1"; shift
  rm_frame top
  rm_head "$title"
  rm_root "$G_SEAL"
  local n=$# i=1 l
  for l in "$@"; do
    if [ "$i" = "$n" ]; then rm_last "$l"; else rm_branch "$l"; fi
    i=$((i + 1))
  done
  rm_frame bottom
}

# ---------- Prompts ----------

RM_IN=0
if { exec 3</dev/tty; } 2>/dev/null; then RM_IN=1; fi

rm_ask() {
  # rm_ask "question" [y|n] -> 0 yes / 1 no
  local q="$1" def="${2:-n}" reply hint
  if [ "$RM_IN" != 1 ] || [ "${RM_ASSUME_YES:-0}" = 1 ]; then [ "$def" = y ]; return; fi
  if [ "$def" = y ]; then hint="[S/n]"; else hint="[s/N]"; fi
  printf '  %s %s %s ' "$(rm_gold "$G_STAR")" "$q" "$(rm_dim "$hint")"
  read -r -u 3 reply || reply=""
  reply="${reply:-$def}"
  case "$reply" in s|S|si|sí|Si|Sí|y|Y|yes) return 0 ;; *) return 1 ;; esac
}

rm_read() {
  # rm_read "prompt" var [secret]
  local p="$1" __v=""
  printf '  %s %s ' "$(rm_gold "$G_STAR")" "$p"
  if [ "${3:-}" = secret ]; then read -r -s -u 3 __v || __v=""; printf '\n'; else read -r -u 3 __v || __v=""; fi
  eval "$2=\$__v"
}

# ---------- Live progress ----------

RM_CURSOR_HIDDEN=0
rm_cursor_hide() { if [ "$RM_TTY" = 1 ] && [ "$RM_COLOR" != none ]; then printf '\033[?25l'; RM_CURSOR_HIDDEN=1; fi; }
rm_cursor_show() { if [ "$RM_CURSOR_HIDDEN" = 1 ]; then printf '\033[?25h'; RM_CURSOR_HIDDEN=0; fi; }

rm_cycling_rune() {
  local f="$1" r t
  r="$(rm_rune_at "$f")"
  # oscillate blue <-> gold
  t=$(( (f % 12) < 6 ? (f % 6) : 6 - (f % 6) ))
  set -- $P_BLUE; local r1=$1 g1=$2 b1=$3
  set -- $P_GOLD; local r2=$1 g2=$2 b2=$3
  printf '%s%s%s%s' "$(rm_esc $(( r1 + (r2 - r1) * t / 6 )) $(( g1 + (g2 - g1) * t / 6 )) $(( b1 + (b2 - b1) * t / 6 )))" "$(rm_bold)" "$r" "$(rm_reset)"
}

rm_bar() {
  # rm_bar percent frame -> living energy bar
  local pct="$1" f="$2" cells=22 filled k out="" wave d
  filled=$(( cells * pct / 100 )); [ "$filled" -lt 1 ] && filled=1
  wave=$(( f % (filled + 5) ))
  local spark="${G_SPARKS[$(( f % ${#G_SPARKS[@]} ))]}"
  set -- $P_BLUE; local r1=$1 g1=$2 b1=$3
  set -- $P_GOLD; local r2=$1 g2=$2 b2=$3
  k=0
  while [ "$k" -lt "$cells" ]; do
    if [ "$k" -lt $(( filled - 1 )) ]; then
      local r=$(( r1 + (r2 - r1) * k / (cells - 1) )) g=$(( g1 + (g2 - g1) * k / (cells - 1) )) b=$(( b1 + (b2 - b1) * k / (cells - 1) ))
      d=$(( k > wave ? k - wave : wave - k ))
      if [ "$d" = 0 ]; then r=$(( r + (255 - r) * 7 / 10 )); g=$(( g + (255 - g) * 7 / 10 )); b=$(( b + (255 - b) * 7 / 10 ))
      elif [ "$d" = 1 ]; then r=$(( r + (255 - r) * 35 / 100 )); g=$(( g + (255 - g) * 35 / 100 )); b=$(( b + (255 - b) * 35 / 100 )); fi
      out="$out$(rm_esc $r $g $b)$G_FULL"
    elif [ "$k" = $(( filled - 1 )) ]; then
      if [ "$pct" -ge 100 ]; then out="$out$(rm_esc $P_GOLD)$G_FULL"; else out="$out$(rm_esc $P_WHITE)$(rm_bold)$spark$(rm_reset)"; fi
    else
      if [ $(( k - filled )) -lt 3 ] && [ $(( (f * 7 + k * 3) % 5 )) = 0 ]; then out="$out$(rm_esc 94 134 196)$G_EMPTY"; else out="$out$(rm_esc $P_DARK)$G_EMPTY"; fi
    fi
    k=$((k + 1))
  done
  printf '%s%s' "$out" "$(rm_reset)"
}

RM_LOG="${RM_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/runemind/last.log}"
mkdir -p "$(dirname "$RM_LOG")" 2>/dev/null || true

rm_elapsed() { local s="$1"; if [ "$s" -ge 60 ]; then printf '%dm %ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi; }

rm_run() {
  # rm_run "label" [last] -- command...   Runs the command with its output in the log, animating a cycling rune.
  local label="$1" last="${2:-}"; shift 2
  [ "${1:-}" = "--" ] && shift
  local start=$SECONDS st=0 f=0 conn="┣━"
  [ "$last" = last ] && conn="┗━"
  printf '\n### %s\n' "$label" >> "$RM_LOG"
  if [ "$RM_TTY" = 0 ] || [ "$RM_COLOR" = none ]; then
    printf '     %s %s ... ' "$conn" "$label"
    "$@" >> "$RM_LOG" 2>&1 || st=$?
    if [ "$st" = 0 ]; then printf 'ok (%s)\n' "$(rm_elapsed $((SECONDS - start)))"; else printf 'FALLÓ\n'; fi
    return "$st"
  fi
  "$@" >> "$RM_LOG" 2>&1 &
  local pid=$!
  rm_cursor_hide
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\033[K     %s %s %s  %s' "$(rm_dim "$conn")" "$(rm_cycling_rune "$f")" "$(rm_strong "$label")" "$(rm_dim "$(rm_elapsed $((SECONDS - start)))")"
    f=$((f + 1)); sleep 0.15
  done
  wait "$pid" || st=$?
  rm_cursor_show
  if [ "$st" = 0 ]; then
    printf '\r\033[K     %s %s\n' "$(rm_dim "$conn")" "$(rm_done_txt "$label" "$(rm_elapsed $((SECONDS - start)))")"
  else
    printf '\r\033[K     %s %s\n' "$(rm_dim "$conn")" "$(rm_fail_txt "$label")"
  fi
  return "$st"
}

rm_download() {
  # rm_download url dest "label" -> curl with a living bar driven by the real file size
  local url="$1" dest="$2" label="$3" total=0 size=0 pct=0 f=0 st=0 start=$SECONDS
  total="$(curl -fsSIL --retry 2 "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}')"
  printf '\n### download %s\n' "$url" >> "$RM_LOG"
  if [ "$RM_TTY" = 0 ] || [ "$RM_COLOR" = none ] || [ "${total:-0}" -le 0 ]; then
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 3 --retry-all-errors "$url" -o "$dest" >> "$RM_LOG" 2>&1
    return
  fi
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 3 --retry-all-errors "$url" -o "$dest" >> "$RM_LOG" 2>&1 &
  local pid=$!
  rm_cursor_hide
  printf '     %s %s %s\n\n' "$(rm_dim "┣━")" "$(rm_cycling_rune 0)" "$(rm_strong "$label")"
  while kill -0 "$pid" 2>/dev/null; do
    size=0; [ -f "$dest" ] && size=$(wc -c < "$dest" | tr -d ' ')
    pct=$(( ${size:-0} * 100 / total )); [ "$pct" -gt 99 ] && pct=99
    printf '\033[2A\r\033[K     %s %s %s\n\r\033[K     %s  %s  %s  %s\n' \
      "$(rm_dim "┣━")" "$(rm_cycling_rune "$f")" "$(rm_strong "$label")" \
      "$(rm_dim "┃")" "$(rm_bar "$pct" "$f")" "$(rm_grad "$(printf '%3d%%' "$pct")")" \
      "$(rm_dim "$(( size / 1048576 )) de $(( total / 1048576 )) MB")"
    f=$((f + 1)); sleep 0.15
  done
  wait "$pid" || st=$?
  printf '\033[2A\r\033[K'
  if [ "$st" = 0 ]; then
    printf '     %s %s\n\r\033[K     %s  %s  %s\n' "$(rm_dim "┣━")" "$(rm_done_txt "$label" "$(rm_elapsed $((SECONDS - start)))")" "$(rm_dim "┃")" "$(rm_bar 100 0)" "$(rm_gold "100%")"
  else
    printf '     %s %s\n\r\033[K\n' "$(rm_dim "┣━")" "$(rm_fail_txt "$label")"
  fi
  rm_cursor_show
  return "$st"
}

