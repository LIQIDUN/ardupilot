#!/bin/bash
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
STATE_DIR="$HOME/.local/state/arducopter-motor-fault"
TMUX_SESSION=motor_fault_mavproxy

if [[ ! -e "$STATE_DIR" ]]; then
    printf '没有本脚本启动的仿真。\n'
    exit 0
fi
[[ -O "$STATE_DIR" && ! -L "$STATE_DIR" ]] || { printf '拒绝使用非本用户的状态目录或符号链接。\n' >&2; exit 1; }
umask 077
exec 9>"$STATE_DIR/lock"
flock 9
if [[ ! -s "$STATE_DIR/active" ]]; then
    printf '没有本脚本启动的仿真。\n'
    exit 0
fi
IFS= read -r run_id <"$STATE_DIR/active"
[[ "$run_id" == "$REPO_DIR/"run.???????? ]] || { printf '运行记录不属于本仓库；未发送信号。\n' >&2; exit 1; }

python3 - "$run_id" <<'PY'
import os
import signal
import sys
import time

import psutil

run_id = sys.argv[1]
owner = os.getuid()
excluded = {os.getpid(), os.getppid()}


def members():
    for proc in psutil.process_iter(("uids", "status", "environ")):
        info = proc.info
        if (proc.pid not in excluded and info["uids"] and info["uids"].real == owner
                and info["status"] != psutil.STATUS_ZOMBIE
                and (info["environ"] or {}).get("MOTOR_FAULT_SITL_RUN_ID") == run_id):
            yield proc


for sig, grace in ((signal.SIGTERM, 5), (signal.SIGKILL, 3)):
    sent = set()
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        running = list(members())
        if not running:
            time.sleep(0.2)
            if not list(members()):
                sys.exit(0)
            continue
        for proc in running:
            if proc not in sent:
                try:
                    proc.send_signal(sig)
                except psutil.NoSuchProcess:
                    pass
                except psutil.AccessDenied as exc:
                    print(exc, file=sys.stderr)
                sent.add(proc)
        time.sleep(0.2)

remaining = list(members())
if remaining:
    sys.exit(f"仍有本次运行的进程未退出：{[proc.pid for proc in remaining]}")
PY

if [[ $(tmux show-environment -t "=$TMUX_SESSION" MOTOR_FAULT_SITL_RUN_ID 2>/dev/null) == "MOTOR_FAULT_SITL_RUN_ID=$run_id" ]]; then
    tmux kill-session -t "=$TMUX_SESSION"
fi

: >"$STATE_DIR/active"
tcp_busy=$(ss -H -ltn '( sport = :11345 or sport = :5760 or sport = :5762 or sport = :5763 or sport = :5765 or sport = :5766 or sport = :5767 or sport = :5768 )')
udp_busy=$(ss -H -aun '( sport = :5501 or sport = :9002 or sport = :9003 or sport = :9005 or sport = :14550 )')
if [[ -n "$tcp_busy$udp_busy" ]]; then
    printf '本次标记的进程已退出，但仍检测到端口占用；未影响其他进程：\n%s\n%s\n' "$tcp_busy" "$udp_busy" >&2
    exit 1
fi
printf '本次仿真进程已关闭，端口已释放；保留参数与日志。\n'
