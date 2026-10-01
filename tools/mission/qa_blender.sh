#!/usr/bin/env bash
# Start, drive and inspect a long-running headless Sightline host (tools/mission/qa_host.py).
#
#   tools/mission/qa_blender.sh start [--port 47000] [--bind 127.0.0.1] [--scene qa|factory] [--blend FILE]
#                                     [--no-video] [--no-pairing]   # default: the coloured QA scene
#   tools/mission/qa_blender.sh status              # host.json, and whether its Blender is alive
#   tools/mission/qa_blender.sh state               # state.json (refreshed at ~5 Hz)
#   tools/mission/qa_blender.sh cmd '<json>' [timeout_s]   # e.g. '{"cmd":"set","prop":"stream_resolution","value":"720p"}'
#   tools/mission/qa_blender.sh drive [fake iPhone args]   # e.g. --linger 20 --scale 10
#   tools/mission/qa_blender.sh logs [host|stdout|fake] [lines]
#   tools/mission/qa_blender.sh stop
#
# Files live in .mission/qa/ (host.json, state.json, cmd/) and .mission/logs/ (qa-host.log,
# qa-blender-stdout.log, qa-fake-iphone.log). The command list and file formats are documented at
# the top of qa_host.py. Run tools/mission/setup.sh first (and again after changing BlenderAddOn/).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
export MISSION_DIR

QA_DIR="${MISSION_DIR}/qa"
CMD_DIR="${QA_DIR}/cmd"
HOST_JSON="${QA_DIR}/host.json"
STATE_JSON="${QA_DIR}/state.json"
PID_FILE="${QA_DIR}/blender.pid"
HOST_LOG="${LOG_DIR}/qa-host.log"
STDOUT_LOG="${LOG_DIR}/qa-blender-stdout.log"
FAKE_LOG="${LOG_DIR}/qa-fake-iphone.log"
FAKE_KEY="${QA_DIR}/fake-iphone.key"
FAKE_FRAME="${QA_DIR}/fake-iphone-frame.jpg"
START_TIMEOUT="${QA_START_TIMEOUT:-60}"
CMD_TIMEOUT="${QA_CMD_TIMEOUT:-30}"
if [ -x "${VENV}/bin/python" ]; then PY="${VENV}/bin/python"; else PY="python3"; fi

ME="tools/mission/qa_blender.sh"

# redact: stdin to stdout with the home directory as ~ and this machine's host name as <host>,
# like the add-on's log (Blender's own stdout and the fake iPhone's errors aren't redacted).
redact() {
  "${PY}" -c '
import os, platform, re, socket, sys
text = sys.stdin.read()
home = os.path.expanduser("~")
if home not in ("", "/"):
    text = text.replace(home, "~")
names = set()
for name in (socket.gethostname(), platform.node()):
    if name:
        short = name.split(".")[0]
        names.update({name, short, short + ".local"})
names.discard("localhost")
for name in sorted(names, key=len, reverse=True):
    text = re.sub(r"(?<![\w-])" + re.escape(name) + r"(?![\w-])", "<host>", text, flags=re.I)
sys.stdout.write(text)
'
}

die() { echo "qa_blender: $*" | redact >&2; exit 1; }

# json_get FILE KEY: a top-level value, empty for null or a missing key/file.
json_get() {
  [ -f "$1" ] || return 0
  "${PY}" - "$1" "$2" <<'EOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        value = json.load(f).get(sys.argv[2])
except (OSError, ValueError):
    value = None
print("" if value is None else value)
EOF
}

host_pid() {
  local pid
  pid="$(json_get "${HOST_JSON}" pid)"
  [ -n "${pid}" ] || { [ -f "${PID_FILE}" ] && pid="$(cat "${PID_FILE}")"; } || true
  echo "${pid}"
}

# pid_alive PID: the process exists and is a Blender (guards against a reused pid).
pid_alive() {
  [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null || return 1
  local comm
  comm="$(ps -p "$1" -o comm= 2>/dev/null)" || return 1
  case "$(basename "${comm}")" in Blender | blender) return 0 ;; *) return 1 ;; esac
}

running() { pid_alive "$(host_pid)"; }

tail_logs() {
  local f
  for f in "${STDOUT_LOG}" "${HOST_LOG}"; do
    [ -f "${f}" ] && { echo "--- ${f#"${ROOT}/"} (last ${1:-30} lines)"; tail -n "${1:-30}" "${f}" | redact; }
  done
  return 0
}

cmd_start() {
  if running; then
    die "already running (pid $(host_pid)); run: ${ME} stop"
  fi
  [ -d "${BLENDER_USER_RESOURCES}/extensions" ] || die "no installed extension: run tools/mission/setup.sh"
  mkdir -p "${CMD_DIR}"
  rm -f "${HOST_JSON}" "${STATE_JSON}" "${PID_FILE}" "${CMD_DIR}"/*.json "${CMD_DIR}"/*.tmp
  nohup "${BLENDER}" --background --factory-startup --python-exit-code 1 \
    --python "${ROOT}/tools/mission/qa_host.py" -- "$@" > "${STDOUT_LOG}" 2>&1 < /dev/null &
  local pid=$! deadline=$((SECONDS + START_TIMEOUT)) state
  echo "${pid}" > "${PID_FILE}"
  while [ "${SECONDS}" -lt "${deadline}" ]; do
    state="$(json_get "${HOST_JSON}" state)"
    if [ "${state}" = "running" ]; then
      cat "${HOST_JSON}"
      return 0
    fi
    if [ "${state}" = "failed" ] || ! kill -0 "${pid}" 2>/dev/null; then
      [ -f "${HOST_JSON}" ] && cat "${HOST_JSON}"
      tail_logs
      die "the host did not start"
    fi
    sleep 0.2
  done
  kill "${pid}" 2>/dev/null || true
  tail_logs
  die "timed out after ${START_TIMEOUT} s waiting for ${HOST_JSON#"${ROOT}/"}"
}

cmd_status() {
  [ -f "${HOST_JSON}" ] || { echo "no host.json: not started"; return 1; }
  cat "${HOST_JSON}"
  local pid
  pid="$(host_pid)"
  if pid_alive "${pid}"; then echo "pid ${pid}: alive"; else echo "pid ${pid:-?}: not running"; return 1; fi
}

cmd_state() {
  [ -f "${STATE_JSON}" ] || die "no state.json: start the host first"
  cat "${STATE_JSON}"
}

# enqueue JSON [TIMEOUT]: prints the result; non-zero exit when it isn't ok.
cmd_cmd() {
  [ $# -ge 1 ] || die "usage: ${ME} cmd '<json>' [timeout_s]"
  local json="$1" timeout="${2:-${CMD_TIMEOUT}}"
  running || die "the host is not running; run: ${ME} start"
  "${PY}" -c 'import json, sys; c = json.loads(sys.argv[1]); assert isinstance(c, dict) and "cmd" in c' "${json}" \
    2>/dev/null || die "not a JSON command object with a \"cmd\": ${json}"
  mkdir -p "${CMD_DIR}"
  local name
  name="$(date +%Y%m%d-%H%M%S)-$$-${RANDOM}"
  printf '%s\n' "${json}" > "${CMD_DIR}/${name}.json.tmp"
  mv "${CMD_DIR}/${name}.json.tmp" "${CMD_DIR}/${name}.json"
  local result="${CMD_DIR}/${name}.result.json" deadline=$((SECONDS + timeout))
  while [ ! -f "${result}" ]; do
    if [ "${SECONDS}" -ge "${deadline}" ] || ! running; then
      rm -f "${CMD_DIR}/${name}.json"
      die "no result after ${timeout} s (host $(running && echo alive || echo not running))"
    fi
    sleep 0.05
  done
  cat "${result}"
  local ok
  ok="$(json_get "${result}" ok)"
  rm -f "${result}"
  [ "${ok}" = "True" ]
}

# drive [ARGS]: runs the fake iPhone against the host, reusing its stored pairing if there is one.
cmd_drive() {
  running || die "the host is not running; run: ${ME} start"
  [ -x "${FAKE_IPHONE}" ] || die "no fake iPhone at ${FAKE_IPHONE#"${ROOT}/"}: run tools/mission/setup.sh"
  local port bind code has_code=0 a
  port="$(json_get "${HOST_JSON}" port)"
  bind="$(json_get "${HOST_JSON}" bind)"
  case "${bind}" in "" | 0.0.0.0) bind=127.0.0.1 ;; esac
  for a in "$@"; do [ "${a}" = "--code" ] && has_code=1; done
  # The fake iPhone takes the last value of a repeated flag, so the caller's args override these.
  local args=(--host "${bind}:${port}" --state "${FAKE_KEY}" --motion "${ROOT}/testdata/motion/scripted.bin"
    --rate 60 --linger 1 --video-out "${FAKE_FRAME}")
  local paired_before=0
  if [ "${has_code}" = 0 ]; then
    if [ -f "${FAKE_KEY}" ]; then
      paired_before=1
    else
      code="$(json_get "${HOST_JSON}" pairing_code)"
      [ -n "${code}" ] || code="$(cmd_cmd '{"cmd":"pair"}' > /dev/null && json_get "${HOST_JSON}" pairing_code)"
      [ -n "${code}" ] || die "no pairing code from the host"
      args+=(--code "${code}")
    fi
  fi
  echo "== fake iPhone $(date +%Y-%m-%dT%H:%M:%S) stored_pairing=${paired_before}" > "${FAKE_LOG}"
  local status=0
  "${FAKE_IPHONE}" "${args[@]}" "$@" >> "${FAKE_LOG}" 2>&1 || status=$?
  if [ "${status}" -ne 0 ] && [ "${paired_before}" = 1 ]; then
    # A stored key the host no longer knows (setup.sh reinstalls the extension, which drops its
    # pairings): pair again with a fresh code.
    echo "== stored pairing failed (exit ${status}); pairing again" >> "${FAKE_LOG}"
    rm -f "${FAKE_KEY}"
    code="$(cmd_cmd '{"cmd":"pair"}' > /dev/null && json_get "${HOST_JSON}" pairing_code)"
    [ -n "${code}" ] || die "no pairing code from the host"
    status=0
    "${FAKE_IPHONE}" "${args[@]}" --code "${code}" "$@" >> "${FAKE_LOG}" 2>&1 || status=$?
  fi
  grep -E '^FAKE_IPHONE_(PAIRED|SESSION)' "${FAKE_LOG}" || true
  if [ "${status}" -ne 0 ]; then
    tail -n 20 "${FAKE_LOG}" | redact >&2
    die "fake iPhone exited ${status} (log: ${FAKE_LOG#"${ROOT}/"})"
  fi
  grep '^FAKE_IPHONE_DONE' "${FAKE_LOG}" | tail -1
  [ -f "${FAKE_FRAME}" ] && echo "newest frame: ${FAKE_FRAME#"${ROOT}/"}"
  return 0
}

cmd_logs() {
  local which="${1:-all}" lines="${2:-40}" f
  case "${which}" in
    host) f="${HOST_LOG}" ;;
    stdout) f="${STDOUT_LOG}" ;;
    fake) f="${FAKE_LOG}" ;;
    all)
      for f in "${HOST_LOG}" "${STDOUT_LOG}" "${FAKE_LOG}"; do
        [ -f "${f}" ] && { echo "--- ${f#"${ROOT}/"}"; tail -n "${lines}" "${f}" | redact; }
      done
      return 0 ;;
    *) die "logs: host, stdout, fake or all" ;;
  esac
  [ -f "${f}" ] || die "no ${f#"${ROOT}/"}"
  tail -n "${lines}" "${f}" | redact
}

cmd_stop() {
  local pid
  pid="$(host_pid)"
  if ! pid_alive "${pid}"; then
    echo "not running"
    return 0
  fi
  cmd_cmd '{"cmd":"stop"}' 10 > /dev/null || true
  local deadline=$((SECONDS + 15))
  while pid_alive "${pid}" && [ "${SECONDS}" -lt "${deadline}" ]; do sleep 0.2; done
  if pid_alive "${pid}"; then
    echo "no clean exit; sending SIGTERM" >&2
    kill -TERM "${pid}" 2>/dev/null || true
    deadline=$((SECONDS + 5))
    while pid_alive "${pid}" && [ "${SECONDS}" -lt "${deadline}" ]; do sleep 0.2; done
  fi
  if pid_alive "${pid}"; then
    echo "still alive; sending SIGKILL" >&2
    kill -KILL "${pid}" 2>/dev/null || true
  fi
  rm -f "${PID_FILE}"
  echo "stopped (pid ${pid}); host state: $(json_get "${HOST_JSON}" state)"
}

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

sub="${1:-}"
[ $# -gt 0 ] && shift
case "${sub}" in
  start | status | state | cmd | drive | logs | stop) "cmd_${sub}" "$@" ;;
  -h | --help | help | "") usage ;;
  *) usage >&2; exit 2 ;;
esac
