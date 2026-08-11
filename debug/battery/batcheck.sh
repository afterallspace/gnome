#!/usr/bin/env bash
# Состояние батареи: износ, ёмкость, тренд деградации.
#
#   ./batcheck.sh              — снимок + строка в batlog.csv (копим тренд)
#   ./batcheck.sh watch 14400  — наблюдение: пишет каждый замер в runs/,
#                                сверяет интеграл мощности с energy_now
#   ./batcheck.sh sum runs/... — разбор сохранённого прогона. Нужен, когда
#                                машина села посреди разряда и итог не успел
#                                напечататься
#
# Root не нужен, всё читается из sysfs.
set -uo pipefail

MODE="${1:-snap}"
SECS="${2:-600}"
B=/sys/class/power_supply/BAT0
ADP=/sys/class/power_supply/ADP1
CSV="$(dirname "$0")/batlog.csv"

r() { cat "$1" 2>/dev/null; }

# ── разбор сохранённого прогона ─────────────────────────────────────────
if [ "$MODE" = sum ]; then
  F="${2:-}"
  [ -f "$F" ] || { echo "  ✗ укажи файл: ./batcheck.sh sum runs/разряд_….csv"; exit 1; }
  echo "═══════════════════════════════════════════════════════"
  echo " РАЗБОР ПРОГОНА: $(basename "$F")"
  echo "═══════════════════════════════════════════════════════"
  awk -F, -v design="$(r $B/energy_full_design)" -v full="$(r $B/energy_full)" 'NR==2{
      e_first=$3; c_first=$6; integ_first=$8 }
    NR>1 { e_last=$3; c_last=$6; el=$2; integ_last=$8; psum+=$4; pn++; mode[$7]++ }
    END {
      if (pn==0) { print "  файл пуст"; exit 1 }
      # от интеграла отнимаем его значение в первой строке: он копится с
      # запуска скрипта, а первый замер ложится только через интервал
      integ = integ_last - integ_first
      printf "  длительность           : %.1f ч (%d замеров)\n", el/3600, pn
      # режим — по преобладанию во всех строках, а не по статусу первой
      for (m in mode) if (mode[m] > best) { best = mode[m]; st = m }
      printf "  режим                  : %s (%d из %d замеров)\n", st, best, pn
      printf "  заряд                  : %s %% → %s %%\n", c_first, c_last
      printf "  средняя мощность       : %.2f Вт\n", psum/pn
      printf "  отдано по интегралу    : %.3f Вт·ч\n", integ
      printf "  по счётчику energy_now : %.3f Вт·ч\n", e_first-e_last
      d = (e_first-e_last); d = (d<0? -d : d)
      if (integ>0.01) {
        printf "  расхождение            : %.1f %%", 100*(d>integ? d-integ : integ-d)/integ
        # на коротких прогонах разница тонет в дискретности energy_now
        # (шаг ~1 мВт·ч), сравнивать имеет смысл от получаса
        if (el < 1800) print "   — прогон короткий, это шум дискретности"
        else print (100*(d>integ? d-integ : integ-d)/integ < 5 ? "   ✔ счётчик связный" : "   ⚠ счётчик расходится")
      }
      dc = c_first - c_last
      if (dc >= 50) {
        printf "\n  ── Оценка реальной ёмкости ──\n"
        printf "  разряжено на %d %% отдав %.2f Вт·ч → полная ёмкость ≈ %.1f Вт·ч\n", dc, integ, integ*100/dc
        printf "  прошивка сейчас считает: %.1f Вт·ч (проектная %.1f)\n", full/1e6, design/1e6
        printf "  → износ по замеру ≈ %.1f %%, по прошивке %.1f %%\n", \
               100*(1-(integ*100/dc)*1e6/design), 100*(1-full/design)
      } else
        printf "\n  Разряд всего на %d %% — для оценки ёмкости нужно от 50 %%,\n  иначе экстраполяция врёт.\n", dc
    }' "$F"
  echo "═══════════════════════════════════════════════════════"
  exit 0
fi

if [ ! -d "$B" ]; then echo "  ✗ $B не найден"; exit 1; fi

design=$(r $B/energy_full_design); full=$(r $B/energy_full); now=$(r $B/energy_now)
volt=$(r $B/voltage_now); pw=$(r $B/power_now); st=$(r $B/status)
cap=$(r $B/capacity); cyc=$(r $B/cycle_count)

echo "═══════════════════════════════════════════════════════"
echo " БАТАРЕЯ"
echo "═══════════════════════════════════════════════════════"
printf "  производитель / модель : %s / %s\n" "$(r $B/manufacturer)" "$(r $B/model_name)"
printf "  статус                 : %s (%s %%), адаптер %s\n" \
  "$st" "$cap" "$([ "$(r $ADP/online)" = 1 ] && echo воткнут || echo НЕТ)"
echo
echo "── Ёмкость ───────────────────────────────────────────"
awk -v d="${design:-0}" -v f="${full:-0}" -v n="${now:-0}" 'BEGIN{
  printf "  проектная              : %.2f Вт·ч\n", d/1e6
  printf "  реальная               : %.2f Вт·ч\n", f/1e6
  printf "  сейчас в батарее       : %.2f Вт·ч\n", n/1e6
  if (d>0) {
    printf "  ИЗНОС                  : %.1f %%   (осталось %.1f %% от заводской)\n", 100*(1-f/d), 100*f/d
    printf "  потеряно               : %.2f Вт·ч\n", (d-f)/1e6 }}'
echo
echo "── Электрика ─────────────────────────────────────────"
awk -v v="${volt:-0}" -v p="${pw:-0}" 'BEGIN{
  printf "  напряжение             : %.3f В\n", v/1e6
  printf "  мощность               : %.2f Вт\n", p/1e6 }'
printf "  циклов заряда          : %s\n" "$([ "${cyc:-'-1'}" = "-1" ] && echo "не отдаёт прошивка" || echo "$cyc")"

# ── тренд по накопленному логу ──────────────────────────────────────────
if [ -f "$CSV" ] && [ "$(wc -l < "$CSV")" -gt 1 ]; then
  echo
  echo "── Тренд ─────────────────────────────────────────────"
  awk -F, -v curf="${full:-0}" -v curd="${design:-0}" 'NR==2 {
      first_ts=$1; first_full=$3 }
    END {
      if (first_full>0 && curd>0) {
        w0=100*(1-first_full*1e6/curd); w1=100*(1-curf/curd)
        printf "  первая запись          : %s — износ %.1f %%\n", first_ts, w0
        printf "  сейчас                 : износ %.1f %%  (%+.1f п.п.)\n", w1, w1-w0
      }}' "$CSV"
  printf "  записей в логе         : %s\n" "$(( $(wc -l < "$CSV") - 1 ))"
fi

# ── режим наблюдения ────────────────────────────────────────────────────
if [ "$MODE" = watch ]; then
  RUNS="$(dirname "$0")/runs"; mkdir -p "$RUNS"
  # Имя нейтральное намеренно: статус в момент старта ничего не говорит о
  # прогоне. 03.08 калибровочный разряд начали с воткнутым адаптером, и файл
  # назвался «заряд», хотя все 800 строк в нём — Discharging. Режим теперь
  # определяет `sum` по самим данным.
  RUN="$RUNS/прогон_$(date +%Y%m%d-%H%M%S).csv"
  echo "timestamp,elapsed_s,energy_wh,power_w,voltage_v,capacity_pct,status,integral_wh" > "$RUN"
  echo
  echo "── Наблюдение $SECS с ────────────────────────────────"
  echo "  Сверяем интеграл мощности с тем, что прошивка пишет в energy_now."
  echo "  Расхождение больше нескольких процентов = счётчик энергии врёт,"
  echo "  и тогда цифре износа тоже верить нельзя."
  echo "  Каждый замер пишется в $(basename "$RUN") сразу — если машина"
  echo "  выключится на разряде, данные останутся."
  e0="$now"; t0=$(date +%s); acc=0; prev_p="$pw"; prev_t="$t0"; n=0
  while [ $(( $(date +%s) - t0 )) -lt "$SECS" ]; do
    sleep 10
    p=$(r $B/power_now); t=$(date +%s)
    # трапеция: средняя мощность на интервале × длительность
    acc=$(awk -v a="$acc" -v p1="$prev_p" -v p2="${p:-0}" -v dt="$(( t - prev_t ))" \
          'BEGIN{ printf "%.0f", a + (p1+p2)/2*dt }')
    prev_p="${p:-0}"; prev_t="$t"; n=$((n+1))
    # строка пишется на каждом замере: разряд до отсечки иначе потеряет всё
    awk -v ts="$(date -Iseconds)" -v el="$(( t - t0 ))" -v e="$(r $B/energy_now)" \
        -v p="${p:-0}" -v v="$(r $B/voltage_now)" -v c="$(r $B/capacity)" \
        -v s="$(r $B/status)" -v a="$acc" 'BEGIN{
      printf "%s,%d,%.3f,%.2f,%.3f,%s,%s,%.4f\n", ts, el, e/1e6, p/1e6, v/1e6, c, s, a/3600/1e6 }' >> "$RUN"
    printf "\r  замеров: %-4s  прошло: %-5s с  заряд: %-3s %%  отдано: %s Вт·ч " \
      "$n" "$(( t - t0 ))" "$(r $B/capacity)" \
      "$(awk -v a="$acc" 'BEGIN{printf "%.2f", a/3600/1e6}')"
  done
  echo
  e1=$(r $B/energy_now); t1=$(date +%s)
  echo "  Прогон: $RUN"
  awk -v a="$acc" -v e0="${e0:-0}" -v e1="${e1:-0}" -v dt="$(( t1 - t0 ))" -v st="$st" 'BEGIN{
    meas = a/3600/1e6              # интеграл мощности, Вт·ч
    delta = (e1-e0)/1e6            # изменение по прошивке, Вт·ч
    printf "  по интегралу мощности  : %.3f Вт·ч\n", meas
    printf "  по счётчику energy_now : %+.3f Вт·ч\n", delta
    if (meas > 0.01) {
      d = (delta<0 ? -delta : delta)
      printf "  расхождение            : %.1f %%", 100*(d-meas>0?d-meas:meas-d)/meas
      if (100*((d>meas?d-meas:meas-d))/meas < 5) print "   ✔ счётчик энергии связный"
      else print "   ⚠ счётчик расходится, износ считать нельзя"
    } else print "  мощность около нуля — замер бесполезен, нужна нагрузка или разряд" }'
fi

# ── запись в лог ────────────────────────────────────────────────────────
[ -f "$CSV" ] || echo "timestamp,wear_pct,full_wh,design_wh,now_wh,capacity_pct,voltage_v,power_w,status,cycles" > "$CSV"
awk -v ts="$(date -Iseconds)" -v d="${design:-0}" -v f="${full:-0}" -v n="${now:-0}" \
    -v c="${cap:-0}" -v v="${volt:-0}" -v p="${pw:-0}" -v s="$st" -v cy="${cyc:-'-1'}" 'BEGIN{
  printf "%s,%.2f,%.3f,%.3f,%.3f,%s,%.3f,%.2f,%s,%s\n", ts, (d>0?100*(1-f/d):0), f/1e6, d/1e6, n/1e6, c, v/1e6, p/1e6, s, cy }' >> "$CSV"
echo
echo "  Записано в $(basename "$CSV")"
echo "═══════════════════════════════════════════════════════"
