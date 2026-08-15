# Эксплуатация: разлочка GPU на каждый день

Короткий runbook. Механизм и история — [SOLUTION.md](SOLUTION.md),
расследование — [INVESTIGATION.md](INVESTIGATION.md).

## Как это работает в норме

При каждом входе в сессию user-юнит `nvpcf-unlock.service` (через 15 с)
запускает `nvpcf-session-unlock.sh`: греет дискретку glmark'ом, меряет
частоту SM под нагрузкой и, если она заперта на ~1327 МГц, до трёх раз
прогоняет рецепт `NVST 3 → 20 с → NVST 1` через root-хелпер
`/usr/local/bin/nvpcf-boot-fix.sh`. Итог — только в журнале (файловое
логирование снято 15.08.2026, ветка закрыта).

**Проверка после загрузки:**
`journalctl --user -u nvpcf-unlock.service -b 0` — ищите
`OK: already unlocked` или `OK: unlocked (attempt N)`.
Не запускать `bootcheck.sh` в первые ~2 минуты после входа (сервис работает).

## Если карта задушена (17 FPS, 1327 МГц)

```fish
cd ~/.config/debug/gpu
prime-run glmark2 --off-screen -b shading:duration=600 &   # нагрузка
sudo ./nvpcf-unlock.sh                                     # проверенный рецепт
./bootcheck.sh                                             # вердикт
```
Вердикт всегда по частоте: ~1327 МГц = лок, 1600+ = свобода. Ваттам не
верить (батарея/голодная зарядка их занижают).

## Переустановка автоматики с нуля (после переустановки ОС и т.п.)

```fish
sudo pacman -S --needed acpi_call-dkms glmark2 nvidia-prime
sudo install -o root -g root -m 755 ~/.config/debug/gpu/nvpcf-boot-fix.sh /usr/local/bin/nvpcf-boot-fix.sh
sudo mkdir -p /usr/local/share/nvpcf-fix
sudo cp ~/.config/debug/gpu/acpi/nvpcf-stnm.aml /usr/local/share/nvpcf-fix/
echo "afterall ALL=(root) NOPASSWD: /usr/local/bin/nvpcf-boot-fix.sh" | sudo tee /etc/sudoers.d/nvpcf-fix
# юнит лежит в ~/.config/systemd/user/nvpcf-unlock.service
systemctl --user daemon-reload && systemctl --user enable nvpcf-unlock.service
```

Если пропал `nvpcf-stnm.aml` — пересобрать из исходника:
`cd ~/.config/debug/gpu/acpi && iasl nvpcf-stnm.dsl` (пакет `acpica`).

## После обновлений

- **Ядро** — ничего не делать (acpi_call пересобирается dkms).
- **Драйвер NVIDIA** — прогнать `./bootcheck.sh` в плохой и после разлочки;
  если рецепт перестал работать, см. SOLUTION.md → «Дальше по приоритету».
- **BIOS** — пере-снять ACPI-дамп (инструкция в SOLUTION.md), сверить
  `\_SB.NPCF` и `_Q24`; рецепт перепроверить.

## Полное удаление

```fish
systemctl --user disable --now nvpcf-unlock.service
rm ~/.config/systemd/user/nvpcf-unlock.service
sudo rm /usr/local/bin/nvpcf-boot-fix.sh /etc/sudoers.d/nvpcf-fix
sudo rm -r /usr/local/share/nvpcf-fix
sudo pacman -R acpi_call-dkms   # по желанию
```

## Карта файлов

| Файл | Роль |
|---|---|
| `nvpcf-session-unlock.sh` | обёртка юнита: нагрузка, вердикт по частоте, до 3 попыток |
| `nvpcf-boot-fix.sh` | root-хелпер: SSDT + NVST 3 → NVST 1 (копия в /usr/local/bin) |
| `nvpcf-unlock.sh` | ручной запуск рецепта и EC-эксперименты |
| `nvpcf-peek.sh` | чтение ACPI-переменных механизма (`--dsm`, `--kick`) |
| `acpi/nvpcf-stnm.dsl/.aml` | runtime-SSDT с методом `\NVST` |
| `bootcheck.sh` | вердикт загрузки (25 с), без записи — чистая диагностика |
| `archive/` | закрытое наблюдение: `monitor.sh`, `summary.sh`, `compare-boots.sh` |
| `archive/deadends/` | тупиковые инструменты (override-таблицы и пр.) — не использовать |
| `BUGREPORT.md` | текст багрепорта для NVIDIA |

Сопутствующее: gamemode-лок частот для игр — `/usr/local/bin/gamemode-tweaks.sh`
(вызывается через `gamemoderun %command%`, конфиг `~/.config/gamemode.ini`).
