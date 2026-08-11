#!/usr/bin/env bash
# Проверка перед запуском игры: готова система или сначала надо разгрузить память.
#   ./precheck.sh
set -uo pipefail

ok=0; warn=0

say() { printf "  %-38s %s\n" "$1" "$2"; }

echo "═══════════════════════════════════════════════════════"
echo " ГОТОВНОСТЬ К ИГРЕ"
echo "═══════════════════════════════════════════════════════"

# --- swap: главный показатель ---
sw_kb=$(awk '/^SwapTotal/{t=$2} /^SwapFree/{f=$2} END{print t-f}' /proc/meminfo)
sw_mb=$((sw_kb / 1024))
if [ "$sw_mb" -lt 200 ]; then
  say "swap занято" "${sw_mb} МБ  ✔"
  ok=$((ok+1))
else
  say "swap занято" "${sw_mb} МБ  ✖ ГЛАВНАЯ ПРОБЛЕМА"
  warn=$((warn+1))
fi

# --- доступная память ---
av_mb=$(( $(awk '/^MemAvailable/{print $2}' /proc/meminfo) / 1024 ))
if [ "$av_mb" -gt 7000 ]; then
  say "памяти доступно" "${av_mb} МБ  ✔"
  ok=$((ok+1))
else
  say "памяти доступно" "${av_mb} МБ  ✖ мало"
  warn=$((warn+1))
fi

# --- VRAM: справочно. Замером 21.07 показано, что при 968 МБ, занятых
# steamwebhelper, игра всё равно работала штатно — так что это не порог,
# а просто «что там сейчас лежит».
vram_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null)
say "видеопамять занята" "${vram_used} МБ из 4096"

# --- кто держит VRAM ---
echo
echo "  Держат видеопамять:"
# поля после снятия '|':  GPU GI CI PID TYPE ИМЯ ПАМЯТЬ
# имя = предпоследнее поле, память = последнее
nvidia-smi 2>/dev/null | awk '/Processes:/,0' | grep -E "MiB" | grep -v "GPU Memory" | \
  sed 's/|//g' | awk '{gsub(/MiB/,"",$NF); printf "      %-44s %6s МБ\n", $(NF-1), $NF}' | head -8

# --- Steam GPU-ускорение веб-вьюшек: справочно, НЕ замечание ---
# Замером 21.07 подтверждено: с включённым ускорением игра спокойно берёт
# свои 35 Вт и 99 % загрузки. Видеопамять узким местом не была.
echo
if grep -q '"GPUAccelWebViewsV3"[[:space:]]*"1"' ~/.steam/registry.vdf 2>/dev/null; then
  say "Steam: GPU-ускорение веб-вьюшек" "включено (это нормально)"
fi

# --- топ пожирателей ---
echo
echo "  Больше всего памяти сейчас:"
ps -eo rss,comm --no-headers --sort=-rss | head -6 | \
  awk '{printf "      %-42s %.0f МБ\n", $2, $1/1024}'

echo
echo "═══════════════════════════════════════════════════════"
if [ "$warn" -eq 0 ]; then
  echo " ✔ Всё чисто, можно запускать."
else
  echo " ✖ Замечаний: $warn. Разгрузи память перед игрой."
  [ "$sw_mb" -ge 200 ] && echo "   Своп не пуст — закрой браузер и мессенджеры, он схлопнется сам."
fi
echo "═══════════════════════════════════════════════════════"
