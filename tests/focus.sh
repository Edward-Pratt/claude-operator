#!/usr/bin/env bash
# tests/focus.sh: checks scripts/focus.sh picks and focuses the right window on every
# supported compositor, without needing those compositors installed. Each compositor's
# CLI is replaced by a stub that prints a window list in that compositor's JSON shape
# and logs the focus command it receives. The process tree is real: a "terminal" (bash)
# runs a "session" (sleep), and the terminal's pid owns the target window.
# The tmux case uses a real tmux server on a private socket, with a client attached
# under `script` as the terminal. Needs bash, jq, sleep; tmux and script for that case.
set -u
here=$(cd "$(dirname "$0")" && pwd)
focus=$here/../claude-operator/scripts/focus.sh
work=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; [ -n "${sock:-}" ] && tmux -S "$sock" kill-server 2>/dev/null; rm -rf "$work"' EXIT
mkdir -p "$work/bin"
log=$work/focus.log
fails=0

# Test processes get a bare environment: inheriting this shell's KITTY_* or TMUX would
# send focus.sh to the real terminal running the tests.
clean() { env -i PATH=/usr/bin:/bin HOME="$HOME" "$@"; }

# The "terminal" owns the window; the "session" two levels down is what focus.sh gets.
clean bash -c 'bash -c "exec sleep 300" & wait' >/dev/null 2>&1 & term=$!
sleep 0.3
session=$(pgrep -P "$(pgrep -P "$term" | head -n 1)")
[ -n "$session" ] || session=$(pgrep -P "$term" | head -n 1)
decoy=$$ # a window owned by some other process

stub() { # stub NAME BODY
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$work/bin/$1"
  chmod +x "$work/bin/$1"
}
stub hyprctl "case \$1 in
  clients) echo '[{\"pid\":$decoy,\"title\":\"x\",\"class\":\"firefox\",\"address\":\"0xdead\",\"focusHistoryID\":0},
                  {\"pid\":$term,\"title\":\"t\",\"class\":\"foot\",\"address\":\"0xbeef\",\"focusHistoryID\":3}]' ;;
  dispatch) echo \"hyprctl \$2\" >> $log; echo ok ;;
esac"
stub niri "case \"\$*\" in
  '--json windows'|'msg --json windows') echo '[{\"id\":7,\"title\":\"x\",\"app_id\":\"firefox\",\"pid\":$decoy,\"is_focused\":true},
                     {\"id\":12,\"title\":\"t\",\"app_id\":\"foot\",\"pid\":$term,\"is_focused\":false}]' ;;
  *) echo \"niri \$*\" >> $log ;;
esac"
stub swaymsg "if [ \"\$1\" = -t ]; then
  echo '{\"type\":\"root\",\"nodes\":[{\"type\":\"output\",\"nodes\":[{\"type\":\"workspace\",\"nodes\":[
    {\"type\":\"con\",\"id\":4,\"pid\":$decoy,\"name\":\"x\",\"app_id\":\"firefox\",\"focused\":true,\"nodes\":[]},
    {\"type\":\"con\",\"id\":9,\"pid\":$term,\"name\":\"t\",\"app_id\":null,\"window_properties\":{\"class\":\"XTerm\"},\"focused\":false,\"nodes\":[]}]}]}]}'
else echo \"swaymsg \$*\" >> $log; fi"
stub umbriel "case \$1 in
  windows) echo '[{\"id\":\"w1\",\"pid\":$decoy,\"title\":\"x\"},{\"id\":\"w2\",\"pid\":$term,\"title\":\"t\"}]' ;;
  msg) echo \"umbriel \$2\" >> $log ;;
esac"

check() { # check NAME EXPECTED [ENV...]
  local name=$1 want=$2; shift 2
  : > "$log"
  env -i PATH="$work/bin:/usr/bin:/bin" HOME="$HOME" "$@" bash "$focus" "${target:-$session}"
  local code=$? got
  got=$(head -n 1 "$log")
  if [ "$want" = FAIL ]; then
    [ $code -ne 0 ] && echo "ok   $name (exit $code, as expected)" || { echo "FAIL $name: expected failure, got: $got"; fails=$((fails + 1)); }
  elif [ $code -eq 0 ] && [ "$got" = "$want" ]; then
    echo "ok   $name: $got"
  else
    echo "FAIL $name: exit $code, wanted '$want', got '$got'"; fails=$((fails + 1))
  fi
}

check hyprland 'hyprctl hl.dsp.focus({ window = "address:0xbeef" })' HYPRLAND_INSTANCE_SIGNATURE=x
check niri 'niri msg action focus-window --id 12' NIRI_SOCKET=/x
check sway 'swaymsg [con_id=9] focus' SWAYSOCK=/x
check umbriel 'umbriel window-focus:w2'
rm "$work/bin/umbriel"
check unsupported FAIL

# tmux: the session runs in a pane; the window belongs to the terminal of its client.
if command -v tmux >/dev/null && command -v script >/dev/null; then
  sock=$work/tmux.sock
  clean tmux -S "$sock" -f /dev/null new-session -d -s t 'sleep 300'
  tmux -S "$sock" new-window -t t: 'sleep 301' # the session's pane is not the current one
  pane_pid=$(tmux -S "$sock" list-panes -t t:0 -F '#{pane_pid}')
  clean TERM=xterm script -q -c "tmux -S $sock attach -t t" /dev/null </dev/null >/dev/null 2>&1 & client_term=$!
  sleep 0.5
  stub hyprctl "case \$1 in
    clients) echo '[{\"pid\":$client_term,\"title\":\"t\",\"class\":\"foot\",\"address\":\"0xcafe\",\"focusHistoryID\":1}]' ;;
    dispatch) echo \"hyprctl \$2\" >> $log; echo ok ;;
  esac"
  target=$pane_pid check tmux 'hyprctl hl.dsp.focus({ window = "address:0xcafe" })' HYPRLAND_INSTANCE_SIGNATURE=x
  active=$(tmux -S "$sock" display-message -p -t t '#{pane_pid}')
  [ "$active" = "$pane_pid" ] && echo "ok   tmux selected the session's pane" \
    || { echo "FAIL tmux: active pane $active, wanted $pane_pid"; fails=$((fails + 1)); }
else
  echo "skip tmux (needs tmux and script)"
fi

[ $fails -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
