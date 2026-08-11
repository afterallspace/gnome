#!/usr/bin/env bash
# Ограничить/вернуть энергобюджет CPU. Нужен, чтобы проверить гипотезу
# «процессор отбирает питание у видеокарты».
#
#   sudo ./cpu-cap.sh 30 40   — PL1=30 Вт, PL2=40 Вт (для игр — то, что нужно)
#   sudo ./cpu-cap.sh restore — вернуть заводские 52/64 Вт
#   ./cpu-cap.sh show         — показать текущие значения
#
# Всё живёт до перезагрузки. Ничего не ломает, ничего не прошивает.
set -uo pipefail
P=/sys/class/powercap/intel-rapl:0

show() {
  echo "PL1 (long_term)  = $(awk '{printf "%.0f Вт", $1/1e6}' $P/constraint_0_power_limit_uw)"
  echo "PL2 (short_term) = $(awk '{printf "%.0f Вт", $1/1e6}' $P/constraint_1_power_limit_uw)"
  echo "PSYS limit       = $(awk '{printf "%.0f Вт", $1/1e6}' /sys/class/powercap/intel-rapl:1/constraint_0_power_limit_uw 2>/dev/null)"
  echo "GPU limit        = $(nvidia-smi --query-gpu=power.default_limit --format=csv,noheader)"
  echo "platform_profile = $(cat /sys/firmware/acpi/platform_profile)"
}

case "${1:-show}" in
  show) show ;;
  restore)
    [ "$EUID" -eq 0 ] || { echo "нужен sudo"; exit 1; }
    echo 52000000 > $P/constraint_0_power_limit_uw
    echo 64000000 > $P/constraint_1_power_limit_uw
    echo "Вернул заводские значения:"; show ;;
  *)
    [ "$EUID" -eq 0 ] || { echo "нужен sudo"; exit 1; }
    PL1="${1:?PL1 в ваттах}"; PL2="${2:-$((PL1 + 10))}"
    echo $((PL1 * 1000000)) > $P/constraint_0_power_limit_uw
    echo $((PL2 * 1000000)) > $P/constraint_1_power_limit_uw
    echo "Выставил:"; show ;;
esac
