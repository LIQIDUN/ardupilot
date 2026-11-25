#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
AUTOTEST="$REPO_DIR/Tools/autotest"
GAZEBO_DIR=/home/liqidun/github/ardupilot_gazebo
WORLD="$GAZEBO_DIR/worlds/iris_ardupilot.world"
CLASSIC_PLUGINS=/usr/lib/x86_64-linux-gnu/gazebo-11/plugins
QGC=/home/liqidun/appimage/QGroundControl.AppImage
STATE_DIR="$HOME/.local/state/arducopter-motor-fault"
TMUX_SESSION=motor_fault_mavproxy

die() { printf '启动失败：%s\n' "$*" >&2; exit 1; }

for command_name in python3 mavproxy.py tmux terminator gazebo gzserver gzclient xterm \
    git gcc g++ ldd ss flock nohup xdpyinfo; do
    command -v "$command_name" >/dev/null || die "缺少依赖：$command_name"
done
[[ -n ${DISPLAY:-} ]] && xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 || die '无法连接 X11 显示。'
python3 -c 'import psutil, pexpect, pymavlink, wx; from importlib.util import find_spec; assert all(find_spec(m) for m in ("MAVProxy.modules.mavproxy_console", "MAVProxy.modules.mavproxy_map"))' \
    || die '缺少 Python 依赖或 MAVProxy Console/Map 模块。'
[[ -x "$QGC" ]] || die "QGroundControl 不可执行：$QGC"
[[ -w "$AUTOTEST" && -x "$REPO_DIR/modules/waf/waf-light" ]] || die 'Tools/autotest 不可写或缺少本仓库的 Waf。'

for required_file in "$AUTOTEST/sim_vehicle.py" \
    "$AUTOTEST/default_params/copter.parm" "$AUTOTEST/default_params/gazebo-iris.parm" \
    "$WORLD" "$GAZEBO_DIR/models/iris_with_standoffs_demo/model.sdf" \
    "$GAZEBO_DIR/models/iris_with_standoffs/model.sdf" \
    "$GAZEBO_DIR/models_gazebo/gimbal_small_2d/model.sdf" \
    "$GAZEBO_DIR/build/libArduPilotPlugin.so" \
    "$CLASSIC_PLUGINS/libLiftDragPlugin.so" "$CLASSIC_PLUGINS/libGimbalSmall2dPlugin.so"; do
    [[ -f "$required_file" && -r "$required_file" ]] || die "找不到或无法读取：$required_file"
done
plugin_libs=$(ldd "$GAZEBO_DIR/build/libArduPilotPlugin.so") || die '无法检查 Classic ArduPilot 插件依赖。'
[[ "$plugin_libs" != *'not found'* ]] || die "Classic ArduPilot 插件缺少动态库：$plugin_libs"

umask 077
mkdir -p -- "$STATE_DIR"
[[ -O "$STATE_DIR" && ! -L "$STATE_DIR" ]] || die "状态目录不属于当前用户或是符号链接：$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || die '另一个启停操作正在进行。'
[[ ! -s "$STATE_DIR/active" ]] || die "已有运行记录；请先执行 $SCRIPT_DIR/stop_motor_fault.sh"
if tmux has-session -t "=$TMUX_SESSION" 2>/dev/null; then
    die "tmux 会话 $TMUX_SESSION 已存在；不会覆盖现有会话。"
fi

tcp_busy=$(ss -H -ltn '( sport = :11345 or sport = :5760 or sport = :5762 or sport = :5763 or sport = :5765 or sport = :5766 or sport = :5767 or sport = :5768 )') || die '无法检查 TCP 端口。'
udp_busy=$(ss -H -aun '( sport = :5501 or sport = :9002 or sport = :9003 or sport = :9005 or sport = :14550 )') || die '无法检查 UDP 端口。'
[[ -z "$tcp_busy$udp_busy" ]] || die "所需端口已被占用：
$tcp_busy
$udp_busy"

run_dir=$(mktemp -d "$STATE_DIR/run.XXXXXXXX")
for log_file in mav.tlog mav.tlog.raw mav.parm; do
    if [[ -f "$AUTOTEST/$log_file" ]]; then
        cp -p -- "$AUTOTEST/$log_file" "$run_dir/$log_file"
    fi
done
run_id="$REPO_DIR/${run_dir##*/}"
printf '%s\n' "$run_id" >"$STATE_DIR/active"

export GAZEBO_MASTER_URI=http://127.0.0.1:11345
export GAZEBO_MODEL_PATH="$GAZEBO_DIR/models:$GAZEBO_DIR/models_gazebo:$AUTOTEST/models:/usr/share/gazebo-11/models${GAZEBO_MODEL_PATH:+:$GAZEBO_MODEL_PATH}"
export GAZEBO_PLUGIN_PATH="$GAZEBO_DIR/build:$CLASSIC_PLUGINS${GAZEBO_PLUGIN_PATH:+:$GAZEBO_PLUGIN_PATH}"
export GAZEBO_MODEL_DATABASE_URI=""

window_pids=()
launch_window() {
    local title=$1 geometry=$2 workdir=$3 stderr_log=$4
    shift 4
    nohup env "MOTOR_FAULT_SITL_RUN_ID=$run_id" terminator -u \
        "--geometry=$geometry" -T "$title" -x env "MOTOR_FAULT_SITL_RUN_ID=$run_id" \
        bash -c 'cd -- "$1" || exit; shift; exec "$@"' _ "$workdir" "$@" \
        >"$run_dir/$stderr_log" 2>&1 </dev/null 9>&- &
    window_pids+=("$!")
}

printf -v pane_log 'cat >> %q' "$run_dir/sitl-window.log"
tmux new-session -d -s "$TMUX_SESSION" -n MAVProxy -c "$AUTOTEST" \
    env "MOTOR_FAULT_SITL_RUN_ID=$run_id" "PATH=$PATH" "DISPLAY=$DISPLAY" \
    "XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}" TMPDIR="$run_dir" \
    SITL_RITW_TERMINAL='xterm -iconic -T MotorFault-ArduCopter -e' \
    python3 sim_vehicle.py -v ArduCopter -f gazebo-iris --console --map \
    --sim-address=127.0.0.1 --no-extra-ports --out=udpout:127.0.0.1:14550 \
    --waf-configure-arg=--no-submodule-update --waf-build-arg=--no-submodule-update \; \
    set-environment -t "=$TMUX_SESSION" MOTOR_FAULT_SITL_RUN_ID "$run_id" \; \
    pipe-pane -t "=$TMUX_SESSION:" "$pane_log" 9>&- \
    || die "无法启动 MAVProxy tmux 会话；请执行 stop_motor_fault.sh 清理。"
launch_window Gazebo 600x400+850+0 "$GAZEBO_DIR/worlds" gazebo-window.log gazebo --verbose "$WORLD"
launch_window QGC 500x300+0+700 "${QGC%/*}" qgc-window.log "$QGC"

for window_pid in "${window_pids[@]}"; do
    for ((attempt=0; attempt<30; attempt++)); do
        if grep -zFxq "MOTOR_FAULT_SITL_RUN_ID=$run_id" "/proc/$window_pid/environ" 2>/dev/null; then
            break
        fi
        kill -0 "$window_pid" 2>/dev/null || break
        sleep 0.1
    done
    grep -zFxq "MOTOR_FAULT_SITL_RUN_ID=$run_id" "/proc/$window_pid/environ" 2>/dev/null \
        || die "窗口进程 $window_pid 未启动；日志：$run_dir；请执行 stop_motor_fault.sh 清理。"
done

exec 9>&-
ready_deadline=$((SECONDS + 300))
while ((SECONDS < ready_deadline)); do
    [[ $(tmux show-environment -t "=$TMUX_SESSION" MOTOR_FAULT_SITL_RUN_ID 2>/dev/null) == "MOTOR_FAULT_SITL_RUN_ID=$run_id" ]] \
        || die "MAVProxy 会话已退出；日志：$run_dir/sitl-window.log"
    pane_output=$(tmux capture-pane -pJ -S -200 -t "=$TMUX_SESSION:" 2>/dev/null) \
        || die "无法读取 MAVProxy 终端；日志：$run_dir/sitl-window.log"
    if grep -Eq '^[A-Z][A-Z0-9_]*( [A-Z0-9_]+)*>([[:blank:]]|$)' <<<"$pane_output"; then
        printf 'Motor Fault SITL 仿真组件已启动。\ntmux: %s\nWorld: %s\n运行记录：%s\n' "$TMUX_SESSION" "$WORLD" "$run_dir"
        exit 0
    fi
    sleep 0.5
done
die "等待 MAVProxy 命令行超时（300 秒）；日志：$run_dir/sitl-window.log；请执行 stop_motor_fault.sh 清理。"
