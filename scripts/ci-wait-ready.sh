#!/usr/bin/env bash
# 供 ci-e2e.sh 和离线测试共同使用；只读本次进程的输出，不读持久化日志。
wait_for_stox_ready() {
  local pid="$1" output="$2" seconds="${3:-20}" deadline
  case "$seconds" in
    ''|*[!0-9]*) echo "Invalid readiness timeout: $seconds" >&2; return 2 ;;
  esac
  seconds=$((10#$seconds))
  deadline=$((SECONDS + seconds))
  while :; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "Stox exited before diagnostics were ready" >&2
      return 1
    fi
    if grep -qxF 'STOX_DIAG late ready=true' "$output" 2>/dev/null; then
      return 0
    fi
    if (( SECONDS >= deadline )); then
      echo "Timed out after ${seconds}s waiting for Stox diagnostics" >&2
      return 1
    fi
    sleep 0.2
  done
}
