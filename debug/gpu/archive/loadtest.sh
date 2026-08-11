#!/usr/bin/env bash
# Автоматический нагрузочный тест: разделяет GPU-нагрузку и CPU-нагрузку,
# чтобы увидеть, отбирает ли CPU энергобюджет у видеокарты.
#
#   ./loadtest.sh <метка>       например: ./loadtest.sh bat-full-ac
#
# Фазы:
#   idle    15 с — базовая линия
#   gpu     60 с — только GPU
#   cpu     60 с — только CPU
#   both    60 с — GPU + CPU одновременно   ← здесь и вскрывается дележ бюджета
#   idle    15 с — остывание
set -uo pipefail
cd "$(dirname "$0")"

TAG="${1:-loadtest}"
DIR="$(pwd)/runs/${TAG}_$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DIR"

for b in vkmark stress-ng; do
  command -v "$b" >/dev/null || { echo "Нет $b. Установи: sudo pacman -S --needed mangohud lib32-mangohud vkmark glmark2 stress-ng"; exit 1; }
done

echo "Каталог прогона: $DIR"
echo "Батарея сейчас: $(cat /sys/class/power_supply/BAT0/capacity)% / $(cat /sys/class/power_supply/BAT0/status), АС=$(cat /sys/class/power_supply/ADP1/online)"
echo

# setsid — чтобы логгер стал лидером своей группы процессов и его можно было
# прибить целиком вместе с потомками (иначе остаются висеть сиротами)
setsid env MONITOR_DIR="$DIR" MONITOR_NOUI=1 ./monitor.sh "$TAG" &
MON=$!
sleep 2

: > "$DIR/phases.csv"
mark() { echo "$(date +%s),$1" >> "$DIR/phases.csv"; echo ">>> фаза: $1"; }

GPU_PID=""; CPU_PID=""

# UUID дискретки берём прямо у vkmark (вендор 0x10DE = NVIDIA), чтобы не гадать
# и не зависеть от порядка перечисления устройств.
NV_UUID=$(vkmark -L 2>/dev/null | awk '
  /Vendor ID:/   { vendor = $3 }
  /Device UUID:/ { if (vendor == "0x10DE") { print $3; exit } }')
if [ -z "$NV_UUID" ]; then
  echo "Не нашёл NVIDIA среди Vulkan-устройств. Проверь: vkmark -L"; exit 1
fi
echo "Дискретка: UUID $NV_UUID"

# -D           — прибиваем нагрузку к дискретке явно
# --fullscreen — иначе окно не получает кадровых колбэков и рендер встаёт
# БЕЗ -p immediate: этот режим карта НЕ ПОДДЕРЖИВАЕТ, vkmark падает сразу
# с «Selected present mode Immediate is not supported». Остаётся mailbox.
start_gpu() {
  vkmark -D "$NV_UUID" --fullscreen --run-forever -b shading \
    >>"$DIR/vkmark.log" 2>&1 &
  GPU_PID=$!
  sleep 5
  kill -0 "$GPU_PID" 2>/dev/null || {
    echo "!!! vkmark не запустился, см. $DIR/vkmark.log:"
    head -5 "$DIR/vkmark.log" | sed 's/^/!!!   /'
  }
}
stop_gpu()  { [ -n "$GPU_PID" ] && kill "$GPU_PID" 2>/dev/null; GPU_PID=""; }
start_cpu() { stress-ng --cpu 12 --cpu-method matrixprod -t 0 >/dev/null 2>&1 & CPU_PID=$!; }
stop_cpu()  { [ -n "$CPU_PID" ] && { kill "$CPU_PID" 2>/dev/null; pkill -P "$CPU_PID" 2>/dev/null; }; CPU_PID=""; }

finish() {
  stop_gpu; stop_cpu
  kill -TERM -"$MON" 2>/dev/null   # вся группа: monitor.sh + оба его логгера
  sleep 1
  kill -KILL -"$MON" 2>/dev/null
  echo
  echo "Готово: $DIR"
  echo "Отчёт:  ./loadtest-report.sh \"$DIR\""
}
trap finish EXIT INT TERM

mark idle;  sleep 15
mark gpu;   start_gpu;  sleep 12
# страховка от повторения бага: убеждаемся, что нагрузка легла на дискретку
u=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | tr -d ' ')
if [ "${u:-0}" -lt 20 ]; then
  echo "!!! ВНИМАНИЕ: загрузка RTX 2050 всего ${u}% — нагрузка ушла не туда."
  echo "!!! Результат будет недостоверным. Проверь: prime-run vulkaninfo --summary"
else
  echo "    ок, дискретка нагружена на ${u}%"
fi
sleep 48
mark cpu;   stop_gpu;   start_cpu; sleep 60
mark both;  start_gpu;  sleep 60
mark idle2; stop_gpu;   stop_cpu;  sleep 15
mark end
