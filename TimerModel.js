// Pure timer/stopwatch math for the clock's timer section. Like Model.js it
// is Qt-free, so it can be exercised under node.
//
// State is kept as absolute epoch timestamps rather than a ticking counter:
// a countdown stores when it ends, a stopwatch stores when it (re)started plus
// what it had banked before. That is what lets the state file survive a shell
// restart — reloading it and reading the wall clock is all resuming takes.
//
//   mode             "timer" | "stopwatch"
//   running          bool
//   durationMs       the countdown's full length, for the reset target
//   endsAt           epoch ms the running countdown hits zero
//   remainingMs      a paused countdown's time left
//   startedAt        epoch ms the running stopwatch last resumed
//   accumulatedMs    stopwatch time banked across pauses

var DEFAULT_PRESETS = [1, 5, 10, 25]

function emptyState(mode) {
  return {
    mode: mode === "stopwatch" ? "stopwatch" : "timer",
    running: false,
    durationMs: 0,
    endsAt: 0,
    remainingMs: 0,
    startedAt: 0,
    accumulatedMs: 0
  }
}

// Anything read back from disk goes through here, so a hand-edited or
// truncated file degrades to an idle timer instead of NaNs on the bar.
function normalizeState(raw) {
  var state = emptyState(raw && raw.mode)
  if (!raw || typeof raw !== "object") return state
  state.running = raw.running === true
  var numbers = ["durationMs", "endsAt", "remainingMs", "startedAt", "accumulatedMs"]
  for (var i = 0; i < numbers.length; i++) {
    var value = Number(raw[numbers[i]])
    state[numbers[i]] = isFinite(value) && value > 0 ? value : 0
  }
  return state
}

function remainingMs(state, now) {
  if (state.mode !== "timer") return 0
  if (state.running) return Math.max(0, state.endsAt - now)
  return state.remainingMs
}

function elapsedMs(state, now) {
  if (state.mode !== "stopwatch") return 0
  return state.accumulatedMs + (state.running ? Math.max(0, now - state.startedAt) : 0)
}

// The number the readout shows for whichever mode is on.
function displayMs(state, now) {
  return state.mode === "timer" ? remainingMs(state, now) : elapsedMs(state, now)
}

// Something worth showing on the bar: running, or paused part-way through.
function isActive(state) {
  if (state.running) return true
  return state.mode === "timer" ? state.remainingMs > 0 : state.accumulatedMs > 0
}

function isFinished(state, now) {
  return state.mode === "timer" && state.running && now >= state.endsAt
}

// ---- Transitions. Each returns a new state rather than mutating, so the
//      QML side can assign it straight to a property and get one change
//      notification.

function startTimer(durationMs, now) {
  var state = emptyState("timer")
  state.running = true
  state.durationMs = durationMs
  state.endsAt = now + durationMs
  return state
}

function startStopwatch(now) {
  var state = emptyState("stopwatch")
  state.running = true
  state.startedAt = now
  return state
}

function pause(state, now) {
  var next = normalizeState(state)
  if (!next.running) return next
  if (next.mode === "timer") next.remainingMs = remainingMs(state, now)
  else next.accumulatedMs = elapsedMs(state, now)
  next.running = false
  next.endsAt = 0
  next.startedAt = 0
  return next
}

function resume(state, now) {
  var next = normalizeState(state)
  if (next.running) return next
  if (next.mode === "timer") {
    if (next.remainingMs <= 0) return next
    next.endsAt = now + next.remainingMs
    next.remainingMs = 0
  } else {
    next.startedAt = now
  }
  next.running = true
  return next
}

// Nudging a countdown by a minute either way, running or paused. Never
// below one second, so -1m on a short timer does not fire it on the spot.
function adjustTimer(state, deltaMs, now) {
  var next = normalizeState(state)
  if (next.mode !== "timer") return next
  var left = Math.max(1000, remainingMs(next, now) + deltaMs)
  next.durationMs = Math.max(next.durationMs, left)
  if (next.running) next.endsAt = now + left
  else next.remainingMs = left
  return next
}

// ---- Formatting

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

// m:ss under an hour, h:mm:ss past it. A countdown rounds up, so it reads
// 0:01 right until it fires rather than sitting on 0:00 for a second.
function formatDuration(ms, roundUp) {
  var total = roundUp ? Math.ceil(Math.max(0, ms) / 1000) : Math.floor(Math.max(0, ms) / 1000)
  var hours = Math.floor(total / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  var seconds = total % 60
  if (hours > 0) return hours + ":" + pad2(minutes) + ":" + pad2(seconds)
  return minutes + ":" + pad2(seconds)
}

// Stopwatch readout in the panel gets tenths; the bar does not.
function formatTenths(ms) {
  return formatDuration(ms, false) + "." + Math.floor((Math.max(0, ms) % 1000) / 100)
}

// "5 min", "1 h 30 min" — for notification text.
function describeDuration(ms) {
  var minutes = Math.round(ms / 60000)
  if (minutes < 1) return Math.round(ms / 1000) + " s"
  var hours = Math.floor(minutes / 60)
  minutes = minutes % 60
  if (hours === 0) return minutes + " min"
  return minutes === 0 ? hours + " h" : hours + " h " + minutes + " min"
}

// ---- Input

// Presets come from shell.json, possibly as a JSON string when set through
// `omarchy bar set` without --json, possibly as a comma list typed by hand.
function normalizePresets(value) {
  var list = value
  if (typeof list === "string") {
    try { list = JSON.parse(list) } catch (e) { list = list.split(",") }
  }
  if (!Array.isArray(list)) return DEFAULT_PRESETS.slice()
  var out = []
  for (var i = 0; i < list.length && out.length < 6; i++) {
    var minutes = Number(list[i])
    if (isFinite(minutes) && minutes > 0 && minutes <= 24 * 60 && out.indexOf(minutes) === -1) out.push(minutes)
  }
  return out.length > 0 ? out : DEFAULT_PRESETS.slice()
}

function presetLabel(minutes) {
  if (minutes >= 60 && minutes % 60 === 0) return (minutes / 60) + "h"
  return minutes + "m"
}

// The custom field takes "7", "7m", "1:30" (m:ss), "1h", "1h30", "90s".
// Returns milliseconds, or 0 when it cannot make sense of the text.
function parseDuration(text) {
  var s = String(text || "").trim().toLowerCase().replace(/\s+/g, "")
  if (s === "") return 0
  var ms = 0
  var m
  if ((m = /^(\d+):(\d{1,2})(?::(\d{1,2}))?$/.exec(s))) {
    ms = m[3] !== undefined
      ? ((+m[1]) * 3600 + (+m[2]) * 60 + (+m[3])) * 1000
      : ((+m[1]) * 60 + (+m[2])) * 1000
  } else if (/^(\d+(\.\d+)?[hms]?)+$/.test(s)) {
    // A number with no unit takes the one below the unit before it ("1h30"
    // is minutes, "5m30" is seconds), and on its own it is minutes ("7").
    var scale = { h: 3600, m: 60, s: 1 }
    var below = { h: "m", m: "s", s: "s", "": "m" }
    var token = /(\d+(?:\.\d+)?)([hms]?)/g
    var last = ""
    while ((m = token.exec(s))) {
      var unit = m[2] || below[last]
      ms += Number(m[1]) * scale[unit] * 1000
      last = unit
    }
  }
  if (!isFinite(ms) || ms <= 0) return 0
  return Math.min(Math.round(ms), 24 * 3600 * 1000)
}
