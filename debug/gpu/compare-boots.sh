#!/usr/bin/env bash
# Сравнить снимки хорошей и плохой загрузки, которые сохранил bootcheck.sh.
# Без аргументов берёт самый свежий снимок каждого вида.
#
#   ./compare-boots.sh
#   ./compare-boots.sh snapshots/ХОРОШАЯ_... snapshots/ПЛОХАЯ_...
set -uo pipefail
cd "$(dirname "$0")"

G="${1:-$(ls -dt snapshots/ХОРОШАЯ_* 2>/dev/null | head -1)}"
B="${2:-$(ls -dt snapshots/ПЛОХАЯ_*  2>/dev/null | head -1)}"

[ -n "$G" ] && [ -d "$G" ] || { echo "Нет снимка хорошей загрузки. Гоняй ./bootcheck.sh после каждой перезагрузки, пока не поймаешь."; exit 1; }
[ -n "$B" ] && [ -d "$B" ] || { echo "Нет снимка плохой загрузки."; exit 1; }

echo "═══════════════════════════════════════════════════════"
echo " ХОРОШАЯ: $(basename "$G")"
echo " ПЛОХАЯ : $(basename "$B")"
echo "═══════════════════════════════════════════════════════"
echo
echo "── Вердикты ──────────────────────────────────────────"
paste -d'\n' <(sed 's/^/  Х: /' "$G/verdict.txt") <(sed 's/^/  П: /' "$B/verdict.txt")

show_diff() {
  local name="$1" f="$2"
  echo
  echo "── $name ────────────────────────────────────────────"
  if [ -f "$G/$f" ] && [ -f "$B/$f" ]; then
    if diff -q "$G/$f" "$B/$f" >/dev/null 2>&1; then
      echo "  идентично"
    else
      diff "$G/$f" "$B/$f" | sed 's/^</  Х:/; s/^>/  П:/' | head -30
    fi
  else
    echo "  нет данных"
  fi
}

show_diff "Параметры драйвера nvidia" nvidia-params.txt
show_diff "Питание GPU (RTD3 и прочее)" nvidia-power.txt
show_diff "mkinitcpio" mkinitcpio.txt
show_diff "modprobe.d" modprobe.d.txt

echo
echo "── Журнал ядра: строки, которых нет во второй загрузке ──"
if [ -f "$G/kernel.log.gz" ] && [ -f "$B/kernel.log.gz" ]; then
  norm() { zcat "$1" | sed -E 's/^\[ *[0-9]+\.[0-9]+\] //; s/0x[0-9a-fA-F]+/0xADDR/g; s/\b[0-9]{4,}\b/NUM/g'; }
  echo "  ТОЛЬКО В ХОРОШЕЙ:"
  comm -23 <(norm "$G/kernel.log.gz" | sort -u) <(norm "$B/kernel.log.gz" | sort -u) \
    | grep -viE "wlp0s20f3|UFW BLOCK|systemd-journald|Bluetooth|usb |audit" | head -20 | sed 's/^/    /'
  echo
  echo "  ТОЛЬКО В ПЛОХОЙ:"
  comm -13 <(norm "$G/kernel.log.gz" | sort -u) <(norm "$B/kernel.log.gz" | sort -u) \
    | grep -viE "wlp0s20f3|UFW BLOCK|systemd-journald|Bluetooth|usb |audit" | head -20 | sed 's/^/    /'
else
  echo "  нет журналов в снимках"
fi

echo
echo "── Тайминги инициализации ────────────────────────────"
for tag in "$G:ХОРОШАЯ" "$B:ПЛОХАЯ"; do
  d="${tag%%:*}"; n="${tag##*:}"
  [ -f "$d/kernel.log.gz" ] || continue
  echo "  $n:"
  zcat "$d/kernel.log.gz" | grep -E "NVRM: loading|nvidia-modeset: Loading|nvidia-drm\] \[GPU ID|i915 .*Found alderlake" \
    | sed -E 's/(\[ *[0-9]+\.[0-9]+\]).*(NVRM: loading|nvidia-modeset|GPU ID|Found alderlake).*/    \1 \2/' | head -4
done
echo "═══════════════════════════════════════════════════════"
