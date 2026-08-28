.pragma library

// Clockwise from 12 o'clock: C, G, D, A, E, B, F#, Db, Ab, Eb, Bb, F
var FIFTHS = [
  { major: "C",  minor: "Am",  accidentals: "0" },
  { major: "G",  minor: "Em",  accidentals: "1#" },
  { major: "D",  minor: "Bm",  accidentals: "2#" },
  { major: "A",  minor: "F#m", accidentals: "3#" },
  { major: "E",  minor: "C#m", accidentals: "4#" },
  { major: "B",  minor: "G#m", accidentals: "5#" },
  { major: "F#", minor: "D#m", accidentals: "6#" },
  { major: "Db", minor: "Bbm", accidentals: "5b" },
  { major: "Ab", minor: "Fm",  accidentals: "4b" },
  { major: "Eb", minor: "Cm",  accidentals: "3b" },
  { major: "Bb", minor: "Gm",  accidentals: "2b" },
  { major: "F",  minor: "Dm",  accidentals: "1b" }
]

var SECTORS = 12
var SECTOR_DEG = 360 / SECTORS
// PathAngleArc and screen-space cos/sin: 0° = 3 o'clock, clockwise.
var TOP_DEG = -90
// Pitch class of each major tonic, matching FIFTHS (C=0 … B=11).
var PITCH_CLASS = [0, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10, 5]

function wrap(index) {
  var n = FIFTHS.length
  return ((index % n) + n) % n
}

function keyAt(index) {
  return FIFTHS[wrap(index)]
}

function label(index) {
  var k = keyAt(index)
  return k.major + " / " + k.minor
}

function diatonic(index) {
  var i = wrap(index)
  return {
    I: keyAt(i).major,
    ii: keyAt(i + 11).minor,
    iii: keyAt(i + 1).minor,
    IV: keyAt(i + 11).major,
    V: keyAt(i + 1).major,
    vi: keyAt(i).minor
  }
}

function subdominantIndex(tonic) {
  return wrap(tonic + 11)
}

function dominantIndex(tonic) {
  return wrap(tonic + 1)
}

function inKeyWedge(index, tonic) {
  var i = wrap(index)
  var t = wrap(tonic)
  return i === t || i === wrap(t + 1) || i === wrap(t + 11)
}

function wedgeChords(tonic) {
  var t = wrap(tonic)
  var sub = wrap(t + 11)
  var dom = wrap(t + 1)
  return [
    { index: t, ring: "major", roman: "I" },
    { index: sub, ring: "minor", roman: "ii" },
    { index: dom, ring: "minor", roman: "iii" },
    { index: sub, ring: "major", roman: "IV" },
    { index: dom, ring: "major", roman: "V" },
    { index: t, ring: "minor", roman: "vi" }
  ]
}

function wrapCursor(cursor, length) {
  var n = length > 0 ? length : 1
  return ((cursor % n) + n) % n
}

function wedgeChordAt(tonic, cursor) {
  var list = wedgeChords(tonic)
  return list[wrapCursor(cursor, list.length)]
}

function wedgeChordByDegree(tonic, degree) {
  var list = wedgeChords(tonic)
  var n = Number(degree)
  if (!isFinite(n)) return null
  n = Math.floor(n)
  if (n < 1 || n > list.length) return null
  return list[n - 1]
}

function wedgeChordIndex(tonic, sector, ring) {
  var list = wedgeChords(tonic)
  var i = wrap(sector)
  for (var n = 0; n < list.length; n++) {
    if (list[n].index === i && list[n].ring === ring)
      return n
  }
  return -1
}

function wedgeStartDeg(tonic) {
  return sectorStartDeg(subdominantIndex(tonic))
}

function wedgeSweepDeg() {
  return SECTOR_DEG * 3
}

function sectorMidDeg(index) {
  return wrap(index) * SECTOR_DEG + TOP_DEG
}

function sectorStartDeg(index) {
  return sectorMidDeg(index) - SECTOR_DEG / 2
}

function sectorSweepDeg() {
  return SECTOR_DEG
}

function sectorEdgeDeg(index) {
  return sectorStartDeg(index)
}

function degToRad(deg) {
  return deg * Math.PI / 180
}

function polarX(cx, radius, deg) {
  return cx + radius * Math.cos(degToRad(deg))
}

function polarY(cy, radius, deg) {
  return cy + radius * Math.sin(degToRad(deg))
}

function radialSvg(cx, cy, rInner, rOuter) {
  var parts = []
  for (var i = 0; i < SECTORS; i++) {
    var deg = sectorEdgeDeg(i)
    parts.push(
      "M " + polarX(cx, rInner, deg).toFixed(2) + " " + polarY(cy, rInner, deg).toFixed(2)
      + " L " + polarX(cx, rOuter, deg).toFixed(2) + " " + polarY(cy, rOuter, deg).toFixed(2)
    )
  }
  return parts.join(" ")
}

function midiToHz(midi) {
  return 440 * Math.pow(2, (midi - 69) / 12)
}

function rootMidi(index, minor) {
  var pc = PITCH_CLASS[wrap(index)]
  if (!minor)
    return 60 + pc
  var mpc = (pc + 9) % 12
  return (mpc >= 8 ? 48 : 60) + mpc
}

function triad(index, ring) {
  var minor = ring === "minor"
  var root = rootMidi(index, minor)
  var third = root + (minor ? 3 : 4)
  var fifth = root + 7
  var key = keyAt(index)
  return {
    root: midiToHz(root),
    third: midiToHz(third),
    fifth: midiToHz(fifth),
    label: minor ? key.minor : key.major,
    minor: minor
  }
}

function hitTest(x, y, cx, cy, minorInner, minorOuter, majorInner, majorOuter) {
  var dx = x - cx
  var dy = y - cy
  var r = Math.sqrt(dx * dx + dy * dy)
  var ring = ""
  if (r >= minorInner && r <= minorOuter)
    ring = "minor"
  else if (r >= majorInner && r <= majorOuter)
    ring = "major"
  if (!ring)
    return null

  var fromTop = Math.atan2(dy, dx) * 180 / Math.PI - TOP_DEG
  fromTop = ((fromTop % 360) + 360) % 360
  return { index: Math.round(fromTop / SECTOR_DEG) % SECTORS, ring: ring }
}
