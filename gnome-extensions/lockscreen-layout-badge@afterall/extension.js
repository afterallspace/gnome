import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js'
import { getInputSourceManager } from 'resource:///org/gnome/shell/ui/status/keyboard.js'
import * as Main from 'resource:///org/gnome/shell/ui/main.js'

const LABELS = {
  us: '🇺🇸',
  ru: '🇷🇺',
}

export default class LockscreenLayoutBadge extends Extension {
  enable() {
    // session-modes включает unlock-dialog, поэтому при блокировке
    // экрана disable() не вызывается и подписи остаются нашими.
    this._ism = getInputSourceManager()
    this._original = new Map()
    this._sourceSignals = new Map()
    this._sourcesChangedId = this._ism.connect('sources-changed', () => this._applyAll())
    this._applyAll()
  }

  _applyAll() {
    for (const [source, id] of this._sourceSignals) source.disconnect(id)
    this._sourceSignals.clear()

    for (const i in this._ism.inputSources) {
      const source = this._ism.inputSources[i]
      this._apply(source)
      // если чей-то disable() вернёт стандартную подпись — переустановим
      const id = source.connect('changed', () => this._apply(source))
      this._sourceSignals.set(source, id)
    }

    this._pinWidth()
  }

  // В момент переключения раскладки пересчёт ширины индикатора транзиентно
  // гуляет на субпиксель и дёргает соседние иконки. CSS тут бессилен:
  // и контейнер индикатора, и кнопка панели переопределяют vfunc расчёта
  // ширины и не читают width из стиля. Поэтому фиксируем аллокацию всей
  // кнопки на уровне Clutter — set_width() перекрывает любые vfunc.
  _pinWidth() {
    const button = Main.panel.statusArea.keyboard
    if (!button) return
    button.set_width(-1) // сброс фиксации, чтобы замерить натуральную ширину
    const [, natural] = button.get_preferred_width(-1)
    button.set_width(Math.ceil(natural))
  }

  _apply(source) {
    const label = LABELS[source.id]
    if (!label || source.shortName === label) return
    if (!this._original.has(source.id)) this._original.set(source.id, source.shortName)
    source.shortName = label // сеттер сам обновляет индикатор и OSD
  }

  disable() {
    // Вызывается только при настоящем отключении расширения,
    // не при блокировке экрана (см. session-modes).
    this._ism.disconnect(this._sourcesChangedId)
    for (const [source, id] of this._sourceSignals) source.disconnect(id)
    this._sourceSignals.clear()

    for (const i in this._ism.inputSources) {
      const source = this._ism.inputSources[i]
      if (this._original.has(source.id)) source.shortName = this._original.get(source.id)
    }
    Main.panel.statusArea.keyboard?.set_width(-1)
    this._original = null
    this._ism = null
  }
}
