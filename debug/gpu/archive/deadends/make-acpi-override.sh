#!/bin/bash
# Устанавливает ПОСТОЯННОЕ решение: патченную таблицу NvdTable через
# механизм ядра «ACPI table upgrade via initrd». Патч закрывает гейт NVPCF
# (_DSM больше не отдаёт GSP кривую таблицу лимитов 15/20 Вт) — карта всегда
# живёт на vBIOS-дефолтах (35 Вт), гонка с EC становится безразлична.
#
#   sudo ./make-acpi-override.sh
#
# Создаёт:
#   /boot/acpi-override.img                        — cpio с патченной таблицей
#   /boot/loader/entries/zz-cachyos-acpifix.conf   — ОТДЕЛЬНАЯ загрузочная
#       запись «CachyOS (ACPI fix)». Штатные записи не трогаются, sdboot-manage
#       о ней не знает и не перезапишет.
#
# Проверка после загрузки через новую запись:
#   ./bootcheck.sh                     — ожидается ХОРОШАЯ (30+ Вт)
#   journalctl -k -b 0 | grep -i "ACPI: table upgrade\|NvdTable"
#
# Откат: выбрать обычную запись в меню загрузки, либо удалить оба файла.
set -euo pipefail
cd "$(dirname "$0")"

[ "$(id -u)" = 0 ] || { echo "нужен root: sudo $0"; exit 1; }
AML=acpi/nvdtable-patched.aml
[ -f "$AML" ] || { echo "нет $AML — собери: cd acpi && iasl nvdtable-patched.dsl"; exit 1; }

# 1. cpio с таблицей по пути, где её ищет ядро
d=$(mktemp -d)
mkdir -p "$d/kernel/firmware/acpi"
cp "$AML" "$d/kernel/firmware/acpi/nvdtable-patched.aml"
(cd "$d" && find kernel -type f -o -type d | cpio -H newc -o --quiet) > /boot/acpi-override.img
rm -rf "$d"
echo "✔ /boot/acpi-override.img создан ($(stat -c%s /boot/acpi-override.img) байт)"

# 2. загрузочная запись: копия штатной cachyos-записи + наша строка initrd
#    ПЕРЕД остальными initrd (порядок важен: ядро сканирует все, но кладём
#    первым по канону Arch Wiki)
src=$(grep -rl "vmlinuz-linux-cachyos" /boot/loader/entries/ 2>/dev/null | grep -v lts | grep -v acpifix | head -1)
[ -n "$src" ] || { echo "✖ не нашёл штатную запись cachyos в /boot/loader/entries/"; exit 1; }
dst=/boot/loader/entries/zz-cachyos-acpifix.conf
awk '
  /^title/   { print "title CachyOS (ACPI fix — NVPCF off)"; next }
  /^initrd/ && !done { print "initrd  /acpi-override.img"; done=1 }
  { print }
' "$src" > "$dst"
echo "✔ $dst создан на основе $(basename "$src"):"
sed 's/^/    /' "$dst"
echo
echo "Дальше: перезагрузка → в меню systemd-boot выбрать «CachyOS (ACPI fix)»"
echo "→ ./bootcheck.sh. Если всё хорошо и хочется сделать записью по умолчанию:"
echo "  добавь в /boot/loader/loader.conf строку: default zz-cachyos-acpifix.conf"
