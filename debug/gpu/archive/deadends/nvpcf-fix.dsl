/*
 * Лечебный SSDT: метод \NVFX переписывает переменные \_SB.NPCF на вменяемые
 * и шлёт драйверу Notify 0xC0 «перечитай конфиг питания».
 *
 * Идея: заводская таблица Xiaomi отдаёт GSP TPP AC = 20 Вт (0xA0 в 1/8 Вт),
 * из-за чего карта душится до ~17 Вт вместо vBIOS-дефолта 35. Ставим TPP 45 Вт
 * (перестаёт быть ограничителем), CTGP-оффсеты 0 (никакого разгона, только
 * возврат к штатным 35 Вт), Dynamic Boost включён.
 *
 * Загрузка на лету (обратимо перезагрузкой):
 *   sudo modprobe acpi_configfs acpi_call
 *   sudo mkdir /sys/kernel/config/acpi/table/nvpcffix
 *   sudo tee /sys/kernel/config/acpi/table/nvpcffix/aml < nvpcf-fix.aml >/dev/null
 *   echo '\NVFX' | sudo tee /proc/acpi/call && sudo cat /proc/acpi/call
 */
DefinitionBlock ("", "SSDT", 2, "GPUDBG", "NVPCFFIX", 0x00000001)
{
    External (\_SB.NPCF, DeviceObj)
    External (\_SB.NPCF.DBAC, IntObj)
    External (\_SB.NPCF.DBDC, IntObj)
    External (\_SB.NPCF.ACBT, IntObj)
    External (\_SB.NPCF.DCBT, IntObj)
    External (\_SB.NPCF.AMAT, IntObj)
    External (\_SB.NPCF.AMIT, IntObj)
    External (\_SB.NPCF.ATPP, IntObj)
    External (\_SB.NPCF.DTPP, IntObj)
    External (\_SB.PC00.PEG0.PEGP, DeviceObj)

    /*
     * NVOF — воспроизводит ветку _Q24 для STNM==3, при которой наблюдалось
     * разлоченное состояние (33 Вт / потолок 50): буст-контроллер ВЫКЛ,
     * оффсеты 0, и уведомление драйверу перечитать конфиг.
     * Пробовать ПЕРВЫМ при задушенной карте.
     */
    Method (\NVOF, 0, Serialized)
    {
        \_SB.NPCF.DBAC = Zero
        \_SB.NPCF.DBDC = Zero
        \_SB.NPCF.ACBT = Zero
        \_SB.NPCF.DCBT = Zero
        Notify (\_SB.PC00.PEG0.PEGP, 0xC0)
        Notify (\_SB.NPCF, 0xC0)
        Return (Zero)
    }

    /*
     * NVFX — альтернатива: буст-контроллер ВКЛ, но с вменяемым TPP 45 Вт
     * вместо заводских 20. Пробовать, если NVOF не помог.
     * (Метод NVST — смена режима EC — в отдельной таблице nvpcf-stnm.dsl,
     * чтобы таблицы можно было грузить независимо.)
     */
    Method (\NVFX, 0, Serialized)
    {
        \_SB.NPCF.DBAC = One        // Dynamic Boost AC вкл
        \_SB.NPCF.DBDC = One        // Dynamic Boost DC вкл
        \_SB.NPCF.ACBT = Zero       // CTGP-оффсет AC: 0 → штатные 35 Вт, без разгона
        \_SB.NPCF.DCBT = Zero
        \_SB.NPCF.AMAT = 0x50       // макс буст-оффсет 10 Вт (заводское значение ветки PDFG&8)
        \_SB.NPCF.AMIT = Zero
        \_SB.NPCF.ATPP = 0x0168     // TPP AC 45 Вт — больше не ограничитель
        \_SB.NPCF.DTPP = 0x78       // TPP DC 15 Вт — узаконить наблюдаемый DC-режим
        Notify (\_SB.PC00.PEG0.PEGP, 0xC0)
        Notify (\_SB.NPCF, 0xC0)
        Return (Zero)
    }
}
