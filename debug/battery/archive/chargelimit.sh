#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════╗
# ║ АРХИВ. Путь закрыт 05.08.2026: обработчик SMI в BIOS XMAAD6B0P1717   ║
# ║ принимает вызов и НЕ реализует группу 0x10. Порог заряда этим не     ║
# ║ поставить. Скрипт рабочий и оставлен как перепроверка на случай      ║
# ║ нового BIOS: `diag` и `smi` дают вердикт за пару минут.              ║
# ║ Разбор — ../BATTERY.md, «Лимит заряда: расследование закрыто».       ║
# ╚══════════════════════════════════════════════════════════════════════╝
#
# Порог заряда батареи через MIFS WMI (Xiaomi/Redmi, ODM Bitland).
#
#   sudo ./chargelimit.sh              — статус: порог, здоровье, адаптер
#   sudo ./chargelimit.sh diag         — жив ли транспорт вообще, ТОЛЬКО чтение
#   sudo ./chargelimit.sh calib        — найти раскладку ответа по hwmon, ЧТЕНИЕ
#   sudo ./chargelimit.sh probe        — свип функций прошивки, ТОЛЬКО чтение
#   sudo ./chargelimit.sh raw FA 10 02 00 — один вызов, сырые байты ответа
#   sudo ./chargelimit.sh set 80       — поставить порог 40/50/60/70/80
#   sudo ./chargelimit.sh off          — снять лимит (100 %)
#
# Нужен root: пишем в /proc/acpi/call (модуль acpi_call).
#
# ── Протокол ───────────────────────────────────────────────────────────
# Метод \_SB.PC00.WMID.WMAA — это WMI-метод MiInterface класса
# MiCommonInterface, GUID B60BFB48-3E5B-49E4-A0E9-8CFFE1B3434B. Сигнатура
# WMAA(instance, method_id, buffer) → WMAA 0x0 0x1 { 32 байта }.
#
# Входной буфер (первые 8 байт значимы, остальные 24 — нули):
#   [1] операция    0xFA = GET, 0xFB = SET
#   [3] команда     0x10 = группа защиты заряда
#   [4] под-функция 0x01 здоровье, 0x02 порог, 0x03 зона, 0x06 ватты БП
#   [6] значение
# Ответ: OUT[1] = 0x80 поддержано / 0xE0 нет, OUT[6] = значение группы 0x10.
#
# Коды порога (не проценты!): 0→100 %, 1→80 % (legacy), 4→80 % (granular),
# 5→70 %, 6→60 %, 7→50 %, 8→40 %. Шкала granular: % = 120 − код·10.
# Кода для 90 % нет, прошивка его отвергает.
#
# Источник расшифровки: реверс Xiaomi PC Manager в XiControl
# (github.com/Oksion/XiControl, docs/01-wmi-protocol.md и 12-charge-levels.md),
# сверено с драйвером ядра bitland-mifs-wmi и с _WDG/WQAB из ssdt8.dsl этой
# машины. Байты рецепта с ArchWiki укладываются в этот же формат.
#
# ⚠ Лимит держит EC и ТЕРЯЕТ его на переходах питания (сон, гибернация,
#   AC↔батарея) и при перезагрузке. Нужен ре-арм — см. BATTERY.md.
#
# ⚠ НЕ ПИСАТЬ в /sys/bus/wmi/devices/B60BFB48-*/kb_mode. Драйвер ядра
#   считает команду 0x10 «режимом RGB-клавиатуры» и кладёт значение в тот же
#   байт [4], то есть запись kb_mode=fixed это SET 0x10/02 val=0 — снятие
#   лимита. На этой машине атрибут управляет зарядом, а не подсветкой.
set -uo pipefail

CALL=/proc/acpi/call
WMAA='\_SB.PC00.WMID.WMAA'
CMD_CHARGE=0x10
SUB_HEALTH=0x01
SUB_LIMIT=0x02
SUB_ZONE=0x03
SUB_WATTS=0x06
LOCK=/run/lock/mifs-wmaa.lock

die() { echo "  ✗ $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "нужен root: sudo $0 $*"

if [ ! -e "$CALL" ]; then
  modprobe acpi_call 2>/dev/null
  [ -e "$CALL" ] || die "нет $CALL — модуль acpi_call не загрузился (pacman -S acpi_call-dkms)"
fi

# ── Один вызов MiInterface ─────────────────────────────────────────────
# mifs <op> <cmd> <arg> <val> → печатает 30 байт ответа как "00 80 00 10 …"
# Падает, а не возвращает нули: молчаливый ноль здесь уже один раз стоил
# ложного вердикта в соседней ветке.
OUT=()
mifs() {
  local op=$1 cmd=$2 arg=$3 val=$4 head pad raw i
  printf -v head '0x00 0x%02x 0x00 0x%02x 0x%02x 0x00 0x%02x 0x00' \
    "$((op))" "$((cmd))" "$((arg))" "$((val))"
  pad=$(printf '0x00 %.0s' $(seq 24))

  # /proc/acpi/call один на всю систему, а с ним же работает драйвер
  # bitland-mifs-wmi: свои вызовы хотя бы сериализуем между собой
  exec 9>"$LOCK" || die "не открыть $LOCK"
  flock 9 || die "не взять блокировку $LOCK"
  echo "$WMAA 0x0 0x1 { $head $pad}" > "$CALL" || die "запись в $CALL не удалась"
  raw=$(tr -d '\0' < "$CALL")
  exec 9>&-

  case "$raw" in
    '' )        die "пустой ответ от $CALL" ;;
    Error*)     die "ACPI вернул: $raw" ;;
    'not called'*) die "acpi_call говорит «not called» — вызов не прошёл" ;;
    '{'*)       ;;
    *)          die "неожиданный ответ от $CALL: $raw" ;;
  esac

  # "{0x00, 0x80, …}" → массив
  raw=${raw#\{}; raw=${raw%\}}; raw=${raw//,/ }
  OUT=()
  for i in $raw; do OUT+=("$((i))"); done
  [ "${#OUT[@]}" -ge 7 ] || die "ответ короче 7 байт (${#OUT[@]}) — разбирать нечего"
}

# Вызов с проверкой статуса. Возвращает 1, если функция не поддержана.
mifs_ok() {
  mifs "$@"
  [ "${OUT[1]}" = 128 ]
}

# Ответ одной строкой hex — чтобы не гадать о раскладке
out_hex() {
  local i
  for i in "${!OUT[@]}"; do printf '%02x ' "${OUT[$i]}"; done
  echo
}
# Индексы над байтами: ── 0  1  2  3 …
out_ruler() {
  local i
  for i in "${!OUT[@]}"; do printf '%2d ' "$i"; done
  echo
}

# ── Таблицы кодов порога ───────────────────────────────────────────────
code_to_pct() {
  case "$1" in
    0) echo 100 ;; 1) echo 80 ;; 4) echo 80 ;;
    5) echo 70 ;;  6) echo 60 ;; 7) echo 50 ;; 8) echo 40 ;;
    *) return 1 ;;
  esac
}
pct_to_code() {
  case "$1" in
    100) echo 0 ;; 80) echo 1 ;; 70) echo 5 ;;
    60) echo 6 ;;  50) echo 7 ;; 40) echo 8 ;;
    *) return 1 ;;
  esac
}

hdr() {
  echo "═══════════════════════════════════════════════════════"
  echo " $1"
  echo "═══════════════════════════════════════════════════════"
}

B=/sys/class/power_supply/BAT0
ADP=/sys/class/power_supply/ADP1
r() { cat "$1" 2>/dev/null; }

# ── Статус ─────────────────────────────────────────────────────────────
show_status() {
  hdr "ПОРОГ ЗАРЯДА — MIFS 0x10"

  if ! mifs_ok 0xFA $CMD_CHARGE $SUB_LIMIT 0; then
    printf "  статус в OUT[1] = 0x%02x, а ждали 0x80 (есть) или 0xE0 (нет)\n" "${OUT[1]}"
    echo "  Сырой ответ:"
    echo -n "    "; out_ruler
    echo -n "    "; out_hex
    echo
    echo "  Это НЕ вердикт «лимита нет»: раскладка ответа у прошивки"
    echo "  отличается от TM2424. Сначала откалибровать — ./chargelimit.sh calib"
    return 1
  fi

  local code=${OUT[6]} pct
  if pct=$(code_to_pct "$code"); then
    if [ "$pct" = 100 ]; then
      printf "  порог заряда           : не ограничен (код %d)\n" "$code"
    else
      printf "  порог заряда           : %d %% (код %d)\n" "$pct" "$code"
    fi
  else
    printf "  порог заряда           : код %d — вне известной таблицы\n" "$code"
  fi

  if mifs_ok 0xFA $CMD_CHARGE $SUB_HEALTH 0; then
    printf "  здоровье по прошивке   : %d %% от исходной ёмкости\n" "${OUT[6]}"
  else
    echo "  здоровье по прошивке   : не поддержано (0x10/01)"
  fi

  if mifs_ok 0xFA $CMD_CHARGE $SUB_ZONE 0; then
    printf "  индикатор зоны заряда  : %d\n" "${OUT[6]}"
  fi

  if mifs_ok 0xFA $CMD_CHARGE $SUB_WATTS 0; then
    local w=${OUT[6]}
    if [ "$w" = 0 ]; then
      echo "  адаптер                : нет питания или блок не-PD"
    else
      printf "  адаптер (PD)           : %d Вт\n" "$w"
    fi
  fi

  echo
  echo "── Батарея по sysfs ──────────────────────────────────"
  printf "  статус                 : %s (%s %%), адаптер %s\n" \
    "$(r $B/status)" "$(r $B/capacity)" \
    "$([ "$(r $ADP/online)" = 1 ] && echo воткнут || echo НЕТ)"
  local design full
  design=$(r $B/energy_full_design); full=$(r $B/energy_full)
  if [ -n "$design" ] && [ -n "$full" ]; then
    awk -v d="$design" -v f="$full" 'BEGIN{
      printf "  ёмкость                : %.2f из %.2f Вт·ч (износ %.1f %%)\n",
             f/1e6, d/1e6, 100*(1-f/d) }'
  fi
  echo "═══════════════════════════════════════════════════════"
}

# ── Запись порога ──────────────────────────────────────────────────────
# Ре-арм off→on: сначала 100 %, пауза, потом код. Так делает и OEM —
# запись нуля сбрасывает стейт-машину заряда в EC.
apply() {
  local code=$1 pct=$2 got

  mifs_ok 0xFB $CMD_CHARGE $SUB_LIMIT 0 \
    || die "прошивка отвергла сброс порога (OUT[1]=$(printf 0x%02x "${OUT[1]}"))"

  if [ "$code" != 0 ]; then
    sleep 0.08
    mifs_ok 0xFB $CMD_CHARGE $SUB_LIMIT "$code" \
      || die "прошивка отвергла код $code (OUT[1]=$(printf 0x%02x "${OUT[1]}")) — порог $pct % не поддержан на этой модели"
  fi

  # Верификация чтением: без неё «поставили» ничего не значит
  mifs_ok 0xFA $CMD_CHARGE $SUB_LIMIT 0 || die "не прочитать порог обратно"
  got=${OUT[6]}
  [ "$got" = "$code" ] \
    || die "readback не сошёлся: записали код $code, прошивка держит $got"

  if [ "$code" = 0 ]; then
    echo "  ✔ лимит снят, заряд до 100 %"
  else
    echo "  ✔ порог $pct % установлен и подтверждён чтением (код $code)"
    echo
    echo "  Лимит живёт в EC и слетает на переходах питания и при"
    echo "  перезагрузке — нужен ре-арм, см. BATTERY.md."
  fi
}

# ── Свип: что вообще отвечает прошивка. ТОЛЬКО GET, ничего не пишем ────
probe() {
  hdr "СВИП ФУНКЦИЙ MIFS (только чтение)"
  echo "  Ничего не пишется: все вызовы 0xFA/GET."
  echo
  echo "── Под-функции группы заряда 0x10 ────────────────────"
  local a c
  for a in 0 1 2 3 4 5 6 7 8; do
    mifs 0xFA $CMD_CHARGE "$a" 0
    printf "  0x10/%02x : статус 0x%02x  OUT[4]=%-4d OUT[6]=%-4d %s\n" \
      "$a" "${OUT[1]}" "${OUT[4]}" "${OUT[6]}" \
      "$([ "${OUT[1]}" = 128 ] && echo поддержано || echo —)"
  done

  echo
  echo "── Команды 0x01…0x30, arg=0 ──────────────────────────"
  for c in $(seq 1 48); do
    mifs 0xFA "$c" 0 0
    [ "${OUT[1]}" = 128 ] || continue
    printf "  cmd 0x%02x : поддержано, OUT[4]=%-4d OUT[6]=%-4d\n" \
      "$c" "${OUT[4]}" "${OUT[6]}"
  done
  echo "═══════════════════════════════════════════════════════"
}

# ── Калибровка раскладки ответа ────────────────────────────────────────
# Единственный способ не гадать: тот же метод WMAA читает обороты
# вентиляторов и температуру CPU, и результат этих чтений уже виден в
# hwmon — драйвер ядра bitland-mifs-wmi делает их сам. Сверяем сырой
# ответ с заведомо верными числами и находим, по каким индексам лежит
# полезная нагрузка на ЭТОЙ прошивке.
#
# Раскладка по драйверу (его data[] начинается с байта 4):
#   cmd 0x0D: CPU RPM = [4][5], GPU RPM = [6][7], SYS RPM = [10][11], LE
#   cmd 0x16: температура CPU = [4], °C
calib() {
  hdr "КАЛИБРОВКА РАСКЛАДКИ ОТВЕТА (только чтение)"

  local hw name f
  for f in /sys/class/hwmon/hwmon*; do
    [ "$(r "$f/name")" = bitland_mifs ] && hw=$f && break
  done
  [ -n "${hw:-}" ] || die "не найден hwmon с именем bitland_mifs — драйвер не привязался?"

  echo "  Эталон из hwmon ($hw), его пишет драйвер ядра тем же методом:"
  local fan1 fan2 fan3 temp ref_ok=1
  fan1=$(r "$hw/fan1_input"); fan2=$(r "$hw/fan2_input"); fan3=$(r "$hw/fan3_input")
  temp=$(r "$hw/temp1_input")
  [ -n "$fan1" ] || die "не прочитать $hw/fan1_input"
  [ -n "$temp" ] || die "не прочитать $hw/temp1_input"
  printf "    вентиляторы : CPU %s, GPU %s, SYS %s об/мин\n" "$fan1" "$fan2" "$fan3"
  printf "    температура : %d °C\n" $((temp / 1000))

  # Ноль как эталон не годится: он значит «не прочиталось», а не «холодно».
  # Сверять раскладку по нулям — это ровно тот молчаливый ноль, который уже
  # один раз дал ложный вердикт в nvme-ветке.
  if [ "$fan1" = 0 ] && [ "$temp" = 0 ]; then
    ref_ok=0
    echo
    echo "  ⚠ ЭТАЛОН ПУСТОЙ. 0 °C при работающем CPU — это не измерение,"
    echo "    а «не прочиталось»: драйвер ядра через этот же метод получает"
    echo "    сплошные нули. Сверять раскладку не с чем — ниже только сырые"
    echo "    дампы, без сопоставления."
  fi
  echo

  # ── Тест на эхо: жив ли вообще SMI ───────────────────────────────────
  # Шлём узор, которого не бывает в осмысленном ответе. Если он вернётся
  # (пусть и со сдвигом) — обработчик SMI не отработал, и мы читаем
  # собственный буфер из общей памяти. Если ответ другой — прошивка
  # что-то посчитала, и раскладку надо искать.
  echo "── Тест на эхо: 0xFA cmd=0xAA arg=0xBB val=0xCC ──────"
  mifs 0xFA 0xAA 0xBB 0xCC
  echo "    IN : 00 fa 00 aa bb 00 cc 00"
  echo -n "    ── "; out_ruler
  echo -n "    OUT "; out_hex
  local joined=" $(out_hex)"
  if [[ "$joined" == *" aa "* && "$joined" == *" bb "* && "$joined" == *" cc "* ]]; then
    echo "    ✗ УЗОР ВЕРНУЛСЯ ЦЕЛИКОМ — это эхо нашего же буфера."
    echo "      Обработчик SMI не отработал: мы пишем в общую память и"
    echo "      читаем её обратно. Интерфейс на этой прошивке мёртв."
  else
    echo "    ✔ узор не вернулся — прошивка ответила чем-то своим,"
    echo "      значит обработчик живой и раскладку имеет смысл искать"
  fi
  echo

  echo "── GET cmd 0x0D (обороты) ────────────────────────────"
  mifs 0xFA 0x0D 0 0
  echo -n "    "; out_ruler
  echo -n "    "; out_hex
  local i lo hi v hit=0
  if [ "$ref_ok" = 1 ]; then
    echo "  Ищем $fan1 как 16 бит little-endian:"
    for i in $(seq 0 $((${#OUT[@]} - 2))); do
      lo=${OUT[$i]}; hi=${OUT[$((i+1))]}; v=$((lo + hi * 256))
      if [ "$v" = "$fan1" ]; then
        printf "    ✔ CPU RPM (%s) лежит в байтах [%d][%d]\n" "$fan1" "$i" "$((i+1))"
        printf "      → смещение payload: %+d к раскладке TM2424 (там [4][5])\n" "$((i - 4))"
        hit=1
      fi
    done
    [ "$hit" = 1 ] || echo "    ✗ значения $fan1 в ответе нет — обороты сменились между чтениями или раскладка сложнее"
  fi

  echo
  echo "── GET cmd 0x16 (температура CPU) ────────────────────"
  mifs 0xFA 0x16 0 0
  echo -n "    "; out_ruler
  echo -n "    "; out_hex
  if [ "$ref_ok" = 1 ]; then
    local t=$((temp / 1000))
    echo "  Ищем $t (±2 °C, читалось не в тот же миг):"
    hit=0
    for i in "${!OUT[@]}"; do
      v=${OUT[$i]}
      if [ "$v" -ge $((t - 2)) ] && [ "$v" -le $((t + 2)) ]; then
        printf "    • кандидат: байт [%d] = %d\n" "$i" "$v"
        hit=1
      fi
    done
    [ "$hit" = 1 ] || echo "    ✗ похожего значения нет"
  fi

  echo
  echo "── GET cmd 0x10 суб 0x00…0x08 (группа заряда) ────────"
  local a
  for a in 0 1 2 3 4 5 6 7 8; do
    mifs 0xFA $CMD_CHARGE "$a" 0
    printf "  0x10/%02x : " "$a"; out_hex
  done
  echo "═══════════════════════════════════════════════════════"
}

# ── Диагностика транспорта ─────────────────────────────────────────────
# acpi_call умеет вычислять не только методы, но и именованные объекты,
# в том числе поля OperationRegion. Прочитаем служебные поля интерфейса
# напрямую и посмотрим, работает ли транспорт вообще.
#
# Раскладка региона XGNS (SystemMemory 0x44A61000, 42 байта, лежит в
# ACPI NVS — памяти прошивки, сразу за таблицей FACS):
#   MTID  8 бит   смещение 0    id метода, ставится перед SMI
#   WMIB  256 бит смещения 1-32 буфер запроса/ответа
#   CTID  16 бит  смещения 33-34 «тег» 0x4141 = "AA", ставит WMAA
#   PSSP  8 бит   смещение 35   ← НОМЕР ПОРТА I/O ДЛЯ ЗАПУСКА SMI
#
# WSMI пишет 0xD0 в порт, чей адрес берётся из PSSP. Если прошивка не
# заполнила PSSP, запись уходит в порт 0x0000 и обработчик SMI никогда
# не вызывается — тогда интерфейс мёртв, сколько в него ни пиши.
acpi_eval() {
  local path=$1 raw
  exec 9>"$LOCK"; flock 9
  echo "$path" > "$CALL" 2>/dev/null
  raw=$(tr -d '\0' < "$CALL")
  exec 9>&-
  echo "$raw"
}

diag() {
  hdr "ДИАГНОСТИКА ТРАНСПОРТА MIFS"
  local base='\_SB.PC00.WMID'

  # Сначала любой вызов WMAA — он выставляет MTID и CTID. Если эти поля
  # потом читаются обратно, значит запись в NVS доходит и возвращается.
  echo "  Делаем GET 0x10/02, затем читаем служебные поля обратно."
  mifs 0xFA $CMD_CHARGE $SUB_LIMIT 0
  echo -n "    ответ WMAA : "; out_hex
  echo

  local mtid ctid pssp wmib
  mtid=$(acpi_eval "$base.MTID")
  ctid=$(acpi_eval "$base.CTID")
  pssp=$(acpi_eval "$base.PSSP")
  wmib=$(acpi_eval "$base.WMIB")

  printf "    MTID : %s   (ждём 0x1 — id метода, который выставил WSMI)\n" "$mtid"
  printf "    CTID : %s   (ждём 0x4141 — тег, который выставил WMAA)\n" "$ctid"
  printf "    PSSP : %s   (порт I/O для запуска SMI)\n" "$pssp"
  echo "    WMIB : $wmib"
  echo

  echo "── Вердикт ───────────────────────────────────────────"
  if [ "$ctid" = "0x4141" ]; then
    echo "  ✔ запись в общую память доходит: CTID вернулся как 0x4141."
  else
    echo "  ✗ CTID вернулся как «$ctid», а не 0x4141 — запись в общую"
    echo "    память НЕ доходит или регион не тот. Тогда весь интерфейс"
    echo "    нерабочий по причине, которая лежит до всякого SMI."
  fi
  case "$pssp" in
    0x0|0x00|0)
      echo "  ✗ PSSP = 0. Порт запуска SMI не заполнен прошивкой, значит"
      echo "    WSMI пишет 0xD0 в порт 0x0000 и обработчик НЕ ВЫЗЫВАЕТСЯ."
      echo "    Это и объясняет нули у драйвера ядра: он честно зовёт метод,"
      echo "    метод честно кладёт буфер в память — и на этом всё."
      echo "    Лимит заряда так не поставить, чинить надо прошивку."
      ;;
    ''|Error*|'not called'*)
      echo "  ? PSSP не прочитался («$pssp») — поле недоступно для"
      echo "    вычисления, вердикт по нему сделать нельзя."
      ;;
    *)
      echo "  ✔ PSSP = $pssp — порт задан, SMI в принципе запускается."
      echo "    Значит дело не в транспорте, а в раскладке или в том, что"
      echo "    именно эта прошивка группу 0x10 не реализует."
      ;;
  esac
  echo "═══════════════════════════════════════════════════════"
}

# ── Свип предкомпенсации поворота ──────────────────────────────────────
# Установлено: ответ = запрос, повёрнутый влево на 2 байта, и это верно
# для любой команды, включая несуществующую. Значит буфер перекашивается
# механически, обработчик SMI видит не то, что мы послали.
#
# Гипотеза: перекос симметричный, и если повернуть запрос ВПРАВО на 2,
# в память ляжет правильный запрос. Проверяем свипом: шлём один и тот же
# логический запрос, повёрнутый на 0…7, и смотрим, не перестанет ли ответ
# быть перестановкой запроса. Перестал — значит прошивка наконец ответила.
#
# Только GET: в буфере есть 0xFA и никогда 0xFB, поэтому ни при каком
# повороте это не превратится в запись.
mifs_raw_buf() {
  # -n навешивается на КАЖДОЕ имя в объявлении, поэтому nameref объявляем
  # отдельной строкой, иначе i/str/out тоже станут namerefs и bash упадёт
  local -n _b=$1
  local i str out
  str=""
  for i in "${!_b[@]}"; do str+=$(printf '0x%02x ' "${_b[$i]}"); done
  exec 9>"$LOCK"; flock 9
  echo "$WMAA 0x0 0x1 { $str}" > "$CALL" || die "запись в $CALL не удалась"
  out=$(tr -d '\0' < "$CALL")
  exec 9>&-
  case "$out" in '{'*) ;; *) die "неожиданный ответ: $out" ;; esac
  out=${out#\{}; out=${out%\}}; out=${out//,/ }
  OUT=()
  for i in $out; do OUT+=("$((i))"); done
}

rotsweep() {
  hdr "СВИП ПРЕДКОМПЕНСАЦИИ ПОВОРОТА (только GET)"
  echo "  Логический запрос: 00 FA 00 10 02 00 00 00  (GET порога заряда)"
  echo
  echo "  Наблюдаемый поворот — это СУММА перекоса записи и чтения."
  echo "  Компенсировать надо перекос записи, а он может быть любого"
  echo "  знака, поэтому свип идёт по всем 32 позициям, а не по восьми."
  echo

  local n k s ok
  for n in $(seq "${1:-0}" "${2:-31}"); do
    # логический буфер
    local L=(0 0xFA 0 0x10 0x02 0 0 0)
    for k in $(seq 8 31); do L+=(0); done
    # поворот вправо на n: S[(i+n) mod 32] = L[i]
    local S=(); for k in $(seq 0 31); do S+=(0); done
    for k in $(seq 0 31); do S[$(( (k + n) % 32 ))]=$(( ${L[$k]} )); done

    mifs_raw_buf S

    # является ли ответ поворотом запроса?
    local found=-1
    for s in $(seq 0 31); do
      ok=1
      for k in $(seq 0 31); do
        [ "${OUT[$k]:-0}" = "${S[$(( (k + s) % 32 ))]}" ] || { ok=0; break; }
      done
      [ "$ok" = 1 ] && { found=$s; break; }
    done

    if [ "$found" -ge 0 ]; then
      printf "  n=%-2d  эхо, поворот влево на %d\n" "$n" "$found"
    else
      printf "  n=%-2d  ★ НЕ перестановка запроса — ПРОШИВКА ОТВЕТИЛА\n" "$n"
      printf "        IN  "; for k in "${!S[@]}"; do printf '%02x ' "${S[$k]}"; done; echo
      printf "        OUT "; for k in "${!OUT[@]}"; do printf '%02x ' "${OUT[$k]}"; done; echo
      echo "        статусные байты:"
      for k in "${!OUT[@]}"; do
        case "${OUT[$k]}" in
          128) printf "          [%d] = 0x80 поддержано\n" "$k" ;;
          224) printf "          [%d] = 0xE0 не поддержано\n" "$k" ;;
        esac
      done
    fi
  done
  echo "═══════════════════════════════════════════════════════"
}

# ── Считает ли процессор SMI на самом деле ─────────────────────────────
# MSR 0x34 = MSR_SMI_COUNT, счётчик обработанных SMI с момента включения.
# В драйвере msr смещение в файле и есть номер регистра, поэтому читаем
# со сдвига 0x34 = 52 БАЙТА.
#
# ⚠ Только bs=8 count=1 iflag=skip_bytes. С bs=1 count=8 dd делает восемь
#   однобайтовых чтений, а msr_read отвергает всё, что не кратно 8 байтам
#   (count % 8 → -EINVAL), и запрос молча возвращает пустоту.
#
# Это единственная независимая проверка того, что запись 0xD0 в порт 0xB2
# вообще доходит до SMM. Если счётчик не растёт, обработчик не при чём:
# SMI просто не генерируется, и никакая возня с буфером не поможет.
read_smi_count() {
  local v
  v=$(dd if=/dev/cpu/0/msr bs=8 count=1 skip=52 iflag=skip_bytes 2>/dev/null \
      | od -An -tu8 | tr -d ' ')
  [ -n "$v" ] || return 1
  echo "$v"
}

smi_test() {
  hdr "СЧЁТЧИК SMI (MSR 0x34)"

  [ -e /dev/cpu/0/msr ] || modprobe msr 2>/dev/null
  [ -e /dev/cpu/0/msr ] || die "нет /dev/cpu/0/msr — модуль msr не загрузился"

  local a b c d
  if ! a=$(read_smi_count); then
    echo "  Не прочитать MSR 0x34. Проверить по порядку:"
    printf "    lockdown : %s  (ненулевой режим режет доступ к MSR)\n" \
      "$(cat /sys/kernel/security/lockdown 2>/dev/null || echo 'нет файла')"
    printf "    устройство: %s\n" \
      "$([ -e /dev/cpu/0/msr ] && echo есть || echo 'нет — modprobe msr')"
    die "MSR недоступен"
  fi
  printf "  до вызова          : %s\n" "$a"

  # Холостая пауза той же длины: SMI на этой машине происходят и сами по
  # себе (термика, EC), поэтому нужен контроль, а не просто «выросло».
  sleep 1
  b=$(read_smi_count) || die "не прочитать MSR 0x34"
  printf "  после 1 с покоя    : %s   (фон: +%d)\n" "$b" "$((b - a))"

  mifs 0xFA $CMD_CHARGE $SUB_LIMIT 0
  c=$(read_smi_count) || die "не прочитать MSR 0x34"
  printf "  после вызова WMAA  : %s   (прирост: +%d)\n" "$c" "$((c - b))"

  sleep 1
  d=$(read_smi_count) || die "не прочитать MSR 0x34"
  printf "  ещё 1 с покоя      : %s   (фон: +%d)\n" "$d" "$((d - c))"

  echo
  echo "── Вердикт ───────────────────────────────────────────"
  local bg=$((b - a)) call=$((c - b)) bg2=$((d - c))
  if [ "$call" -gt "$bg" ] && [ "$call" -gt "$bg2" ]; then
    echo "  ✔ вызов даёт SMI сверх фона: запись 0xD0 в порт 0xB2 доходит"
    echo "    до SMM, обработчик вызывается. Значит он получает запрос и"
    echo "    сознательно ничего не отвечает — группа 0x10 в этой прошивке"
    echo "    не реализована."
  elif [ "$call" = 0 ]; then
    echo "  ✗ вызов НЕ даёт ни одного SMI. Запись в порт 0xB2 не приводит"
    echo "    к прерыванию — APMC-источник SMI отключён в чипсете. Тогда"
    echo "    интерфейс мёртв на уровне ниже ACPI, и свой SSDT не поможет:"
    echo "    он писал бы в тот же порт."
  else
    echo "  ? прирост $call при фоне $bg/$bg2 — не отличить от шума."
    echo "    Повторить в покое, желательно без нагрузки и на батарее."
  fi
  echo "═══════════════════════════════════════════════════════"
}

# ── Что РЕАЛЬНО ложится в память ───────────────────────────────────────
# Свип поворотов проверил только гипотезу «перекос записи — это поворот».
# Если это другая перестановка, повернуть вход было бесполезно в принципе.
# Регион лежит в ACPI NVS, а она не System RAM, поэтому /dev/mem до неё
# пускает даже при STRICT_DEVMEM.
#
# Зонд: шлём буфер, где байт i равен i (00 01 02 … 1f). Тогда содержимое
# памяти показывает перестановку напрямую, без перебора. Записью это стать
# не может: в байте операции 0x01, а не 0xFB.
REGION=$((0x44A61000))
REGION_LEN=42

read_region() {
  dd if=/dev/mem bs=$REGION_LEN count=1 skip=$REGION iflag=skip_bytes 2>/dev/null \
    | od -An -tx1 -v | tr -s ' ' | sed 's/^ //'
}

memprobe() {
  hdr "ЧТО РЕАЛЬНО ЛОЖИТСЯ В ПАМЯТЬ (чтение /dev/mem)"
  echo "  Регион XGNS: физический 0x44A61000, $REGION_LEN байт, ACPI NVS."
  echo "  Мы НИЧЕГО не пишем: только вызов GET и чтение памяти."
  echo

  local before after
  before=$(read_region)
  if [ -z "$before" ]; then
    echo "  ✗ не прочитать /dev/mem по 0x44A61000."
    echo "    Вероятно IO_STRICT_DEVMEM=y и регион занят драйвером."
    echo "    Тогда остаётся только свой SSDT с байтовым доступом."
    die "/dev/mem недоступен"
  fi
  echo "  до вызова :"
  echo "$before" | sed 's/^/    /'
  echo

  # зонд-идентичность: байт i = i
  local P=() i
  for i in $(seq 0 31); do P+=( "$i" ); done
  mifs_raw_buf P
  echo "  послали   : 00 01 02 03 … 1f  (байт i = i)"
  printf "  вернулось : "; out_hex

  after=$(read_region)
  echo "  в памяти после вызова :"
  echo "$after" | sed 's/^/    /'
  echo

  # разбор: байты региона 1..32 — это буфер WMIB
  local -a M=()
  for i in $after; do M+=( $((16#$i)) ); done
  echo "── Перестановка на записи ────────────────────────────"
  local clean=1 rot="" k
  for i in $(seq 0 31); do
    [ "${M[$((i+1))]:-x}" = "$i" ] || clean=0
  done
  if [ "$clean" = 1 ]; then
    echo "  ✔ в памяти лежит РОВНО то, что послали (байт i = i)."
    echo "    Значит запись чистая, а поворот на 2 целиком на чтении."
    echo "    Обработчик видел корректные запросы всё это время —"
    echo "    и не ответил ни на один. Группа 0x10 не реализована."
  else
    # проверим, не поворот ли
    for k in $(seq 0 31); do
      local ok=1
      for i in $(seq 0 31); do
        [ "${M[$((i+1))]:-x}" = "$(( (i + k) % 32 ))" ] || { ok=0; break; }
      done
      [ "$ok" = 1 ] && { rot=$k; break; }
    done
    if [ -n "$rot" ]; then
      printf "  запись поворачивает на %d. Свип это покрывал.\n" "$rot"
    else
      echo "  ★ запись перемешивает НЕ поворотом — свип этого не покрывал."
      echo "    Показать обработчику правильный запрос через штатный WMAA"
      echo "    невозможно в принципе. Нужен прямой доступ (direct)."
      printf "    карта: "
      for i in $(seq 0 31); do printf "%d→%s " "$i" "${M[$((i+1))]}"; done; echo
    fi
  fi
  printf "  MTID(байт 0) = %s   CTID(байты 33,34) = %s %s\n" \
    "${M[0]}" "${M[33]}" "${M[34]}"
  echo "═══════════════════════════════════════════════════════"
}

# ── Сырой вызов ────────────────────────────────────────────────────────
raw_call() {
  local op=${1:-0xFA} cmd=${2:-0x10} arg=${3:-0} val=${4:-0}
  case "$op" in 0xFB|0xfb|251) echo "  ⚠ это SET — прошивке будет записано" >&2 ;; esac
  mifs "$op" "$cmd" "$arg" "$val"
  printf "  IN : 00 %02x 00 %02x %02x 00 %02x 00\n" "$((op))" "$((cmd))" "$((arg))" "$((val))"
  echo -n "  ── "; out_ruler
  echo -n "  OUT "; out_hex
}

# ── Разбор аргументов ──────────────────────────────────────────────────
case "${1:-status}" in
  status|'')
    show_status
    ;;
  probe)
    probe
    ;;
  calib)
    calib
    ;;
  diag)
    diag
    ;;
  rotsweep)
    rotsweep "${2:-0}" "${3:-31}"
    ;;
  smi)
    smi_test
    ;;
  mem)
    memprobe
    ;;
  raw)
    shift
    raw_call "$@"
    ;;
  set)
    pct=${2:-}
    [ -n "$pct" ] || die "укажи порог: $0 set 80   (40/50/60/70/80)"
    code=$(pct_to_code "$pct") \
      || die "порог $pct % не из набора прошивки. Доступно: 40 50 60 70 80 (и 100 = снять). 90 % прошивка не держит."
    hdr "УСТАНОВКА ПОРОГА $pct %"
    apply "$code" "$pct"
    ;;
  off|100)
    hdr "СНЯТИЕ ЛИМИТА"
    apply 0 100
    ;;
  *)
    die "неизвестная команда «$1». Есть: status, probe, set <%>, off"
    ;;
esac
