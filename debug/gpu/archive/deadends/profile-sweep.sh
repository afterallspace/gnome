#!/usr/bin/env bash
# Перебор режимов платформы с замером: какой профиль → какой STNM → какой
# потолок ватт. Запускать ПОД НАГРУЗКОЙ (glmark2 в соседнем окне) и НА ЗАРЯДКЕ.
#
#   prime-run glmark2 --off-screen -b shading:duration=600 &   # окно 1
#   sudo ./profile-sweep.sh                                    # окно 2
set -u
PP=/sys/class/platform-profile/platform-profile-0/profile
CALL=/proc/acpi/call
[ -w "$CALL" ] || { echo "sudo modprobe acpi_call"; exit 1; }
[ "$(cat /sys/class/power_supply/ADP1/online)" = 1 ] || echo "⚠ БЕЗ ЗАРЯДКИ — ватты будут в DC-режиме, вердикты кривые"

stnm() { printf '%s' '\_SB.PC00.LPCB.H_EC.STNM' > "$CALL"; tr -d '\0' < "$CALL"; }
watts() { # средняя мощность GPU за 8 секунд
  nvidia-smi --query-gpu=power.draw.instant --format=csv,noheader,nounits -l 1 2>/dev/null \
    | head -8 | awk '{s+=$1; n++} END{if(n)printf "%.1f", s/n; else printf "?"}'
}

printf "%-22s %-6s %-8s %-10s %s\n" "профиль" "запись" "STNM" "GPU Вт" "примечание"
for p in low-power balanced balanced-performance performance balanced; do
  err=$(echo "$p" > "$PP" 2>&1) && ok="ок" || ok="ОТКАЗ"
  sleep 6   # дать EC стрельнуть _Q24 и драйверу перечитать
  printf "%-22s %-6s %-8s %-10s %s\n" "$p" "$ok" "$(stnm)" "$(watts)" "${err:-}"
done
echo
echo "Текущий профиль: $(cat $PP)"
