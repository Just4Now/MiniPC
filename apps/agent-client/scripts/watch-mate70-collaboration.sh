#!/bin/zsh

set -u

HDC_BIN="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
MASTER_SERIAL="53V0224C19002918"
COLLABORATOR_SERIAL="53V0224C19002841"
LOG_FILTER='CollabController|CollabBroadcaster|CollabControl|SessionBackedModel|ComputeLayers|ModelSetParallelConfig|layerSeg|parallel_settings|runtime_ready|session_ready|session_ended|Start infer|inputTokenCount|outputTokenCount|Prefill latency|Decode latency|Failed to recv emb|RecvToken|Address in use|OH_QoS_Gewu|llmEnableCollaboration|DrvGetL2Info|cppcrash'

RESET=$'\033[0m'
BOLD=$'\033[1m'
CYAN=$'\033[36m'
MAGENTA=$'\033[35m'
GREEN=$'\033[32m'
RED=$'\033[31m'
YELLOW=$'\033[33m'

if [[ ! -x "$HDC_BIN" ]]; then
  print -P "%F{red}HDC not found: $HDC_BIN%f"
  exit 1
fi

connected_targets="$($HDC_BIN list targets 2>/dev/null)"
for serial in "$MASTER_SERIAL" "$COLLABORATOR_SERIAL"; do
  if ! print -r -- "$connected_targets" | grep -q "$serial"; then
    print -P "%F{red}Device is not connected: $serial%f"
    exit 1
  fi
done

print "${BOLD}Loopy / Gewu dual-Mate70 collaboration log${RESET}"
print "${CYAN}[MASTER 2918]${RESET} serial=$MASTER_SERIAL, expected layers=0-12"
print "${MAGENTA}[COLLAB 2841]${RESET} serial=$COLLABORATOR_SERIAL, expected layers=13-27"
print ""
print "${GREEN}Collaboration proof:${RESET} one request must show Start infer on both devices,"
print "plus ${CYAN}layers: 0-12${RESET} on MASTER and ${MAGENTA}layerSeg: 13-27${RESET} on COLLAB."
print "A completed round must also show matching inputTokenCount and session_ended."
print "Open Loopy on both phones, keep COLLAB awake, then send a prompt on MASTER."
print "Press Ctrl-C here to stop watching. Existing device logs are not cleared."
print ""

children=()
cleaned_up=false

cleanup() {
  if [[ "$cleaned_up" == true ]]; then
    return
  fi
  cleaned_up=true
  print ""
  print "${YELLOW}Stopping dual-device log streams...${RESET}"
  for pid in "${children[@]}"; do
    for child_pid in "${(@f)$(pgrep -P "$pid" 2>/dev/null)}"; do
      kill "$child_pid" 2>/dev/null || true
    done
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup INT TERM EXIT

emit_line() {
  local label="$1"
  local base_color="$2"
  local line="$3"
  local line_color="$base_color"

  if [[ "$line" == *"layers: 0-12"* || "$line" == *"layerSeg: 13-27"* ||
        "$line" == *"Start infer"* || "$line" == *"Prefill latency"* ||
        "$line" == *"Decode latency"* || "$line" == *"session_ended"* ]]; then
    line_color="$GREEN"
  elif [[ "$line" == *"CollabBroadcaster"* && "$line" == *"failed"* ]]; then
    # UDP broadcast is only a fallback on Mate hotspot topologies. The TCP
    # control channel below is authoritative, so do not paint this expected
    # broadcast restriction as a collaboration failure.
    line_color="$YELLOW"
  elif [[ "$line" == *"failed"* || "$line" == *"error"* || "$line" == *"Error"* ||
          "$line" == *"DrvGetL2Info"* || "$line" == *"cppcrash"* ]]; then
    line_color="$RED"
  fi

  print -r -- "${line_color}${label}${RESET} $line"
}

watch_device() {
  local serial="$1"
  local label="$2"
  local color="$3"

  while true; do
    print -r -- "${color}${label}${RESET} log stream connected"
    "$HDC_BIN" -t "$serial" shell hilog 2>&1 |
      rg --line-buffered -i "$LOG_FILTER" |
      while IFS= read -r line; do
        emit_line "$label" "$color" "$line"
      done
    print -r -- "${RED}${label}${RESET} log stream ended; retrying in 2 seconds"
    sleep 2
  done
}

monitor_control_link() {
  local previous_state=''
  local current_state=''

  while true; do
    local master_socket=''
    local collaborator_socket=''
    master_socket="$($HDC_BIN -t "$MASTER_SERIAL" shell netstat -an 2>/dev/null | grep ':19091 ' | grep 'ESTABLISHED' || true)"
    collaborator_socket="$($HDC_BIN -t "$COLLABORATOR_SERIAL" shell netstat -an 2>/dev/null | grep ':19091 ' | grep 'ESTABLISHED' || true)"
    if [[ -n "$master_socket" && -n "$collaborator_socket" ]]; then
      current_state='connected'
    else
      current_state='disconnected'
    fi

    if [[ "$current_state" != "$previous_state" ]]; then
      if [[ "$current_state" == 'connected' ]]; then
        print -r -- "${GREEN}[CONTROL 19091] CONNECTED${RESET} master and collaborator sockets are established"
      else
        print -r -- "${RED}[CONTROL 19091] DISCONNECTED${RESET} do not trust a master-only answer; bring COLLAB Loopy to foreground"
      fi
      previous_state="$current_state"
    fi
    sleep 3
  done
}

watch_device "$MASTER_SERIAL" "[MASTER 2918]" "$CYAN" &
children+=("$!")
watch_device "$COLLABORATOR_SERIAL" "[COLLAB 2841]" "$MAGENTA" &
children+=("$!")
monitor_control_link &
children+=("$!")

wait
