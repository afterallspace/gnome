#!/usr/bin/env bash
# Разбор одного прогона: ./summary.sh runs/<каталог>
# Считает статистику только по «нагруженным» секундам (GPU util >= 30%),
# чтобы простой до/после запуска игры не размывал средние.
set -uo pipefail
D="${1:?укажи каталог прогона}"

echo "══════════════════════════════════════════════════════════════"
echo " ПРОГОН: $(basename "$D")"
echo "══════════════════════════════════════════════════════════════"
sed -n '2,$p' "$D/static.txt" 2>/dev/null | sed 's/^/  /'
echo

echo "── GPU (только секунды с util ≥ 30%) ─────────────────────────"
awk -F',' '
  { gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$5);
    gsub(/^ +| +$/,"",$7); gsub(/^ +| +$/,"",$9); gsub(/^ +| +$/,"",$10); gsub(/^ +| +$/,"",$11) }
  $5+0 >= 30 {
    n++; w+=$2; if($2+0>wm)wm=$2+0; if(wn==""||$2+0<wn)wn=$2+0
    c+=$3; if($3+0>cm)cm=$3+0
    u+=$5; t+=$7; if($7+0>tm)tm=$7+0
    gen[$9]++; wid[$10]++; reasons[$11]++
  }
  END{
    if(n==0){print "  нет секунд под нагрузкой (игра не запускалась?)"; exit}
    printf "  сэмплов под нагрузкой : %d с\n", n
    printf "  мощность GPU          : сред %.1f Вт | макс %.1f Вт | мин %.1f Вт\n", w/n, wm, wn
    printf "  частота SM            : сред %.0f МГц | макс %.0f МГц  (потолок 2100)\n", c/n, cm
    printf "  загрузка GPU          : сред %.0f %%\n", u/n
    printf "  температура           : сред %.0f °C | макс %.0f °C  (slowdown 97)\n", t/n, tm
    printf "  PCIe gen/width        : "; for(k in gen) printf "gen%s×%d с ", k, gen[k];
    for(k in wid) printf "| x%s×%d с ", k, wid[k]; printf "\n"
    printf "  причины троттлинга    :\n"
    for(k in reasons) printf "      %s  — %d с\n", k, reasons[k]
  }' "$D/gpu.csv"
echo
echo "  Расшифровка битов clocks_event_reasons:"
echo "     0x1 GpuIdle   0x4 SwPowerCap(упёрлись в power limit драйвера)"
echo "     0x8 HwSlowdown  0x40 SwThermalSlowdown"
echo "     0x80 HwThermalSlowdown  0x100 HwPowerBrakeSlowdown(EC срезал питание!)"
echo

echo "── CPU / платформа ───────────────────────────────────────────"
awk -F',' 'NR>1 && $2!="" {
    n++; p+=$2; if($2+0>pm)pm=$2+0
    s+=$3; if($3+0>sm)sm=$3+0
    f+=$5; if($5+0>fm)fm=$5+0
    t+=$6; if($6+0>tm)tm=$6+0
    b+=$10; bs[$8]++
    last_thr=$12; if(first_thr=="")first_thr=$12
    lastcore=$13; if(firstcore=="")firstcore=$13
  }
  END{
    if(n==0){print "  нет данных RAPL"; exit}
    printf "  мощность пакета CPU   : сред %.1f Вт | макс %.1f Вт   (PL1=52 Вт, PL2=64 Вт)\n", p/n, pm
    printf "  мощность PSYS (вся платформа): сред %.1f Вт | макс %.1f Вт   (лимит 56 Вт)\n", s/n, sm
    printf "  частота CPU (макс ядро): сред %.0f МГц | пик %.0f МГц\n", f/n, fm
    printf "  температура пакета    : сред %.0f °C | макс %.0f °C\n", t/n, tm
    printf "  мощность батареи      : сред %.1f Вт  (>0 при зарядке = ест бюджет адаптера)\n", b/n
    printf "  состояние батареи     : "; for(k in bs) printf "%s×%dс ", k, bs[k]; printf "\n"
    printf "  прирост package_throttle: %d   core_throttle: %d\n", last_thr-first_thr, lastcore-firstcore
  }' "$D/sys.csv"
echo

echo "── ГЛАВНЫЙ ВОПРОС: куда ушёл бюджет ──────────────────────────"
gpu_avg=$(awk -F',' '{gsub(/ /,"",$2);gsub(/ /,"",$5)} $5+0>=30 {n++;w+=$2} END{if(n)printf "%.1f",w/n; else print 0}' "$D/gpu.csv")
awk -F',' -v g="$gpu_avg" 'NR>1 && $2!="" {n++;p+=$2;b+=$10} END{
  if(!n){print "  нет данных"; exit}
  cpu=p/n; bat=b/n; tot=cpu+g+bat
  printf "  CPU пакет      %6.1f Вт\n", cpu
  printf "  GPU            %6.1f Вт\n", g
  printf "  заряд батареи  %6.1f Вт\n", bat
  printf "  ─────────────────────────\n"
  printf "  ИТОГО из адаптера ≈ %.1f Вт (+ экран/SSD/Wi-Fi ≈ 8–12 Вт)\n", tot
  printf "  → нагрузка на адаптер ≈ %.0f Вт\n", tot+10
  if (tot+10 > 95) print "  ⚠ УПИРАЕМСЯ В 100-ВАТТНЫЙ АДАПТЕР — EC будет срезать GPU."
  if (bat > 5 && g < 25) print "  ⚠ Батарея заряжается и одновременно GPU недобирает — сильный признак дележа бюджета."
}' "$D/sys.csv"
echo "══════════════════════════════════════════════════════════════"
