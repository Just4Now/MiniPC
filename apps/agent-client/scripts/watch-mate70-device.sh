#!/bin/zsh

set -u

HDC_BIN="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
LOG_FILTER='CollabController|CollabBroadcaster|CollabControl|SessionBackedModel|ComputeLayers|ModelSetParallelConfig|layerSeg|parallel_settings|runtime_ready|session_ready|session_ended|Start infer|inputTokenCount|outputTokenCount|Prefill latency|Decode latency|Failed to recv emb|RecvToken|Address in use|OH_QoS_Gewu|llmEnableCollaboration|DrvGetL2Info|cppcrash'

RESET=$'\033[0m'
BOLD=$'\033[1m'
GREEN=$'\033[32m'
RED=$'\033[31m'
YELLOW=$'\033[33m'
CYAN=$'\033[36m'
MAGENTA=$'\033[35m'

role="${1:-}"
case "$role" in
  master)
    SERIAL="53V0224C19002918"
    LABEL="[MASTER 2918]"
    COLOR="$CYAN"
    EXPECTED_LAYERS="layers: 0-12"
    ;;
  collaborator|collab)
    SERIAL="53V0224C19002841"
    LABEL="[COLLAB 2841]"
    COLOR="$MAGENTA"
    EXPECTED_LAYERS="layerSeg: 13-27"
    ;;
  *)
    print -P "%F{red}Usage: $0 master|collaborator%f"
    exit 2
    ;;
esac

if [[ ! -x "$HDC_BIN" ]]; then
  print -P "%F{red}HDC not found: $HDC_BIN%f"
  exit 1
fi

print -n -- $'\e]0;Loopy '
print -n -- "${role:u} LLM logs"
print -n -- $'\a'
print "${BOLD}Loopy / Gewu ${role:u} log frontend${RESET}"
print "${COLOR}${LABEL}${RESET} serial=$SERIAL, expected ${EXPECTED_LAYERS}"
print "Green control status plus this device's layer/token logs proves participation."
print "Press Ctrl-C to stop. Existing device logs are not cleared."
print ""

last_control_state=""
stream_pid=""
monitor_pid=""

cleanup() {
  [[ -n "$stream_pid" ]] && kill "$stream_pid" 2>/dev/null || true
  [[ -n "$monitor_pid" ]] && kill "$monitor_pid" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

device_connected() {
  "$HDC_BIN" list targets 2>/dev/null | grep -q "$SERIAL"
}

emit_line() {
  local line="$1"
  local line_color="$COLOR"

  if [[ "$line" == *"layers: 0-12"* || "$line" == *"layerSeg: 13-27"* ||
        "$line" == *"Start infer"* || "$line" == *"Prefill latency"* ||
        "$line" == *"Decode latency"* || "$line" == *"session_ended"* ]]; then
    line_color="$GREEN"
  elif [[ "$line" == *"CollabBroadcaster"* && "$line" == *"failed"* ]]; then
    line_color="$YELLOW"
  elif [[ "$line" == *"failed"* || "$line" == *"error"* || "$line" == *"Error"* ||
          "$line" == *"DrvGetL2Info"* || "$line" == *"cppcrash"* ]]; then
    line_color="$RED"
  fi

  print -r -- "${line_color}${LABEL}${RESET} $line"
}

monitor_control_link() {
  local current_state=""
  while device_connected; do
    if "$HDC_BIN" -t "$SERIAL" shell netstat -an 2>/dev/null |
        grep ':19091 ' | grep -q 'ESTABLISHED'; then
      current_state="connected"
    else
      current_state="disconnected"
    fi

    if [[ "$current_state" != "$last_control_state" ]]; then
      if [[ "$current_state" == "connected" ]]; then
        print -r -- "${GREEN}${LABEL} [CONTROL 19091] CONNECTED${RESET}"
      else
        print -r -- "${RED}${LABEL} [CONTROL 19091] DISCONNECTED${RESET}"
      fi
      last_control_state="$current_state"
    fi
    sleep 3
  done
}

while true; do
  if ! device_connected; then
    if [[ "$last_control_state" != "hdc-disconnected" ]]; then
      print -r -- "${YELLOW}${LABEL} waiting for HDC device $SERIAL ...${RESET}"
      last_control_state="hdc-disconnected"
    fi
    sleep 2
    continue
  fi

  print -r -- "${GREEN}${LABEL} HDC connected; starting hilog stream${RESET}"
  last_control_state=""
  monitor_control_link &
  monitor_pid="$!"

  "$HDC_BIN" -t "$SERIAL" shell hilog 2>&1 |
    rg --line-buffered -i "$LOG_FILTER" |
    while IFS= read -r line; do
      emit_line "$line"
    done &
  stream_pid="$!"
  wait "$stream_pid" 2>/dev/null || true

  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
  stream_pid=""
  monitor_pid=""
  print -r -- "${YELLOW}${LABEL} log stream ended; waiting to reconnect${RESET}"
  sleep 2
done
