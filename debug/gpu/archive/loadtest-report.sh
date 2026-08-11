#!/usr/bin/env bash
# Отчёт по нагрузочному тесту: показывает мощность GPU/CPU в каждой фазе.
#   ./loadtest-report.sh runs/<каталог>
set -uo pipefail
D="${1:?укажи каталог прогона}"
[ -f "$D/phases.csv" ] || { echo "нет phases.csv — это не прогон loadtest.sh"; exit 1; }

echo "══════════════════════════════════════════════════════════════════════"
echo " НАГРУЗОЧНЫЙ ТЕСТ: $(basename "$D")"
echo "══════════════════════════════════════════════════════════════════════"
grep -E "battery|AC online|RAPL|nvidia power|platform_profile" "$D/static.txt" | sed 's/^--- /  /'
echo

# gpu.csv: ts в формате "YYYY/MM/DD HH:MM:SS.mmm" → переводим в epoch через date
awk -F',' 'NR>0 {print $1}' "$D/gpu.csv" > /tmp/.gts 2>/dev/null

python3 - "$D" <<'PY'
import csv, sys, datetime, statistics as st

d = sys.argv[1]

phases = []
with open(f"{d}/phases.csv") as f:
    for line in f:
        t, name = line.strip().split(',')
        phases.append((int(t), name))

def phase_of(ep):
    cur = None
    for t, name in phases:
        if ep >= t: cur = name
        else: break
    return cur

# --- GPU ---
gpu = {}
with open(f"{d}/gpu.csv") as f:
    for row in csv.reader(f):
        if len(row) < 11: continue
        try:
            ts = datetime.datetime.strptime(row[0].strip()[:19], "%Y/%m/%d %H:%M:%S")
            ep = int(ts.timestamp())
            w, sm, util, temp = float(row[1]), float(row[2]), float(row[4]), float(row[6])
            reason = row[10].strip()
        except (ValueError, IndexError):
            continue
        gpu.setdefault(ep, (w, sm, util, temp, reason))

# --- система ---
sysd = {}
with open(f"{d}/sys.csv") as f:
    r = csv.DictReader(f)
    for row in r:
        try:
            ep = int(row["epoch"])
            sysd[ep] = (float(row["pkg_w"]), float(row["psys_w"] or 0),
                        float(row["cpu_freq_max_mhz"]), float(row["pkg_temp_c"]),
                        float(row["bat_power_w"] or 0), row["bat_status"])
        except (ValueError, KeyError, TypeError):
            continue

order = ["idle", "gpu", "cpu", "both", "idle2"]
label = {"idle": "ПРОСТОЙ", "gpu": "ТОЛЬКО GPU", "cpu": "ТОЛЬКО CPU",
         "both": "GPU + CPU ВМЕСТЕ", "idle2": "ОСТЫВАНИЕ"}

print(f"{'фаза':<20} {'GPU Вт':>8} {'GPU МГц':>9} {'CPU Вт':>8} {'PSYS Вт':>9} {'CPU МГц':>9} {'бат Вт':>8}")
print("─" * 78)

res = {}
for ph in order:
    eps = [e for e in gpu if phase_of(e) == ph]
    # первые 10 с фазы отбрасываем — переходный процесс
    if eps:
        eps = sorted(eps)[10:]
    if not eps:
        continue
    gw   = st.mean(gpu[e][0] for e in eps)
    gsm  = st.mean(gpu[e][1] for e in eps)
    se   = [e for e in eps if e in sysd]
    pw   = st.mean(sysd[e][0] for e in se) if se else 0
    psw  = st.mean(sysd[e][1] for e in se) if se else 0
    cf   = st.mean(sysd[e][2] for e in se) if se else 0
    bw   = st.mean(sysd[e][4] for e in se) if se else 0
    res[ph] = (gw, gsm, pw, psw, cf, bw)
    print(f"{label[ph]:<20} {gw:>8.1f} {gsm:>9.0f} {pw:>8.1f} {psw:>9.1f} {cf:>9.0f} {bw:>8.1f}")

print()
print("══ ВЫВОД ═════════════════════════════════════════════════════════════")

g_only = res.get("gpu")
both   = res.get("both")
c_only = res.get("cpu")

if g_only and g_only[1] < 400:
    print("  ✖ ТЕСТ НЕДОСТОВЕРЕН: в фазе «только GPU» дискретка осталась на холостых")
    print(f"    {g_only[1]:.0f} МГц — нагрузка ушла на встроенную Intel, RTX 2050 спала.")
    print("    Обнови loadtest.sh (в нём должен быть prime-run) и перезапусти.")
    print("═" * 70)
    sys.exit(0)

if g_only:
    gw = g_only[0]
    print(f"  GPU в одиночку берёт {gw:.1f} Вт из положенных 35 Вт.")
    if gw < 25:
        print("  ⚠ GPU НЕ ДОБИРАЕТ свой лимит даже без нагрузки на CPU.")
        print("    → дело не в дележе с процессором, режет платформа/EC.")
    else:
        print("  ✔ Сам по себе GPU выходит на свой лимит — железо исправно.")

if g_only and both:
    drop = g_only[0] - both[0]
    pct  = 100 * drop / g_only[0] if g_only[0] else 0
    print(f"\n  При добавлении нагрузки на CPU: {g_only[0]:.1f} Вт → {both[0]:.1f} Вт "
          f"(потеря {drop:.1f} Вт, {pct:.0f} %).")
    if pct > 25:
        print("  ⚠ ПОДТВЕРЖДЁН ДЕЛЁЖ ЭНЕРГОБЮДЖЕТА: процессор отбирает питание у видеокарты.")
        print("    Лечится ограничением PL1/PL2 процессора — см. README.md, шаг 2.")
    else:
        print("  ✔ CPU у GPU бюджет не отбирает.")

if c_only:
    print(f"\n  CPU в одиночку берёт {c_only[2]:.1f} Вт (PL1 сейчас выставлен в 52 Вт "
          f"при паспортных 28 Вт для i7-1260P).")

bat = res.get("both", res.get("gpu", (0,)*6))[5]
if bat > 5:
    print(f"\n  ⚠ Батарея заряжалась во время теста ({bat:.1f} Вт). Это отъедает бюджет адаптера.")
    print("    ОБЯЗАТЕЛЬНО повтори тест при 100 % заряда — это отдельная гипотеза.")

print("═" * 70)
PY
