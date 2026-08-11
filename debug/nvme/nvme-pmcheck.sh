#!/usr/bin/env bash
# Питание NVMe: почему счётчик Power Cycles растёт быстрее, чем машина
# включается. Снимает SMART + состояние PCIe/APST, считает прирост за интервал.
#
#   ./nvme-pmcheck.sh            — снимок и вердикт
#   ./nvme-pmcheck.sh 600        — наблюдать 600 с, померить прирост
#   ./nvme-pmcheck.sh --mark сон — отметка в лог без ожидания: делать до и
#                                  после suspend / перезагрузки, разность
#                                  соседних строк nvmelog.csv и есть ответ
#
# Нужен root. Лучше сразу `sudo ./nvme-pmcheck.sh 600`: при длинном интервале
# кэш пароля sudo (900 с по умолчанию) истекает прямо посреди замера.
# Скрипт это переживёт — держит кэш живым и проверяет каждый снимок, — но
# запуск от root надёжнее.
set -uo pipefail

MODE=interval
SECS=0
TAG=""
case "${1:-}" in
  --mark) MODE=mark; TAG="${2:-mark}" ;;
  "")     SECS=0 ;;
  *)      SECS="$1" ;;
esac

DEV=/dev/nvme0n1
CTRL=/sys/class/nvme/nvme0
PCI=$(basename "$(readlink -f $CTRL/device 2>/dev/null)")
CSV="$(dirname "$0")/nvmelog.csv"

r() { cat "$1" 2>/dev/null; }

# ── sudo: разово спросить пароль и держать кэш живым весь замер ──────────
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
  if ! sudo -n true 2>/dev/null; then
    echo "  Нужен root для чтения smart-log — введи пароль."
    sudo -v || { echo "  ✗ Без sudo замер невозможен."; exit 1; }
  fi
  # Обновляем метку каждые 50 с, иначе она протухнет на длинном sleep.
  # Потоки закрыты намеренно: иначе фоновый цикл держит открытым stdout и
  # вывод скрипта не доходит до `| tee`, пока не отвиснет его sleep.
  ( while true; do sleep 50; sudo -n true || exit; done ) >/dev/null 2>&1 &
  KEEPALIVE=$!
  trap 'kill "$KEEPALIVE" 2>/dev/null; wait "$KEEPALIVE" 2>/dev/null' EXIT
fi

# ── чтение и разбор smart-log ───────────────────────────────────────────
# Формат строк nvme smart-log: "ключ : значение". Ключ дополнен ТАБАМИ, не
# пробелами — поэтому сравниваем по строке после обрезки, а не регекспом.
sm() { printf '%s\n' "$SMART" | awk -F: -v k="$1" '
  { key=$1; gsub(/^[ \t]+|[ \t]+$/,"",key)
    if (key==k) { v=$2; gsub(/[ \t]/,"",v); print v; exit } }'; }
# то же, но только число — у Data Units Written в хвосте висит "(34.08 TB)"
smn() { sm "$1" | sed 's/(.*//; s/[^0-9].*$//'; }

# Снимает smart-log и убеждается, что он разобрался. Пустой или неполный
# снимок — это ошибка, а не нули: молчаливое обнуление уже один раз выдало
# ложный вердикт "счётчик стоит" (запись 2026-08-03 в NVME.md).
grab() {
  local err rc
  err=$($SUDO nvme smart-log "$DEV" 2>&1 >/tmp/nvme-pmcheck.$$ ); rc=$?
  SMART=$(cat /tmp/nvme-pmcheck.$$ 2>/dev/null); rm -f /tmp/nvme-pmcheck.$$
  if [ "$rc" -ne 0 ] || [ -z "$SMART" ]; then
    echo "  ✗ Не удалось прочитать smart-log с $DEV (код $rc)."
    [ -n "$err" ] && echo "    $err"
    exit 1
  fi
  local probe; probe=$(smn power_cycles)
  if ! [[ "$probe" =~ ^[0-9]+$ ]]; then
    echo "  ✗ smart-log прочитан, но поля не разбираются — изменился формат вывода."
    echo "    Сырой вывод для разбора:"
    printf '%s\n' "$SMART" | sed 's/^/    | /' | head -20
    exit 1
  fi
}

grab
pc0=$(smn power_cycles); poh0=$(smn power_on_hours); us0=$(smn unsafe_shutdowns)
duw0=$(smn 'Data Units Written'); rts0=$(r $CTRL/device/power/runtime_suspended_time)

csv_init() {
  [ -f "$CSV" ] || echo "timestamp,mode,tag,secs,power_cycles,delta_pc,pc_per_hour,unsafe,poh,rts_ms,pct_used" > "$CSV"
}

echo "═══════════════════════════════════════════════════════"
echo " ПИТАНИЕ NVMe"
echo "═══════════════════════════════════════════════════════"
printf "  модель                 : %s\n" "$(r $CTRL/model | xargs)"
printf "  прошивка               : %s\n" "$(r $CTRL/firmware_rev | xargs)"
echo
echo "── Счётчики ──────────────────────────────────────────"
printf "  power_cycles           : %s\n" "$pc0"
printf "  power_on_hours         : %s\n" "$poh0"
printf "  unsafe_shutdowns       : %s\n" "$us0"
printf "  percentage_used        : %s\n" "$(sm percentage_used)"
printf "  available_spare        : %s\n" "$(sm available_spare)"
printf "  media_errors           : %s\n" "$(sm media_errors)"
awk -v c="${pc0:-0}" -v h="${poh0:-0}" 'BEGIN{
  if (h>0) { printf "  циклов на час работы   : %.1f", c/h;
             if (c/h > 2) print "   ⚠ на порядок выше числа реальных включений";
             else print "" }}'

echo
echo "── Управление питанием ───────────────────────────────"
printf "  PCI-устройство         : %s\n" "$PCI"
printf "  состояние линии        : %s\n" "$(r /sys/bus/pci/devices/$PCI/power_state)"
printf "  runtime pm             : %s (%s)\n" \
  "$(r $CTRL/device/power/control)" "$(r $CTRL/device/power/runtime_status)"
printf "  в runtime-сне          : %s мс\n" "${rts0:-—}"
printf "  d3cold разрешён        : %s\n" "$(r /sys/bus/pci/devices/$PCI/d3cold_allowed)"
printf "  ASPM L1.1 / L1.2       : %s / %s\n" \
  "$(r /sys/bus/pci/devices/$PCI/link/l1_1_aspm)" "$(r /sys/bus/pci/devices/$PCI/link/l1_2_aspm)"
printf "  APST порог задержки    : %s мкс\n" \
  "$(r /sys/module/nvme_core/parameters/default_ps_max_latency_us)"
echo "  (0 = APST выключен, диск не уходит в PS3/PS4)"

# ── режим отметки: строка в лог и выход ─────────────────────────────────
if [ "$MODE" = mark ]; then
  csv_init
  printf '%s,mark,%s,,%s,,,%s,%s,%s,%s\n' \
    "$(date -Iseconds)" "$TAG" "$pc0" "$us0" "$poh0" "${rts0:-0}" "$(sm percentage_used)" >> "$CSV"
  echo
  echo "  Отметка «$TAG» записана в $(basename "$CSV")."
  echo "  Сравнивай соседние строки: разность power_cycles между отметками"
  echo "  до и после события и есть цена этого события в циклах."
  echo "═══════════════════════════════════════════════════════"
  exit 0
fi

# ── режим интервала ─────────────────────────────────────────────────────
if [ "$SECS" -gt 0 ] 2>/dev/null; then
  echo
  echo "── Наблюдение $SECS с ────────────────────────────────"
  echo "  Не трогай машину: важно, растёт ли счётчик в простое."
  t0=$(date +%s)
  sleep "$SECS"
  grab            # при неудаче выйдет с ошибкой, а не подставит нули
  t1=$(date +%s)
  pc1=$(smn power_cycles); us1=$(smn unsafe_shutdowns); duw1=$(smn 'Data Units Written')
  rts1=$(r $CTRL/device/power/runtime_suspended_time)
  dt=$(( t1 - t0 ))
  d=$(( pc1 - pc0 ))
  rs=$(( ${rts1:-0} - ${rts0:-0} ))

  awk -v d="$d" -v t="$dt" 'BEGIN{
    printf "  прирост power_cycles   : %d за %d с", d, t;
    if (t>0 && d>0) printf "  →  %.0f в час\n", d*3600/t; else print "" }'
  printf "  прирост unsafe_shutdown: %s\n" "$(( us1 - us0 ))"
  printf "  прирост runtime-сна    : %s мс\n" "$rs"
  awk -v a="$duw0" -v b="$duw1" 'BEGIN{ printf "  записано за интервал   : %.1f МиБ\n", (b-a)*512000/1048576 }'

  echo
  echo "── Вердикт ───────────────────────────────────────────"
  if [ "$d" -eq 0 ]; then
    echo "  Счётчик стоит: в простое питание не дёргается."
    echo "  Дальше мерить события, а не простой:"
    echo "    ./nvme-pmcheck.sh --mark before-suspend   (потом suspend и обратно)"
    echo "    ./nvme-pmcheck.sh --mark after-suspend"
    echo "    ./nvme-pmcheck.sh --mark before-reboot    (потом reboot)"
    echo "    ./nvme-pmcheck.sh --mark after-reboot"
  elif [ "$rs" -gt 0 ]; then
    echo "  Счётчик растёт И устройство реально уходит в runtime-сон:"
    echo "  цикл питания настоящий, виновата политика PCI-PM."
    echo "  Проверить: echo on | sudo tee /sys/bus/pci/devices/$PCI/power/control"
  else
    echo "  Счётчик растёт, но D3 не было ни разу (runtime_suspended_time не"
    echo "  изменился). Значит прошивка считает за 'цикл питания' выходы из"
    echo "  неоперационных состояний APST (PS3/PS4) или из ASPM L1.2."
    echo "  Реального обесточивания нет — износ ячеек это не ускоряет,"
    echo "  счётчик просто врёт. Проверяется отключением APST:"
    echo "    nvme_core.default_ps_max_latency_us=0 в командной строке ядра"
    echo "    (через LINUX_OPTIONS в /etc/sdboot-manage.conf + sdboot-manage gen —"
    echo "     modprobe.d не сработает, nvme_core грузится из initramfs)"
  fi

  csv_init
  awk -v ts="$(date -Iseconds)" -v t="$dt" -v pc="$pc1" -v d="$d" -v u="$us1" \
      -v poh="$(smn power_on_hours)" -v rs="${rts1:-0}" -v pu="$(sm percentage_used)" 'BEGIN{
    printf "%s,interval,,%d,%d,%d,%.1f,%s,%s,%d,%s\n", ts, t, pc, d, (t>0? d*3600/t : 0), u, poh, rs, pu }' >> "$CSV"
  echo
  echo "  Записано в $(basename "$CSV")"
fi
echo "═══════════════════════════════════════════════════════"
