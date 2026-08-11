/*
 * NVST — записать режим в EC-регистр STNM (1/2/3) и прогнать штатный
 * обработчик _Q24, как это делает сам EC при смене режима. Точное
 * воспроизведение вечера 21.07: NVST 3 = состояние, в котором карта была
 * разлочена (33 Вт / потолок 50 Вт). Отдельная таблица, чтобы грузиться
 * независимо от nvpcf-fix (методы в разных таблицах не должны дублироваться).
 *
 * Использование (или через nvpcf-unlock.sh --stnm 3):
 *   sudo mkdir /sys/kernel/config/acpi/table/nvpcfstnm
 *   sudo tee /sys/kernel/config/acpi/table/nvpcfstnm/aml < nvpcf-stnm.aml >/dev/null
 *   echo '\NVST 3' | sudo tee /proc/acpi/call && sudo cat /proc/acpi/call
 */
DefinitionBlock ("", "SSDT", 2, "GPUDBG", "NVPCFSTN", 0x00000001)
{
    External (\_SB.PC00.LPCB.H_EC.STNM, FieldUnitObj)
    External (\_SB.PC00.LPCB.H_EC._Q24, MethodObj)

    Method (\NVST, 1, Serialized)
    {
        \_SB.PC00.LPCB.H_EC.STNM = Arg0
        \_SB.PC00.LPCB.H_EC._Q24 ()
        Return (\_SB.PC00.LPCB.H_EC.STNM)
    }
}
