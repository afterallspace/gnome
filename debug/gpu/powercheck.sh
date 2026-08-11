#!/usr/bin/env bash
# Проверка тракта питания: что реально отдаёт зарядка, как ведёт себя батарея.
# ЗАПУСКАТЬ С ВОТКНУТЫМ АДАПТЕРОМ — иначе поля USB-C PD будут нулевые.
#
#   ./powercheck.sh          — снимок
#   ./powercheck.sh 30       — наблюдать 30 секунд (ловит просадки)
set -uo pipefail
SECS="${1:-0}"

BAT=/sys/class/power_supply/BAT0
ADP=/sys/class/power_supply/ADP1
UCSI=$(ls -d /sys/class/power_supply/ucsi-source-psy-* 2>/dev/null | head -1)
TYPEC=/sys/class/typec/port0

r() { cat "$1" 2>/dev/null; }

echo "═══════════════════════════════════════════════════════"
echo " ТРАКТ ПИТАНИЯ"
echo "═══════════════════════════════════════════════════════"

ac=$(r $ADP/online)
printf "  Адаптер подключён      : %s\n" "$([ "$ac" = 1 ] && echo да || echo НЕТ)"
[ "$ac" != 1 ] && echo "  ⚠ Воткни адаптер — без него данные PD бессмысленны."

echo
echo "── USB-C Power Delivery ──────────────────────────────"
pom=$(r $TYPEC/power_operation_mode)
printf "  режим питания порта    : %s\n" "${pom:-—}"
case "$pom" in
  usb_power_delivery) echo "                           ✔ PD-контракт согласован" ;;
  default)            [ "$ac" = 1 ] && echo "                           ⚠ ТОЛЬКО 5 В USB по умолчанию — PD НЕ согласован!" ;;
esac
printf "  ревизия PD             : %s\n" "$(r $TYPEC/usb_power_delivery_revision)"
printf "  роль питания           : %s\n" "$(r $TYPEC/power_role)"
if [ -n "$UCSI" ]; then
  u_v=$(r $UCSI/voltage_now); u_i=$(r $UCSI/current_now)
  u_vm=$(r $UCSI/voltage_max); u_im=$(r $UCSI/current_max)
  printf "  источник: сейчас       : %s В, %s А" \
    "$(awk -v x="${u_v:-0}" 'BEGIN{printf "%.1f", x/1e6}')" \
    "$(awk -v x="${u_i:-0}" 'BEGIN{printf "%.2f", x/1e6}')"
  awk -v v="${u_v:-0}" -v i="${u_i:-0}" 'BEGIN{ if(v>0&&i>0) printf "  →  %.1f Вт\n", v*i/1e12; else print "" }'
  printf "  источник: максимум     : %s В, %s А" \
    "$(awk -v x="${u_vm:-0}" 'BEGIN{printf "%.1f", x/1e6}')" \
    "$(awk -v x="${u_im:-0}" 'BEGIN{printf "%.2f", x/1e6}')"
  awk -v v="${u_vm:-0}" -v i="${u_im:-0}" 'BEGIN{ if(v>0&&i>0) printf "  →  %.0f Вт (номинал блока)\n", v*i/1e12; else print "" }'
  [ "${u_vm:-0}" = 0 ] && [ "$ac" = 1 ] && \
    echo "  ⚠ Прошивка не отдаёт параметры источника — номинал блока не прочитать."
fi

echo
echo "── Батарея ───────────────────────────────────────────"
ef=$(r $BAT/energy_full); ed=$(r $BAT/energy_full_design)
printf "  статус                 : %s (%s %%)\n" "$(r $BAT/status)" "$(r $BAT/capacity)"
printf "  напряжение             : %s В (мин. по проекту %s В)\n" \
  "$(awk -v x="$(r $BAT/voltage_now)" 'BEGIN{printf "%.2f", x/1e6}')" \
  "$(awk -v x="$(r $BAT/voltage_min_design)" 'BEGIN{printf "%.2f", x/1e6}')"
printf "  мощность               : %s Вт\n" \
  "$(awk -v x="$(r $BAT/power_now)" 'BEGIN{printf "%.1f", x/1e6}')"
awk -v f="${ef:-0}" -v d="${ed:-0}" 'BEGIN{
  if(d>0){ printf "  ёмкость                : %.1f / %.1f Вт·ч = %.0f %% от заводской", f/1e6, d/1e6, 100*f/d;
           if(100*f/d < 70) print "  ⚠ сильный износ"; else print "" }}'

echo
echo "── Нагрузка на адаптер ───────────────────────────────"
psys=$(r /sys/class/powercap/intel-rapl:1/energy_uj)
if [ -n "$psys" ]; then
  sleep 1
  psys2=$(r /sys/class/powercap/intel-rapl:1/energy_uj)
  awk -v a="$psys" -v b="$psys2" 'BEGIN{printf "  платформа (PSYS)       : %.1f Вт\n", (b-a)/1e6}'
else
  echo "  платформа (PSYS)       : нет доступа (нужен sudo chmod a+r .../energy_uj)"
fi
printf "  GPU                    : %s\n" "$(nvidia-smi --query-gpu=power.draw.instant --format=csv,noheader 2>/dev/null)"

if [ "$SECS" -gt 0 ] 2>/dev/null; then
  echo
  echo "── Наблюдение $SECS с (ищем просадки и разряд при воткнутом адаптере) ──"
  printf "  %-9s %-14s %9s %8s %8s\n" ВРЕМЯ СТАТУС НАПРЯЖ БАТ_ВТ AC
  end=$(( $(date +%s) + SECS ))
  while [ "$(date +%s)" -lt "$end" ]; do
    printf "  %-9s %-14s %7s В %6s Вт %8s\n" "$(date +%H:%M:%S)" "$(r $BAT/status)" \
      "$(awk -v x="$(r $BAT/voltage_now)" 'BEGIN{printf "%.2f", x/1e6}')" \
      "$(awk -v x="$(r $BAT/power_now)" 'BEGIN{printf "%.1f", x/1e6}')" \
      "$(r $ADP/online)"
    sleep 2
  done
  echo
  echo "  Что искать: строки 'Discharging' при AC=1 под нагрузкой означают,"
  echo "  что адаптер не покрывает потребление — вот тогда виноват блок или кабель."
fi
echo "═══════════════════════════════════════════════════════"
