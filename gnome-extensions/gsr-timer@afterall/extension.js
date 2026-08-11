import GObject from 'gi://GObject'
import GLib from 'gi://GLib'
import Gio from 'gi://Gio'
import St from 'gi://St'
import Clutter from 'gi://Clutter'

import * as Main from 'resource:///org/gnome/shell/ui/main.js'
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js'
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js'

const SCRIPT = GLib.build_filenamev([GLib.get_home_dir(), '.config', 'scripts', 'gsr-toggle.sh'])
const RUNDIR = GLib.get_user_runtime_dir()
const PIDFILE = `${RUNDIR}/gsr-toggle.pid`
const STARTFILE = `${RUNDIR}/gsr-toggle.start`

// Ядро обрезает comm до 15 символов, поэтому сверяем с обрезанным именем.
const COMM = 'gpu-screen-reco'

// Оранжевый индикатор портала, который GNOME показывает во время захвата экрана.
// Ищем его по классу из темы шелла, а не по приватному имени поля — так не
// зависим от внутренностей конкретной версии GNOME.
const NATIVE_CLASS = 'screen-sharing-indicator'

function readText(path) {
  try {
    const [ok, bytes] = GLib.file_get_contents(path)
    return ok ? new TextDecoder().decode(bytes).trim() : null
  } catch {
    return null
  }
}

/** PID пишущего рекордера, либо null. Мёртвый и чужой pid отбрасываются. */
function recordingPid() {
  const pid = readText(PIDFILE)
  if (!pid || !/^\d+$/.test(pid)) return null
  return readText(`/proc/${pid}/comm`) === COMM ? pid : null
}

/**
 * Родной значок стопа живёт в ресурсах шелла, а не в системной теме иконок,
 * поэтому проверяем наличие и откатываемся на адвайтовский аналог.
 */
function stopIconName() {
  try {
    if (new St.IconTheme().has_icon('screencast-stop-symbolic')) return 'screencast-stop-symbolic'
  } catch {
    // St.IconTheme может отсутствовать — тогда просто берём запасной значок.
  }
  return 'media-playback-stop-symbolic'
}

function formatElapsed(ms) {
  const total = Math.max(0, Math.floor(ms / 1000))
  const s = String(total % 60).padStart(2, '0')
  const m = Math.floor(total / 60) % 60
  const h = Math.floor(total / 3600)
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${s}` : `${m}:${s}`
}

const RecordingIndicator = GObject.registerClass(
  class RecordingIndicator extends PanelMenu.Button {
    _init() {
      // Третий аргумент — dontCreateMenu: меню не нужно, клик обрабатываем сами.
      super._init(0.5, 'GSR Recording Indicator', true)

      // Класс из темы шелла даёт ровно то же оформление, что у родного
      // индикатора записи: красная пилюля, жирный белый текст, состояния
      // hover/active, корректная светлая/тёмная/контрастная тема.
      this.add_style_class_name('screen-recording-indicator')

      // Анимация масштабируется от центра, иначе пилюля «уезжает» углом.
      this.set_pivot_point(0.5, 0.5)
      this._shown = false

      const box = new St.BoxLayout({ y_align: Clutter.ActorAlign.CENTER })
      this._label = new St.Label({
        text: '0:00',
        y_align: Clutter.ActorAlign.CENTER,
      })
      box.add_child(this._label)
      box.add_child(new St.Icon({ icon_name: stopIconName() }))
      this.add_child(box)
    }

    // Любой клик останавливает запись — как у родного индикатора GNOME.
    vfunc_event(event) {
      const type = event.type()
      if (type === Clutter.EventType.BUTTON_PRESS || type === Clutter.EventType.TOUCH_BEGIN) {
        try {
          Gio.Subprocess.new([SCRIPT], Gio.SubprocessFlags.NONE)
        } catch (e) {
          logError(e, 'gsr-timer: failed to spawn gsr-toggle')
        }
        return Clutter.EVENT_STOP
      }
      return Clutter.EVENT_PROPAGATE
    }

    setElapsed(text) {
      this._label.text = text
    }

    /** Плавное появление и исчезновение вместо резкой смены visible. */
    setShown(shown) {
      if (shown === this._shown) return
      this._shown = shown

      this.remove_all_transitions()

      if (shown) {
        this.visible = true
        this.opacity = 0
        this.scale_x = 0.8
        this.scale_y = 0.8
        this.ease({
          opacity: 255,
          scale_x: 1,
          scale_y: 1,
          duration: 250,
          mode: Clutter.AnimationMode.EASE_OUT_BACK,
        })
      } else {
        this.ease({
          opacity: 0,
          scale_x: 0.8,
          scale_y: 0.8,
          duration: 200,
          mode: Clutter.AnimationMode.EASE_OUT_QUAD,
          onComplete: () => {
            this.visible = false
          },
        })
      }
    }
  },
)

export default class GsrTimerExtension extends Extension {
  enable() {
    this._suppressed = new Map()

    this._ticks = 0
    this._indicator = new RecordingIndicator()
    this._indicator.visible = false
    Main.panel.addToStatusArea(this.uuid, this._indicator, 0, 'right')

    // 250 мс, а не секунда: при секундном опросе показанное значение
    // отставало от реального на случайную долю секунды, и на старте это
    // выглядело как подвисший на пару секунд таймер.
    this._tick()
    this._timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 250, () => {
      this._tick()
      return GLib.SOURCE_CONTINUE
    })
  }

  disable() {
    if (this._timer) {
      GLib.source_remove(this._timer)
      this._timer = null
    }
    for (const [actor, id] of this._suppressed) {
      actor.disconnect(id)
      actor.show()
    }
    this._suppressed.clear()
    this._suppressed = null

    this._indicator?.destroy()
    this._indicator = null
  }

  /**
   * Прячет родной индикатор портала. Он создаётся лениво, уже после начала
   * захвата, поэтому дерево панели переобходится на каждом тике, а на
   * найденные актёры вешается notify::visible — иначе GNOME покажет их снова.
   */
  _suppressNative() {
    const visit = (actor) => {
      const cls = actor.style_class
      if (typeof cls === 'string' && cls.includes(NATIVE_CLASS)) {
        if (!this._suppressed.has(actor)) {
          const id = actor.connect('notify::visible', () => {
            if (actor.visible) actor.hide()
          })
          this._suppressed.set(actor, id)
          actor.connect('destroy', () => this._suppressed.delete(actor))
        }
        if (actor.visible) actor.hide()
        return
      }
      for (const child of actor.get_children?.() ?? []) visit(child)
    }
    visit(Main.panel)
  }

  _tick() {
    // Обход дерева панели заметно дороже чтения пары мелких файлов,
    // поэтому раз в секунду, а не на каждом тике.
    if (this._ticks++ % 4 === 0) this._suppressNative()

    // Живого процесса мало: пока пользователь выбирает источник в диалоге
    // портала, рекордер уже запущен, но захвата ещё нет. Отметку времени
    // ставит скрипт по факту начала захвата, поэтому ждём именно её —
    // иначе индикатор появлялся бы раньше записи и врал на старте.
    const started = Number(readText(STARTFILE))
    const recording = recordingPid() !== null && Number.isFinite(started) && started > 0

    this._indicator.setShown(recording)
    if (!recording) return

    this._indicator.setElapsed(formatElapsed(Date.now() - started))
  }
}
