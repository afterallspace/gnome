#!/usr/bin/env bash
# Toggle screen recording via gpu-screen-recorder.
#
#   gsr-toggle          start / stop at native resolution
#   gsr-toggle 1080p    start / stop scaled down to 1080p height
#
# Если запись уже идёт, любой из вариантов её останавливает.
set -euo pipefail

OUTDIR="$(xdg-user-dir VIDEOS 2>/dev/null || echo "$HOME/Videos")/Recordings"
RUNDIR="${XDG_RUNTIME_DIR:-/tmp}"
PIDFILE="$RUNDIR/gsr-toggle.pid"
FILEREF="$RUNDIR/gsr-toggle.file"
LOCKFILE="$RUNDIR/gsr-toggle.lock"
LOGFILE="$RUNDIR/gsr-toggle.log"
# STARTFILE — момент, когда РЕАЛЬНО пошёл захват (по нему считает таймер в
# панели). LAUNCHFILE — момент запуска процесса. Это разные вещи: между ними
# висит диалог портала с выбором источника, и сколько он провисит, зависит от
# пользователя. Дребезг бинда меряем по LAUNCHFILE, иначе он не отработает,
# пока диалог открыт.
STARTFILE="$RUNDIR/gsr-toggle.start"
LAUNCHFILE="$RUNDIR/gsr-toggle.launch"

# Бинд в GNOME иногда срабатывает дважды подряд; стоп раньше этого порога
# считаем дребезгом и игнорируем.
MIN_RUN_MS=1500

now_ms() { date +%s%3N; }

# Ядро обрезает comm до 15 символов (TASK_COMM_LEN), поэтому pkill по полному
# имени не матчит никогда, а по обрезанному — цепляет и постороннее.
# Единственный надёжный способ — pid-файл со сверкой по /proc.
running_pid() {
    local pid
    [[ -s $PIDFILE ]] || return 1
    pid=$(<"$PIDFILE")
    [[ $pid =~ ^[0-9]+$ ]] || return 1
    [[ $(cat "/proc/$pid/comm" 2>/dev/null) == gpu-screen-reco ]] || return 1
    printf '%s' "$pid"
}

case ${1:-} in
    ""|1080p) ;;
    *) echo "usage: ${0##*/} [1080p]" >&2; exit 2 ;;
esac

# Сериализуем вызовы: два одновременных нажатия не должны разъехаться.
exec 9>"$LOCKFILE"
flock 9

if pid=$(running_pid); then
    launched=0
    if [[ -s $LAUNCHFILE ]]; then
        launched=$(<"$LAUNCHFILE")
    fi
    if (( $(now_ms) - launched < MIN_RUN_MS )); then
        exit 0   # дребезг бинда, не трогаем запись
    fi
    # Уборку сделает надзорный процесс, который ждёт этот pid.
    kill -INT "$pid"
    exit 0
fi

# Внимание: конструкция `[[ ... ]] && var=...` здесь недопустима — при ложном
# условии она возвращает 1 и set -e молча убивает скрипт.
scale_args=()
if [[ ${1:-} == 1080p ]]; then
    scale_args=(-s 1920x1080)
fi

mkdir -p "$OUTDIR"
FILE="$OUTDIR/Screencast From $(date '+%Y-%m-%d %H-%M-%S').mp4"
printf '%s' "$FILE" >"$FILEREF"
printf '%s' "$(now_ms)" >"$LAUNCHFILE"
rm -f "$STARTFILE"

# Лог обязательно чистить ЗДЕСЬ, в родителе. Перенаправление `>"$LOGFILE"` ниже
# отрабатывает уже в дочернем процессе, после fork, то есть асинхронно — и
# сторож успевает сделать grep по логу ПРОШЛОЙ записи, найти там `update fps:`
# и мгновенно поставить отметку о начале захвата. Индикатор тогда появляется
# ещё во время выбора источника, а таймер считает не с того момента.
: >"$LOGFILE"

# Кодирование идёт на iGPU (VAAPI): портал отдаёт буфер оттуда же, где рисует
# Mutter, поэтому копирования между GPU нет и дискретка не просыпается.
# Пишется только системный звук. Чтобы добавить микрофон в ту же дорожку:
#   -a 'default_output|default_input'
# stdbuf обязателен: при выводе в файл libc буферизует блоками по 4 КБ, и строки
# долетают до лога с большим опозданием — сторож ниже их не видит вовремя.
# stdbuf делает exec, поэтому pid остаётся pid-ом самого рекордера.
stdbuf -oL -eL gpu-screen-recorder \
    -w portal \
    -restore-portal-session yes \
    "${scale_args[@]}" \
    -f 60 \
    -q very_high \
    -k h264 \
    -ac aac \
    -a default_output \
    -cursor yes \
    -o "$FILE" </dev/null >"$LOGFILE" 2>&1 9>&- &

rec=$!
printf '%s' "$rec" >"$PIDFILE"

# Сторож: ставит отметку о фактическом начале захвата и страхует от зависания.
# Родную кнопку портала прячет расширение gsr-timer@afterall, так что остановить
# запись мимо скрипта нечем; здесь остаётся только дешёвая проверка — рекордер
# печатает строку раз в секунду, и если лог перестал расти, цикл захвата встал.
(
    # Пока открыт диалог портала, захвата ещё нет. Ждём в логе признак того,
    # что поток согласован и пошли кадры, и только тогда ставим отметку —
    # иначе таймер в панели считал бы и время выбора источника.
    while kill -0 "$rec" 2>/dev/null; do
        if grep -qE 'negotiation finished|update fps:' "$LOGFILE" 2>/dev/null; then
            printf '%s' "$(now_ms)" >"$STARTFILE"
            break
        fi
        sleep 0.1
    done

    stall=0 last_size=-1
    while kill -0 "$rec" 2>/dev/null; do
        sleep 2
        size=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
        if (( size == last_size )); then
            stall=$(( stall + 1 ))
        else
            stall=0
        fi
        last_size=$size

        if (( stall >= 5 )); then
            kill -INT "$rec" 2>/dev/null
            break
        fi
    done
) 9>&- &
watcher=$!

# Блокировку держать нельзя — иначе стоп будет ждать конца записи. Причём
# закрыть дескриптор только здесь недостаточно: flock живёт на открытом описании
# файла, и унаследованная копия в рекордере держала бы замок всю запись. Поэтому
# выше у дочернего процесса стоит явное `9>&-`.
exec 9>&-

# Дальше скрипт живёт надзорным процессом. Сюда мы попадаем при ЛЮБОМ
# завершении рекордера: наш SIGINT, клик по индикатору, краш. Поэтому состояние
# всегда убирается консистентно.
wait "$rec" || true

kill "$watcher" 2>/dev/null || true

# Отсутствие STARTFILE означает, что захват так и не начался — пользователь
# закрыл диалог портала, не выбрав источник. Записи не было, файл пустой.
captured=0
if [[ -s $STARTFILE ]]; then
    captured=1
fi

rm -f "$PIDFILE" "$STARTFILE" "$LAUNCHFILE"

if (( captured == 0 )); then
    rm -f "$FILE"
fi
