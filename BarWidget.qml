import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "TimerModel.js" as TimerModel

// Date/time label for the bar, and the host for the calendar popup — and,
// in this clone, for a countdown timer / stopwatch that lives under the
// calendar. The timer state is owned here rather than by the panel because
// the bar label reads it too, and the panel is only a view onto it.
//
// Left click reveals the calendar — asking "what is the date?" is what a
// click on a clock means — right click walks the common label formats, and
// middle click opens the timezone picker.
BarWidget {
  id: root
  moduleName: "omarchy.clock"

  property date displayDate: clock.date

  readonly property string configuredFormat: vertical
    ? setting("verticalFormat", "HH\n—\nmm")
    : setting("format", "dddd HH:mm")
  readonly property string configuredAltFormat: vertical
    ? setting("verticalFormatAlt", "dd\nMMM\n'W'ww\n''yy")
    : setting("formatAlt", "d MMMM 'W'ww yyyy")

  readonly property var formatRing: Model.clockFormatRing(configuredFormat, configuredAltFormat, Model.clockFormats(vertical))

  // What the bar shows is what shell.json stores, so a cycled format is the
  // format from then on rather than something that reverts on restart.
  readonly property string activeFormat: configuredFormat
  readonly property string displayText: formatted(displayDate)
  readonly property var verticalLines: timerOnBar
    ? displayText.split("\n").concat([timerIcon, timerBarText])
    : displayText.split("\n")

  // ---- Timer / stopwatch. See TimerModel.js for the state shape; `now` is
  //      bumped by the ticker while something runs, and everything the UI
  //      shows is derived from the pair.
  property var timerState: TimerModel.emptyState("timer")
  property real now: Date.now()
  property bool timerLoaded: false

  readonly property var timerPresets: TimerModel.normalizePresets(setting("timerPresets", TimerModel.DEFAULT_PRESETS))
  readonly property string timerSound: String(setting("timerSound", "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga"))
  readonly property bool timerActive: TimerModel.isActive(timerState)
  readonly property bool timerOnBar: timerActive && ["off", "false", "0"].indexOf(String(setting("showOnBar", "On")).toLowerCase()) === -1
  readonly property real timerDisplayMs: TimerModel.displayMs(timerState, now)
  readonly property string timerIcon: timerState.mode === "timer" ? "󰔛" : "󱎫"
  readonly property string timerBarText: TimerModel.formatDuration(timerDisplayMs, timerState.mode === "timer")
    + (timerState.running ? "" : " ⏸")
  readonly property string barText: timerOnBar
    ? displayText + "   " + timerIcon + " " + timerBarText
    : displayText

  readonly property string timerStatePath: Quickshell.env("HOME") + "/.local/state/omarchy/clock-timer.json"

  function setTimerState(next) {
    root.now = Date.now()
    root.timerState = next
    timerFile.setText(JSON.stringify(next))
  }

  function timerStart(durationMs) {
    if (durationMs > 0) setTimerState(TimerModel.startTimer(durationMs, Date.now()))
  }

  // Start/pause/resume on whatever the current mode is. An idle countdown
  // restarts the last duration it ran, so "again" is one click.
  function timerToggle() {
    var s = root.timerState
    var t = Date.now()
    if (s.running) setTimerState(TimerModel.pause(s, t))
    else if (TimerModel.isActive(s)) setTimerState(TimerModel.resume(s, t))
    else if (s.mode === "stopwatch") setTimerState(TimerModel.startStopwatch(t))
    else if (s.durationMs > 0) timerStart(s.durationMs)
  }

  function timerReset() {
    var idle = TimerModel.emptyState(root.timerState.mode)
    idle.durationMs = root.timerState.durationMs
    setTimerState(idle)
  }

  function timerAdjust(deltaMs) {
    var s = root.timerState
    if (s.mode === "timer" && !TimerModel.isActive(s)) {
      // Nothing loaded yet: +1m on an idle timer sets one up, paused.
      if (deltaMs <= 0) return
      var idle = TimerModel.emptyState("timer")
      idle.durationMs = deltaMs
      idle.remainingMs = deltaMs
      setTimerState(idle)
      return
    }
    setTimerState(TimerModel.adjustTimer(s, deltaMs, Date.now()))
  }

  // Switching modes drops whatever the other mode was doing; the toggle
  // only shows when nothing is running, so that is never a surprise.
  function timerSetMode(mode) {
    if (root.timerState.mode === mode) return
    var idle = TimerModel.emptyState(mode)
    if (mode === "timer") idle.durationMs = root.timerState.durationMs
    setTimerState(idle)
  }

  function timerFinished(lateMs) {
    var s = root.timerState
    var body = TimerModel.describeDuration(s.durationMs) + " timer is up"
    if (lateMs > 5000) body += " (finished while the shell was restarting)"
    // argv, not a command string: the sound path comes from shell.json.
    Quickshell.execDetached(["bash", "-lc",
      'omarchy-notification-send -g 󰔛 -u critical "Timer" "$1"; [ -n "$2" ] && [ -f "$2" ] && exec pw-play "$2"',
      "bash", body, lateMs > 5000 ? "" : root.timerSound])
    var idle = TimerModel.emptyState("timer")
    idle.durationMs = s.durationMs
    setTimerState(idle)
  }

  function timerTick() {
    root.now = Date.now()
    if (TimerModel.isFinished(root.timerState, root.now))
      timerFinished(root.now - root.timerState.endsAt)
  }

  function refresh() {
    displayDate = new Date()
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function cycleFormat() {
    var current = String(configuredFormat)
    var next = Model.nextClockFormat(formatRing, current)
    if (next === "" || next === current) return

    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry[vertical ? "verticalFormat" : "format"] = next

    // Applied locally first so the label changes on the click itself; the
    // shell.json write comes back through the bar as the same value.
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function formatted(date) {
    return Qt.formatDateTime(date, activeFormat.replace(/ww/g, Model.isoWeekLiteral(date.getFullYear(), date.getMonth(), date.getDate())))
  }

  // ---- Calendar popup. Shape contract for shell.summon/hide/toggle
  //      routing: Bar.findPanelWidget requires open/close/opened on the
  //      bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function toggleWeekStart() {
    if (panelLoader.item) panelLoader.item.toggleWeekStart()
  }

  // The clock fills more slot than it paints a mark for, at both
  // orientations: horizontally it is a text label in a padded slot, so the
  // dot takes the label width; vertically it is a stack of icon-sized lines,
  // so the dot takes one line — the same mark every icon widget gets, rather
  // than a rule running the height of the whole stack.
  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  FileView {
    id: timerFile
    path: root.timerStatePath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      if (root.timerLoaded) return
      var parsed = null
      try { parsed = JSON.parse(timerFile.text()) } catch (e) {}
      var s = TimerModel.normalizeState(parsed)
      // A running countdown without an end, or a stopwatch without a start,
      // is a damaged file rather than something to resume.
      if (s.running && ((s.mode === "timer" && s.endsAt <= 0) || (s.mode === "stopwatch" && s.startedAt <= 0)))
        s = TimerModel.emptyState(s.mode)
      root.timerState = s
      root.timerLoaded = true
      root.timerTick()
    }
    // No file yet is the normal first run.
    onLoadFailed: root.timerLoaded = true
  }

  Timer {
    id: ticker
    interval: 250
    repeat: true
    running: root.timerState.running
    triggeredOnStart: true
    onTriggered: root.timerTick()
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: root.displayDate = date
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "omarchy.clock"

    function refresh(): void { root.broadcast("refresh") }
    function cycleFormat(): void { root.cycleFormat() }
    function toggleWeekStart(): void { root.toggleWeekStart() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function timerToggle(): void { root.timerToggle() }
    function timerReset(): void { root.timerReset() }
    function timerStart(minutes: real): void { root.timerStart(minutes * 60000) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.barText
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.verticalLines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.verticalLines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleFormat()
      else if (b === Qt.MiddleButton) { if (root.bar) root.bar.run("omarchy-menu-timezone") }
      else root.togglePanel()
    }

    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 3
            ? button.fontSize * 0.9
            : button.fontSize
          color: button.foreground
        }
      }
    }
  }
}
