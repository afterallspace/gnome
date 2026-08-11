#!/usr/bin/env bash
# Прячет приложения из сетки GNOME, не ломая ассоциации файлов.
#
#   ./hide-apps.sh           — пересоздать все оверрайды из списка ниже
#   ./hide-apps.sh list      — статус: что скрыто, что устарело, чего нет
#   ./hide-apps.sh restore <имя.desktop>  — вернуть приложение в сетку
#
# Как это работает: файл в ~/.local/share/applications ЗАМЕЩАЕТ системный
# целиком, а не дополняет его. Поэтому оверрайд — полная копия системного
# .desktop с добавленным NoDisplay=true: так сохраняются MimeType, и файл
# по-прежнему открывается двойным кликом из Nautilus.
#
# NoDisplay=true, а не Hidden=true: второй означает «удалено пользователем»
# и убивает заодно все ассоциации.
#
# Обратная сторона копии — она не обновляется вместе с пакетом. Если
# приложение добавит новый MimeType, оверрайд заморозит старый список.
# Лечится перезапуском этого скрипта; `list` показывает, где это назрело.
set -uo pipefail

SRC=/usr/share/applications
DST="$HOME/.local/share/applications"

# ── что прячем ──────────────────────────────────────────────────────────
# Открываю только из проводника, в сетке не нужны:
APPS=(
  org.gnome.Loupe.desktop        # Image Viewer
  org.gnome.Decibels.desktop     # Audio Player
  org.gnome.Showtime.desktop     # Video Player
  org.gnome.Evince.desktop       # Document Viewer
)
# Служебный хлам, затесавшийся в меню из зависимостей:
APPS+=(
  avahi-discover.desktop         # Avahi Zeroconf Browser
  bssh.desktop                   # Avahi SSH Server Browser
  bvnc.desktop                   # Avahi VNC Server Browser
  lstopo.desktop                 # Hardware Locality lstopo
  qv4l2.desktop                  # Qt V4L2 test Utility
  qvidcap.desktop                # Qt V4L2 video capture utility
)

MODE="${1:-apply}"
mkdir -p "$DST"

# Вставляет NoDisplay=true в конец группы [Desktop Entry]. Именно в конец
# группы, а не файла: у Showtime дальше идёт [Desktop Action new-window], и
# флаг, попавший туда, не сработает.
gen() {
  awk '/^\[Desktop Action/ && !d { print "NoDisplay=true"; print ""; d=1 }
       { print }
       END { if (!d) print "NoDisplay=true" }' "$1"
}

echo "═══════════════════════════════════════════════════════"
echo " СКРЫТИЕ ПРИЛОЖЕНИЙ ИЗ СЕТКИ"
echo "═══════════════════════════════════════════════════════"

# ── вернуть приложение в сетку ──────────────────────────────────────────
if [ "$MODE" = restore ]; then
  name="${2:-}"
  [ -n "$name" ] || { echo "  Укажи файл: ./hide-apps.sh restore org.gnome.Loupe.desktop"; exit 1; }
  ok=0; for a in "${APPS[@]}"; do [ "$a" = "$name" ] && ok=1; done
  if [ "$ok" -eq 0 ]; then
    echo "  ✗ $name не в списке этого скрипта — трогать не буду."
    echo "    Здесь есть чужие оверрайды (обёртки mullvad-exclude), их сносить нельзя."
    exit 1
  fi
  if [ ! -f "$DST/$name" ]; then echo "  $name и так не скрыт."; exit 0; fi
  if ! grep -q '^NoDisplay=true' "$DST/$name"; then
    echo "  ✗ $DST/$name не похож на оверрайд этого скрипта (нет NoDisplay). Не трогаю."
    exit 1
  fi
  rm -v "$DST/$name"
  update-desktop-database "$DST" 2>/dev/null
  echo "  Готово. Убери имя из массива APPS, иначе следующий запуск скроет снова."
  exit 0
fi

# ── статус ──────────────────────────────────────────────────────────────
if [ "$MODE" = list ]; then
  for a in "${APPS[@]}"; do
    if [ ! -f "$SRC/$a" ]; then
      printf "  %-32s пакет не установлен\n" "$a"
    elif [ ! -f "$DST/$a" ]; then
      printf "  %-32s НЕ СКРЫТ\n" "$a"
    elif diff -q <(gen "$SRC/$a") "$DST/$a" >/dev/null 2>&1; then
      printf "  %-32s скрыт\n" "$a"
    else
      printf "  %-32s скрыт, но УСТАРЕЛ (системный файл изменился)\n" "$a"
    fi
  done
  echo
  echo "  Устаревшие чинятся запуском без аргументов."
  echo "═══════════════════════════════════════════════════════"
  exit 0
fi

# ── применить ───────────────────────────────────────────────────────────
made=0; skipped=0; same=0
for a in "${APPS[@]}"; do
  if [ ! -f "$SRC/$a" ]; then
    printf "  %-32s пропуск, пакет не установлен\n" "$a"; skipped=$((skipped+1)); continue
  fi
  if [ -f "$DST/$a" ] && diff -q <(gen "$SRC/$a") "$DST/$a" >/dev/null 2>&1; then
    same=$((same+1)); continue
  fi
  gen "$SRC/$a" > "$DST/$a" && printf "  %-32s скрыт\n" "$a" && made=$((made+1))
done

if [ "$made" -gt 0 ]; then update-desktop-database "$DST" 2>/dev/null; fi
echo
printf "  создано/обновлено: %s, уже было: %s, пропущено: %s\n" "$made" "$same" "$skipped"
[ "$made" -gt 0 ] && echo "  Если иконки ещё видны — перелогинься."
echo "═══════════════════════════════════════════════════════"
