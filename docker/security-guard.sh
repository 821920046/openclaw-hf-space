#!/usr/bin/env bash
# ==============================================================================
# OpenClaw 核心进程与关键服务安全护栏 (Security Guard)
# 防止 AI Agent 在自主执行 Shell 工具时误杀宿主关键进程（如 Gateway / Nginx / Proxy）
# ==============================================================================

set -euo pipefail

PROTECTED_NAMES=("node" "dist/index.js" "gateway" "nginx" "start.sh" "openrouter_proxy" "admin_api" "backup_api")

# 创建 /usr/local/bin/pkill 守卫
cat << 'EOF' > /usr/local/bin/pkill
#!/usr/bin/env bash
TARGETS=("node" "dist/index.js" "gateway" "nginx" "start.sh" "openrouter_proxy" "admin_api" "backup_api")
ARGS="$*"
for t in "${TARGETS[@]}"; do
  if [[ " $ARGS " =~ [[:space:]]$t([[:space:]]|$) ]] || [[ "$ARGS" =~ (^|[[:space:]])-f[[:space:]]+.*$t.* ]] || [[ "$ARGS" =~ (^|[[:space:]]).*$t.* ]]; then
    # 特别保护核心守护服务
    if [[ "$ARGS" =~ node|gateway|nginx|start\.sh|openrouter_proxy|admin_api|backup_api ]]; then
      echo "[SECURITY GUARD] Blocked pkill targeting core service: '$ARGS'. Operation aborted to maintain container stability." >&2
      exit 1
    fi
  fi
done
REAL_PKILL=""
for p in /usr/bin/pkill /bin/pkill; do
  if [[ -x "$p" && "$p" != "/usr/local/bin/pkill" ]]; then
    REAL_PKILL="$p"
    break
  fi
done
if [[ -n "$REAL_PKILL" ]]; then
  exec "$REAL_PKILL" "$@"
else
  echo "[SECURITY GUARD] pkill finished (simulated safe mode)."
fi
EOF
chmod +x /usr/local/bin/pkill

# 创建 /usr/local/bin/killall 守卫
cat << 'EOF' > /usr/local/bin/killall
#!/usr/bin/env bash
TARGETS=("node" "dist/index.js" "gateway" "nginx" "start.sh" "openrouter_proxy" "admin_api" "backup_api")
ARGS="$*"
for t in "${TARGETS[@]}"; do
  if [[ "$ARGS" =~ (^|[[:space:]])$t([[:space:]]|$) ]]; then
    echo "[SECURITY GUARD] Blocked killall targeting core service: '$ARGS'. Operation aborted to maintain container stability." >&2
    exit 1
  fi
done
REAL_KILLALL=""
for p in /usr/bin/killall /bin/killall; do
  if [[ -x "$p" && "$p" != "/usr/local/bin/killall" ]]; then
    REAL_KILLALL="$p"
    break
  fi
done
if [[ -n "$REAL_KILLALL" ]]; then
  exec "$REAL_KILLALL" "$@"
else
  echo "[SECURITY GUARD] killall finished (simulated safe mode)."
fi
EOF
chmod +x /usr/local/bin/killall

# 创建 /usr/local/bin/kill 守卫
cat << 'EOF' > /usr/local/bin/kill
#!/usr/bin/env bash
REAL_KILL=""
for p in /bin/kill /usr/bin/kill; do
  if [[ -x "$p" && "$p" != "/usr/local/bin/kill" ]]; then
    REAL_KILL="$p"
    break
  fi
done

# 遍历传入的所有 PID，排查是否命中核心进程
for arg in "$@"; do
  # 提取纯数字 PID
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    pid="$arg"
    if [[ -d "/proc/$pid" ]]; then
      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
      if [[ "$cmdline" =~ node.*dist/index\.js.*gateway || "$cmdline" =~ nginx.*daemon || "$cmdline" =~ start\.sh || "$cmdline" =~ openrouter_proxy || "$cmdline" =~ admin_api || "$cmdline" =~ backup_api ]]; then
        echo "[SECURITY GUARD] Blocked kill targeting protected core PID $pid ('$cmdline'). Operation aborted." >&2
        exit 1
      fi
    fi
  fi
done

if [[ -n "$REAL_KILL" ]]; then
  exec "$REAL_KILL" "$@"
else
  builtin kill "$@" 2>/dev/null || true
fi
EOF
chmod +x /usr/local/bin/kill

echo "[security-guard] Core process protection wrappers installed successfully in /usr/local/bin"
