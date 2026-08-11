/*
 * NVSW — записать режим в EC-регистр STNM БЕЗ вызова _Q24.
 * Нужен, потому что _Q24, выполненный пока EC отдаёт STNM=2, попадает в
 * ветку «Dynamic Boost вкл» и ЛОЧИТ карту (наступили 22.07). Безопасный
 * порядок: NVSW 3 → ждать, пока чтение STNM не вернёт 3 → только после
 * этого _Q24. Реализовано в nvpcf-unlock.sh (режим по умолчанию).
 */
DefinitionBlock ("", "SSDT", 2, "GPUDBG", "NVPCFSET", 0x00000001)
{
    External (\_SB.PC00.LPCB.H_EC.STNM, FieldUnitObj)

    Method (\NVSW, 1, Serialized)
    {
        \_SB.PC00.LPCB.H_EC.STNM = Arg0
        Return (\_SB.PC00.LPCB.H_EC.STNM)
    }
}
