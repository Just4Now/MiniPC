#!/bin/bash
# ============================================================================
# perf-test.sh — 向 chat-end 聊天输入框注入 perf.md §3 基准 Prompt 并同时发送
#
# 用法:
#   ./perf-test.sh -p P1 -n 3     # 3 台聊天设备同时输入并发送 P1
#   ./perf-test.sh -p P3 -n 1     # 单台注入并发送 P3
#   ./perf-test.sh -p P2 --devices 192.168.43.113:44231,192.168.43.114:37495
#
# 选项:
#   -p <P1|P2|P3|P4>    Prompt 类型（必填）: P1 短入短出 / P2 短入长出 /
#                       P3 长入短出 / P4 长入长出（perf.md §3）
#   -n <1|2|3>          同时执行的设备台数（默认 3, 不足时取已连接台数;
#                       按 serial 排序取前 N 台）
#   --devices <s1,s2>   显式指定设备 serial（覆盖 -n）
#
# 前提: 设备已解锁亮屏、chat-end App 在前台且「协同已就绪」。
# 流程: 并行 按坐标注入全文（uitest inputText, 替换式）→ 3-2-1 倒计时 → 同时点发送。
# 依赖: devecocli、hdc（DevEco Studio 自带）、python3。
# ============================================================================

set -uo pipefail
DEVECO="${DEVECO:-devecocli}"

# hdc 定位（注入文本走设备端 uitest inputText, devecocli ui text 不支持空格/换行）
find_hdc() {
  if command -v hdc >/dev/null 2>&1; then command -v hdc; return 0; fi
  local cand
  for cand in \
    "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc" \
    "$HOME/Library/Huawei/Sdk/default/openharmony/toolchains/hdc" \
    "/Applications/DevEco Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"; do
    [ -x "$cand" ] && { echo "$cand"; return 0; }
  done
  return 1
}
HDC="$(find_hdc || true)"
[ -n "$HDC" ] || { echo "错误: 未找到 hdc（DevEco Studio 工具链）" >&2; exit 1; }

# ---------------------------------------------------------------- Prompt 定义
# 附录 A 长输入样例文档（perf.md, 889 字符）
DOC='近场协同计算：把大模型装进口袋集群

过去十年，深度学习的算力需求增长了数十万倍，训练与推理几乎完全依赖数据中心。与此同时，手机SoC的神经网络算力也在快速增长，旗舰芯片的NPU峰值算力已达到每秒数十万亿次操作。矛盾在于：单一终端仍装不下七十亿参数的大模型，而云端推理又受制于网络时延、带宽费用与隐私合规。近场协同计算试图在两者之间开辟第三条路——把若干台可信终端组成一个临时的推理集群，让模型请求在设备之间流转，数据不出局域网。

近场组网的关键是发现与链路建立。典型方案利用蓝牙低功耗广播携带自定义厂商字段，待测设备扫描到特定标识后发起连接，再通过链路增强通道传输应用数据。整个过程中不出现IP地址与端口号，设备身份由安装时生成的唯一标识与系统可信列表双重校验，未经组网授权的陌生设备会在握手阶段被拒绝。消息按约四百八十字节切片并以Base64封装，单帧不超过一千字节，配合确认与超时机制保证弱连接下的可靠性。

推理侧通常采用量化模型降低内存占用。以七十亿参数模型为例，四比特量化后权重大约占四吉字节，加上键值缓存与运行时开销，整机需要八吉字节以上可用内存才能流畅运行。会话创建、请求提交、流式回调与销毁构成一次完整的推理生命周期，框架通过代数标记过滤迟到的回调，避免旧请求的输出污染新会话。受限于端侧内存带宽，解码速度一般在每秒十到三十个汉字之间，首字时延则取决于提示词长度与预填充效率。

调度是集群化的核心难题。协调节点需要综合各成员的空闲路数、可用内存与温度状态选择执行机，过载时宁可排队也不应盲目分发。手机散热能力有限，持续推理会触发热降频，性能在数分钟后明显下滑；电量、后台任务与蓝牙干扰同样会放大延迟抖动。工程实践倾向于保守策略：拓扑变化期间暂停后台同步，推理期间冻结组网扫描，把有限的无线电与内存带宽留给生成任务本身。

可靠性与降级同样不可忽视。链路抖动时消息分片必须在超时窗口内重组完毕，否则断链重连；执行机中途离线时，协调节点应把失败原因回传提问方，而不是让其无限等待。渐进式的失败处理——返回部分结果并明确标注缺失——通常优于全有或全无的粗暴策略。'

PROMPT_TEXT=""
case_prompt() {
  case "$1" in
    P1) PROMPT_TEXT='请用一个词形容"夏天"。不要解释，不要说多余的话。' ;;
    P2) PROMPT_TEXT='请写一篇不超过 200 字的科幻微小说，主题是"人工智能未来十年发展"。' ;;
    P3) PROMPT_TEXT="${DOC}
根据上述文章，请用不超过 30 个字总结核心观点。" ;;
    P4) PROMPT_TEXT="${DOC}
请详细分析上述材料中的架构漏洞，并为其编写一份包含系统拓扑、代码重构方案和迁移步骤的详细优化报告。注意报告不能超过200字。" ;;
    *) return 1 ;;
  esac
  # 注入走设备端 uitest inputText（替换式, 支持空格）; 它同样不支持换行, 长文按单行注入。
  # 段落均以句号结尾, 直接拼接不影响语义; 去换行后 P3=904 / P4=941 字符, 均在 maxlength=1000 内。
  PROMPT_TEXT=${PROMPT_TEXT//$'\n'/}
  # hdc shell 里文本用单引号包裹, Prompt 本身含单引号会破坏配对, 直接拒绝
  case "$PROMPT_TEXT" in
    *"'"*) echo "错误: Prompt 文本含单引号, 无法经 hdc shell 注入, 请修改 Prompt" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------- 工具函数
now_ms() { python3 -c 'import datetime; print(datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3])'; }

# devecocli 命令, 失败自动重试一次（hdc 偶发抖动）
dvc() {
  local out rc
  out=$("$DEVECO" "$@" 2>&1); rc=$?
  if [ $rc -ne 0 ] || ! grep -q '✔' <<<"$out"; then
    sleep 1
    "$DEVECO" "$@" >/dev/null 2>&1 && return 0
    return 1
  fi
  return 0
}

# 解析布局树, 输出输入框/发送键坐标: INPUT_X=.. INPUT_Y=.. SEND_X=.. SEND_Y=..
layout_coords() { # <serial>
  local f i
  f=$(mktemp /tmp/perf-layout.XXXXXX)
  for i in 1 2; do
    "$DEVECO" ui layout --device "$1" --format json > "$f" 2>/dev/null
    if python3 - "$f" <<'PY'
import json, sys
try:
    tree = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
inp = send = None
stack = list(tree)
while stack:
    n = stack.pop()
    t = n.get('type') or ''
    if inp is None and t == 'textField':
        inp = n
    elif send is None and t == 'button' and (n.get('text') or '').startswith(('发送', '停止')):
        send = n
    if inp is not None and send is not None:
        break
    stack.extend(n.get('children', []))
if inp is None or send is None:
    sys.exit(1)
c = lambda b: ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2)
ix, iy = c(inp['bounds'])
sx, sy = c(send['bounds'])
print(f'INPUT_X={ix} INPUT_Y={iy} SEND_X={sx} SEND_Y={sy}')
PY
    then rm -f "$f"; return 0; fi
    sleep 1
  done
  rm -f "$f"
  return 1
}

# ---------------------------------------------------------------- 参数
PROMPT=""
N_DEVICES=3
DEVICES_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) PROMPT="$2"; shift 2 ;;
    -n) N_DEVICES="$2"; shift 2 ;;
    --devices) DEVICES_OVERRIDE="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
    *) echo "未知参数: $1（--help 查看用法）" >&2; exit 2 ;;
  esac
done
case_prompt "$PROMPT" || { echo "错误: -p 必须是 P1/P2/P3/P4" >&2; exit 2; }

# ---------------------------------------------------------------- 设备清单
if [ -n "$DEVICES_OVERRIDE" ]; then
  IFS=',' read -r -a SERIALS <<<"$DEVICES_OVERRIDE"
else
  SERIALS=()
  while IFS='|' read -r s name; do
    SERIALS+=("$s"); echo "  设备: $name ($s)"
  done < <("$DEVECO" device list --format json 2>/dev/null |
    python3 -c 'import json,sys
try:
    for d in sorted(json.load(sys.stdin), key=lambda d: d["serial"]):
        if d.get("kind") == "device": print(d["serial"] + "|" + d["name"])
except Exception: pass')
  if [ "${#SERIALS[@]}" -eq 0 ]; then echo "错误: 未发现已连接设备" >&2; exit 1; fi
  if [ "$N_DEVICES" -gt "${#SERIALS[@]}" ]; then N_DEVICES=${#SERIALS[@]}; fi
  SERIALS=("${SERIALS[@]:0:$N_DEVICES}")
fi

# 去重（保持顺序）——同一 serial 两个并行任务会在同设备上互相竞争, 必须排除
UNIQ=()
for s in "${SERIALS[@]}"; do
  DUP=0
  for u in ${UNIQ[@]+"${UNIQ[@]}"}; do [ "$u" = "$s" ] && DUP=1; done
  [ "$DUP" -eq 0 ] && UNIQ+=("$s")
done
if [ "${#UNIQ[@]}" -ne "${#SERIALS[@]}" ]; then
  echo "警告: 设备列表存在重复 serial, 已去重为 ${#UNIQ[@]} 台: ${UNIQ[*]}" >&2
fi
SERIALS=("${UNIQ[@]}")

echo "用例 ${PROMPT}（${#PROMPT_TEXT} 字符）→ ${#SERIALS[@]} 台设备: ${SERIALS[*]}"

# ---------------------------------------------------------------- 1. 并行注入
# uitest inputText 按坐标定位输入框, 无需先点击获取焦点（不弹键盘, 坐标不会漂移）;
# 替换式注入, 输入框残留文本会被自动清掉; 支持空格/标点, 事件正常触发（发送键变绿）。
inject_text() { # <serial> <x> <y>
  local out
  out=$("$HDC" -t "$1" shell "uitest uiInput inputText $2 $3 '$PROMPT_TEXT'" 2>&1)
  if ! grep -q 'No Error' <<<"$out"; then
    sleep 1
    out=$("$HDC" -t "$1" shell "uitest uiInput inputText $2 $3 '$PROMPT_TEXT'" 2>&1)
    grep -q 'No Error' <<<"$out" || { echo "  uitest 输出: $out" >&2; return 1; }
  fi
}
inject_on_device() { # <serial>
  local s=$1 c
  c=$(layout_coords "$s") || { echo "FAIL:$s:无法获取布局" >&2; return 1; }
  eval "$c"
  inject_text "$s" "$INPUT_X" "$INPUT_Y" || { echo "FAIL:$s:注入文本失败" >&2; return 1; }
  echo "OK:$s 已注入 $(now_ms)"
}
RES=$(mktemp -d /tmp/perf-inject.XXXXXX)
for s in "${SERIALS[@]}"; do
  ( inject_on_device "$s" > "$RES/out-$s" 2>&1; echo $? > "$RES/rc-$s" ) &
done
wait
FAIL=0
for s in "${SERIALS[@]}"; do
  if [ "$(cat "$RES/rc-$s" 2>/dev/null)" != "0" ]; then FAIL=1; fi
  cat "$RES/out-$s" 2>/dev/null
done
rm -rf "$RES"
if [ "$FAIL" -ne 0 ]; then
  echo "错误: 有设备注入失败, 为保证同时并发, 终止本轮（设备上的残留输入请手动清理后重跑）" >&2
  exit 1
fi
echo "注入阶段完成 $(now_ms)"

# ---------------------------------------------------------------- 2. 倒计时同时发送
# 坐标获取与 3 秒倒计时并行, 注入完成到发送总等待约 3 秒
send_on_device() { # <serial> <barrier_epoch>
  local s=$1 b=$2 c
  if ! c=$(layout_coords "$s"); then
    echo "FAIL:$s:无法获取发送键坐标" >&2
    return 1
  fi
  eval "$c"
  python3 -c "import time; d=$b-time.time(); time.sleep(d if d>0 else 0)"
  if dvc ui click "$SEND_X" "$SEND_Y" --device "$s"; then
    echo "  $s 发送于 $(now_ms)"
  else
    echo "FAIL:$s:发送点击失败" >&2
    return 1
  fi
}
RES=$(mktemp -d /tmp/perf-send.XXXXXX)
echo "3 秒倒计时后同时发送..."
BARRIER=$(python3 -c 'import time; print(f"{time.time()+3:.3f}")')
for s in "${SERIALS[@]}"; do
  ( send_on_device "$s" "$BARRIER" > "$RES/out-$s" 2>&1; echo $? > "$RES/rc-$s" ) &
done
wait
SEND_FAIL=0
for s in "${SERIALS[@]}"; do
  if [ "$(cat "$RES/rc-$s" 2>/dev/null)" != "0" ]; then SEND_FAIL=1; fi
  cat "$RES/out-$s" 2>/dev/null
done
rm -rf "$RES"
if [ "$SEND_FAIL" -ne 0 ]; then
  echo "错误: 有设备发送失败, 本轮并发不完整（请从 hub 核对后重跑）" >&2
  exit 1
fi
echo "全部发送完成 $(now_ms)（请从 hub 仪表盘记录各路 首字/耗时/字数）"
