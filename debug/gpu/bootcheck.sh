#!/usr/bin/env bash
# Быстрая проверка: эта загрузка «хорошая» или «плохая»?
# ~25 секунд, игра не нужна, окно не открывается.
#
#   ./bootcheck.sh
#
# ПОЧЕМУ glmark2 --off-screen, а НЕ vkmark:
#   vkmark рисует в окно и упирается в вертикальную синхронизацию 60 Гц.
#   На этой машине он выдаёт максимум ~11 Вт при любой сцене — то есть НЕ
#   ДОСТАЁТ даже до потолка в 16 Вт, который видно в игре. Вердикты по нему
#   бессмысленны (первые 10 записей bootlog были мусором, см. bootlog-invalid.csv).
#   glmark2 --off-screen рендерит вне экрана без синхронизации и упирается
#   ровно в 16 Вт — тот же потолок, что и игра. Проверено 21.07.
set -uo pipefail
cd "$(dirname "$0")"

command -v glmark2 >/dev/null || { echo "нужен glmark2: sudo pacman -S glmark2"; exit 1; }
command -v prime-run >/dev/null || { echo "нужен nvidia-prime"; exit 1; }

# На батарее карта ограничена штатно (режим DC) — вердикт будет бессмысленным.
if [ "$(cat /sys/class/power_supply/ADP1/online 2>/dev/null)" != "1" ]; then
  echo "⚠ АДАПТЕР НЕ ПОДКЛЮЧЁН. В режиме от батареи GPU ограничен штатно,"
  echo "  вердикт ничего не будет значить. Воткни зарядку и повтори."
  printf "  Всё равно продолжить? [y/N] "
  read -r a; case "$a" in y|Y|д|Д) ;; *) exit 1 ;; esac
fi

LOG=$(mktemp)
cleanup() { kill "${GP:-0}" 2>/dev/null; sleep 1; pkill -9 -x glmark2 2>/dev/null; rm -f "$LOG"; }
trap cleanup EXIT INT TERM

echo "Гружу дискретку на ~25 секунд (окно не откроется, рендер вне экрана)..."
prime-run glmark2 --off-screen -b shading:duration=30 >"$LOG" 2>&1 &
GP=$!

sleep 6
if ! kill -0 "$GP" 2>/dev/null; then
  echo; echo "✖ glmark2 не запустился:"; sed 's/^/    /' "$LOG" | head -12; exit 1
fi
rend=$(grep -m1 "GL_RENDERER" "$LOG" | sed 's/.*GL_RENDERER: *//')
case "$rend" in
  *NVIDIA*) : ;;
  "")       echo "  (предупреждение: glmark2 ещё не назвал устройство)" ;;
  *)        echo "✖ Нагрузка ушла НЕ на дискретку: $rend"; exit 1 ;;
esac

sum=0; max=0; n=0; usum=0; csum=0; cmax=0
for _ in $(seq 16); do
  line=$(nvidia-smi --query-gpu=power.draw.instant,clocks.sm,utilization.gpu \
         --format=csv,noheader,nounits 2>/dev/null)
  IFS=',' read -r w c u <<< "$line"
  w=${w// /}; c=${c// /}; u=${u// /}
  case "$u" in ''|*[!0-9]*) sleep 1; continue ;; esac
  [ "$u" -lt 50 ] && { sleep 1; continue; }
  sum=$(awk -v a="$sum" -v b="$w" 'BEGIN{print a+b}')
  max=$(awk -v a="$max" -v b="$w" 'BEGIN{print (b>a)?b:a}')
  usum=$((usum + u)); csum=$((csum + c)); n=$((n+1))
  case "$c" in *[!0-9]*|'') ;; *) [ "$c" -gt "$cmax" ] && cmax=$c ;; esac
  sleep 1
done
kill "$GP" 2>/dev/null

if [ "$n" -eq 0 ]; then
  echo "✖ Дискретка не нагрузилась (загрузка ниже 50 %). Лог glmark2:"
  sed 's/^/    /' "$LOG" | head -12; exit 1
fi

avg=$(awk -v s="$sum" -v n="$n" 'BEGIN{printf "%.1f", s/n}')
uavg=$((usum / n)); cavg=$((csum / n))

echo
echo "═══════════════════════════════════════════════════"
printf "  Мощность GPU : %s Вт средних, %s Вт макс   (лимит 35)\n" "$avg" "$max"
printf "  Частота SM   : %s МГц   Загрузка: %s %%   (замеров: %s)\n" "$cavg" "$uavg" "$n"
printf "  Устройство   : %s\n" "${rend:-?}"
# Вердикт по ДВУМ признакам (22.07): лок — это запрет буст-частот, потолок
# ~1327 МГц; свобода — 1600+. Ватты зависят от питания (батарея, голодная
# зарядка, PSYS) и могут врать в обе стороны, частоты — нет. Ватты оставлены
# вторым признаком для AC-случая.
printf "  Макс. частота: %s МГц   (лок ~1327, свобода 1600+)\n" "$cmax"
verdict=$(awk -v a="$avg" -v c="$cmax" 'BEGIN{print (a>24 || c>=1500)?"ХОРОШАЯ":"ПЛОХАЯ"}')
if [ "$verdict" = "ХОРОШАЯ" ]; then
  echo "  ✔ ЗАГРУЗКА ХОРОШАЯ — карта берёт свои ватты, можно играть."
else
  echo "  ✖ ЗАГРУЗКА ПЛОХАЯ — карта задушена до ~16 Вт вместо 35."
  echo "    Внутри сессии не лечится, помогает только перезагрузка."
fi
echo "═══════════════════════════════════════════════════"

wmidrv=$(readlink -f /sys/bus/wmi/devices/46C93E13-*/driver 2>/dev/null | head -1 | xargs -r basename)
mono() { journalctl -k -b 0 --no-pager -o short-monotonic 2>/dev/null \
         | grep -m1 -F "$1" | grep -oE "^\[ *[0-9]+\.[0-9]+\]" | tr -d '[] '; }
t_nvdrm=$(mono "[nvidia-drm] [GPU ID"); t_i915=$(mono "i915 0000:00:02.0: [drm] Found")
gap="?"; [ -n "$t_nvdrm" ] && [ -n "$t_i915" ] && \
  gap=$(awk -v a="$t_i915" -v b="$t_nvdrm" 'BEGIN{printf "%+.0f", (a-b)*1000}')
rtd3=$(head -1 /proc/driver/nvidia/gpus/0000:01:00.0/power 2>/dev/null | sed 's/.*: *//')
bat="$(cat /sys/class/power_supply/BAT0/status 2>/dev/null) $(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)%"
# Фаза заряда — ключевая переменная гипотезы «зарядка в момент загрузки»:
# активный заряд (>8 Вт при <95 %) против трикла/full (<7 Вт при >97 %).
# Строка status это НЕ различает, поэтому пишем ватты зарядки отдельно.
batw=$(awk '{printf "%.1f", $1/1000000}' /sys/class/power_supply/BAT0/power_now 2>/dev/null)
profile=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)

echo
echo "  Состояние этой загрузки:"
printf "    батарея               : %s, %s Вт заряд/разряд\n" "$bat" "${batw:-?}"
printf "    platform_profile      : %s\n" "${profile:-?}"
printf "    RTD3                  : %s\n" "${rtd3:-?}"
printf "    зазор nvidia→i915     : %s мс\n" "$gap"
printf "    WMI 46C93E13          : %s\n" "${wmidrv:-—}"

boot=$(journalctl --list-boots --no-pager 2>/dev/null | tail -1 | awk '{print $2}')
[ -f bootlog.csv ] || echo "дата,вердикт,gpu_вт_сред,gpu_вт_макс,мгц,загрузка,батарея,rtd3,зазор_мс,wmi,ядро,boot_id,бат_вт,профиль" > bootlog.csv
echo "$(date -Is),$verdict,$avg,$max,$cavg,$uavg,\"$bat\",${rtd3:-?},$gap,${wmidrv:-?},$(uname -r),$boot,${batw:-?},${profile:-?}" >> bootlog.csv

# --- СНИМОК ЖУРНАЛА ---
# Журнал этой машины вычищается за считанные часы: лог хорошей загрузки
# 12:57 (34.9 Вт) был безвозвратно потерян через три часа. Поэтому сохраняем
# всё нужное сразу, отдельно от journald.
SNAP="snapshots/${verdict}_$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SNAP"
{
  echo "вердикт: $verdict | GPU $avg Вт сред, $max макс | $cavg МГц | загрузка $uavg %"
  echo "батарея: $bat, ${batw:-?} Вт | профиль: ${profile:-?} | RTD3: ${rtd3:-?} | зазор: $gap мс | WMI: ${wmidrv:-?}"
  echo "ядро: $(uname -r) | boot_id: $boot"
  echo "cmdline: $(cat /proc/cmdline)"
} > "$SNAP/verdict.txt"
journalctl -k -b 0 --no-pager -o short-monotonic > "$SNAP/kernel.log" 2>/dev/null
journalctl -u nvidia-powerd -b 0 --no-pager > "$SNAP/nvidia-powerd.log" 2>/dev/null
cp /proc/driver/nvidia/params "$SNAP/nvidia-params.txt" 2>/dev/null
cp /proc/driver/nvidia/gpus/0000:01:00.0/power "$SNAP/nvidia-power.txt" 2>/dev/null
nvidia-smi -q > "$SNAP/nvidia-smi-q.txt" 2>/dev/null
grep -E '^(MODULES|HOOKS)=' /etc/mkinitcpio.conf > "$SNAP/mkinitcpio.txt" 2>/dev/null
ls /etc/modprobe.d/ > "$SNAP/modprobe.d.txt" 2>/dev/null
gzip -q "$SNAP/kernel.log" "$SNAP/nvidia-smi-q.txt" 2>/dev/null

echo
echo "Записано в bootlog.csv (проверок: $(($(wc -l < bootlog.csv) - 1)))"
echo "Снимок журнала: $SNAP"
[ "$verdict" = "ХОРОШАЯ" ] && {
  echo
  echo "  ⚠ ЭТО ХОРОШАЯ ЗАГРУЗКА — снимок сохранён, НЕ ПЕРЕЗАГРУЖАЙСЯ."
  echo "    Сравни её с плохой:  ./compare-boots.sh"
}
