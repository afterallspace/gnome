#!/bin/bash
# Лок частот GPU на время игры. Исходник — здесь, правится здесь.
# После правки опубликовать: см. «Публикация» внизу.
#
# 450-1400 МГц: на 35-ваттном лимите карта в адаптивном режиме мечется
# «буст 1700+ → упор в лимит → провал», теряя кадры на каждом качке.
# Лок сажает её в стабильную точку вольтаж/частота. Память на 6001 не
# даёт проваливаться на нижние уровни. Подобрано в Ghost of Tsushima.
set -u

if [ "${1:-}" == "start" ]; then
    /usr/bin/nvidia-smi -lgc 450,1400
    /usr/bin/nvidia-smi -lmc 6001,6001
elif [ "${1:-}" == "stop" ]; then
    /usr/bin/nvidia-smi -rgc
    /usr/bin/nvidia-smi -rmc
else
    echo "использование: $0 start|stop" >&2
    exit 1
fi

# Запускается отсюда напрямую: gamemode.ini → sudo <этот путь> start|stop,
# правило в /etc/sudoers.d/gamemode-tweaks. Копии в /usr/local/bin нет.
#
# ВАЖНО при правке: файл заперт на запись (chattr +i), иначе правило sudoers
# на путь внутри ~ позволяло бы любому процессу от afterall переписать его и
# получить root. Порядок работы:
#   sudo chattr -i  ~/.config/scripts/gamemode-tweaks.sh   # отпереть
#   ...правки...
#   sudo chattr +i  ~/.config/scripts/gamemode-tweaks.sh   # запереть обратно
