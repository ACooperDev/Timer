import QtQuick
import qs.Commons
import qs.Ui
import "TimerModel.js" as TimerModel

// The timer / stopwatch block under the calendar. A view only: every
// number and every action goes through `host`, the bar widget, which owns
// the state so the bar label can show it too and it survives the popup
// closing.
//
//   [ Timer | Stopwatch ]
//          12:34
//   1m  5m  10m  25m   [ custom ]
//   −1m    ▶ / ⏸    ⟲    +1m
Column {
  id: root

  property var host: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  // True while the custom-duration field has focus, so the panel's key
  // catcher can stand down and let "t" be typed instead of jumping to today.
  readonly property bool editing: customField.activeFocus

  readonly property var current: host ? host.timerState : TimerModel.emptyState("timer")
  readonly property bool isTimer: current.mode === "timer"
  readonly property bool active: host ? host.timerActive : false
  readonly property real shownMs: host ? host.timerDisplayMs : 0
  readonly property color dim: Qt.darker(foreground, 1.5)

  function releaseField() {
    customField.text = ""
    customField.focus = false
  }

  function startCustom() {
    var ms = TimerModel.parseDuration(customField.text)
    if (ms <= 0 || !host) return
    host.timerStart(ms)
    releaseField()
  }

  spacing: Style.space(10)

  // ---- Mode. Locked while something is running or paused, so a stray
  //      click cannot throw away a countdown in progress.
  Item {
    width: parent.width
    height: modeGroup.implicitHeight

    ButtonGroup {
      id: modeGroup
      anchors.horizontalCenter: parent.horizontalCenter
      focusable: false
      enabled: !root.active
      opacity: enabled ? 1 : 0.45
      options: [
        { value: "timer", label: "Timer", icon: "󰔛" },
        { value: "stopwatch", label: "Stopwatch", icon: "󱎫" }
      ]
      value: root.current.mode
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      onChanged: function(v) { if (root.host) root.host.timerSetMode(v) }
    }
  }

  // ---- Readout. Tabular figures so the digits hold still while counting.
  Text {
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    textFormat: Text.PlainText
    text: root.isTimer
      ? TimerModel.formatDuration(root.active ? root.shownMs : root.current.durationMs, true)
      : TimerModel.formatTenths(root.shownMs)
    color: root.active || root.current.durationMs > 0 ? root.foreground : root.dim
    opacity: root.active && !root.current.running ? 0.6 : 1
    font.family: root.fontFamily
    font.pixelSize: 40
    font.bold: true
    font.features: { "tnum": 1 }
  }

  // ---- Presets and a free-form duration (timer only).
  Item {
    visible: root.isTimer
    width: parent.width
    height: visible ? presetRow.implicitHeight : 0

    Row {
      id: presetRow
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(6)

      Repeater {
        model: root.host ? root.host.timerPresets : []

        Button {
          required property var modelData
          anchors.verticalCenter: parent.verticalCenter
          text: TimerModel.presetLabel(modelData)
          tooltipText: "Start a " + TimerModel.describeDuration(modelData * 60000) + " timer"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: if (root.host) root.host.timerStart(modelData * 60000)
        }
      }

      TextField {
        id: customField
        width: Style.space(84)
        anchors.verticalCenter: parent.verticalCenter
        placeholderText: "7m, 1:30"
        foreground: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.startCustom()
            event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            root.releaseField()
            event.accepted = true
          }
        }
      }
    }
  }

  // ---- Transport.
  Item {
    width: parent.width
    height: transportRow.implicitHeight

    Row {
      id: transportRow
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(14)

      PanelActionButton {
        visible: root.isTimer
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰍴"
        tooltipText: "One minute less"
        enabled: root.active
        opacity: enabled ? 1 : 0.35
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.host.timerAdjust(-60000)
      }

      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: root.current.running ? "󰏤" : "󰐊"
        tooltipText: root.current.running ? "Pause (s)"
          : root.active ? "Resume (s)"
          : root.isTimer ? (root.current.durationMs > 0 ? "Start again (s)" : "Pick a time first")
          : "Start (s)"
        enabled: root.current.running || root.active || !root.isTimer || root.current.durationMs > 0
        opacity: enabled ? 1 : 0.35
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.host.timerToggle()
      }

      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰑓"
        tooltipText: "Reset (r)"
        enabled: root.active
        opacity: enabled ? 1 : 0.35
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.host.timerReset()
      }

      PanelActionButton {
        visible: root.isTimer
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰐕"
        tooltipText: "One minute more"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.host.timerAdjust(60000)
      }
    }
  }
}
