import QtQuick
import QtQuick.Shapes
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.markschellhas.circle-of-fifths"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property int tonicIndex: 0
  property bool earcons: false
  property bool toneMode: false
  property int toneCursor: 0
  property int soundingIndex: -1
  property string soundingRing: ""
  property int lastDegree: 0
  property double lastDegreeAt: 0

  readonly property var selected: Model.keyAt(tonicIndex)
  readonly property string tonicMajor: {
    var k = Model.keyAt(tonicIndex)
    return (k && k.major) ? k.major : "C"
  }
  readonly property var chords: Model.diatonic(tonicIndex)
  readonly property color onSelected: Color.popups.background
  readonly property color gridColor: Util.alpha(root.barForeground, 0.35)
  readonly property color hoverFill: Util.alpha(root.barForeground, 0.16)
  readonly property color soundingFill: Util.alpha(root.barForeground, 0.28)
  readonly property color wedgeFill: Util.alpha(root.barForeground, 0.10)
  readonly property int wedgeStroke: Math.max(3, Style.space(3))
  readonly property int cellStroke: Math.max(2, Style.space(2))
  readonly property string playScript: decodeURIComponent(
    Qt.resolvedUrl("play-triad.py").toString().replace(/^file:\/\//, ""))

  function open() {
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened)
      root.close()
    else
      root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function step(delta) {
    if (root.toneMode)
      root.stepTone(delta)
    else
      tonicIndex = Model.wrap(tonicIndex + delta)
  }

  function stepTone(delta) {
    var list = Model.wedgeChords(root.tonicIndex)
    root.toneCursor = Model.wrapCursor(root.toneCursor + delta, list.length)
    var chord = list[root.toneCursor]
    root.playTriad(chord.index, chord.ring)
  }

  function playWedgeDegree(degree) {
    var list = Model.wedgeChords(root.tonicIndex)
    if (degree < 1 || degree > list.length)
      return
    var now = Date.now()
    if (degree === root.lastDegree && now - root.lastDegreeAt < 80)
      return
    root.lastDegree = degree
    root.lastDegreeAt = now
    var chord = list[degree - 1]
    root.toneCursor = degree - 1
    root.playTriad(chord.index, chord.ring)
  }

  function degreeFromKey(event) {
    if (event.key >= Qt.Key_1 && event.key <= Qt.Key_6)
      return event.key - Qt.Key_1 + 1
    var t = event.text ? String(event.text) : ""
    if (t.length === 1 && t >= "1" && t <= "6")
      return parseInt(t, 10)
    var scan = Number(event.nativeScanCode)
    if (scan >= 2 && scan <= 7)
      return scan - 1
    if (scan >= 10 && scan <= 15)
      return scan - 9
    return 0
  }

  function isToneCursor(index, ringName) {
    if (!root.toneMode)
      return false
    var chord = Model.wedgeChordAt(root.tonicIndex, root.toneCursor)
    return chord && index === chord.index && ringName === chord.ring
  }

  function cellFill(index, ringName) {
    if (root.toneMode) {
      if (root.isToneCursor(index, ringName))
        return root.barForeground
    } else if (index === root.tonicIndex) {
      return root.barForeground
    }
    if (index === root.soundingIndex && root.soundingRing === ringName)
      return root.soundingFill
    if (index === ring.hoverIndex && ring.hoverRing === ringName)
      return root.hoverFill
    if (Model.inKeyWedge(index, root.tonicIndex))
      return root.wedgeFill
    return "transparent"
  }

  function playTriad(index, ringName) {
    var t = Model.triad(index, ringName)
    root.soundingIndex = index
    root.soundingRing = ringName
    soundingTimer.restart()
    Quickshell.execDetached([
      "python3", root.playScript,
      String(t.root), String(t.third), String(t.fifth)
    ])
  }

  function onChordClicked(index, ringName) {
    if (!root.toneMode) {
      root.tonicIndex = index
      return
    }
    var cursor = Model.wedgeChordIndex(root.tonicIndex, index, ringName)
    if (cursor >= 0)
      root.toneCursor = cursor
    root.playTriad(index, ringName)
  }

  onToneModeChanged: {
    if (root.toneMode) {
      root.toneCursor = 0
      if (keyCatcher)
        keyCatcher.forceActiveFocus()
    } else {
      root.soundingIndex = -1
      root.soundingRing = ""
    }
  }

  Timer {
    id: soundingTimer
    interval: 750
    onTriggered: {
      root.soundingIndex = -1
      root.soundingRing = ""
    }
  }

  component AnnularWedge: Shape {
    id: wedge
    property real cx
    property real cy
    property real rInner
    property real rOuter
    property real startDeg
    property real sweepDeg
    property color fill: "transparent"
    property color stroke: "transparent"
    property real strokeWidth: 0

    antialiasing: true
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: wedge.fill
      strokeColor: wedge.strokeWidth > 0 ? wedge.stroke : "transparent"
      strokeWidth: wedge.strokeWidth
      fillRule: ShapePath.WindingFill
      capStyle: ShapePath.FlatCap
      joinStyle: ShapePath.MiterJoin
      startX: Model.polarX(wedge.cx, wedge.rOuter, wedge.startDeg)
      startY: Model.polarY(wedge.cy, wedge.rOuter, wedge.startDeg)

      PathAngleArc {
        centerX: wedge.cx
        centerY: wedge.cy
        radiusX: wedge.rOuter
        radiusY: wedge.rOuter
        startAngle: wedge.startDeg
        sweepAngle: wedge.sweepDeg
        moveToStart: false
      }
      PathAngleArc {
        centerX: wedge.cx
        centerY: wedge.cy
        radiusX: wedge.rInner
        radiusY: wedge.rInner
        startAngle: wedge.startDeg + wedge.sweepDeg
        sweepAngle: -wedge.sweepDeg
        moveToStart: false
      }
      PathLine {
        x: Model.polarX(wedge.cx, wedge.rOuter, wedge.startDeg)
        y: Model.polarY(wedge.cy, wedge.rOuter, wedge.startDeg)
      }
    }
  }

  component RingOutline: Rectangle {
    property real ringRadius
    width: ringRadius * 2
    height: ringRadius * 2
    radius: ringRadius
    color: "transparent"
    border.width: 1
    border.color: root.gridColor
    anchors.centerIn: parent
    antialiasing: true
  }

  component KeyLabel: Text {
    id: keyLabel
    property int sector
    property real labelRadius
    property bool majorRing
    readonly property string ringName: majorRing ? "major" : "minor"
    readonly property bool active: root.toneMode
      ? root.isToneCursor(sector, ringName)
      : sector === root.tonicIndex
    readonly property bool inWedge: Model.inKeyWedge(sector, root.tonicIndex)
    readonly property bool hovered: sector === ring.hoverIndex && ring.hoverRing === ringName
    readonly property bool sounding: sector === root.soundingIndex && root.soundingRing === ringName

    x: Model.polarX(ring.cx, labelRadius, Model.sectorMidDeg(sector)) - width / 2
    y: Model.polarY(ring.cy, labelRadius, Model.sectorMidDeg(sector)) - height / 2
    text: majorRing ? Model.keyAt(sector).major : Model.keyAt(sector).minor
    color: active ? root.onSelected : root.barForeground
    opacity: active || hovered || sounding || inWedge ? 1 : 0.55
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: majorRing ? Style.font.body : Style.font.caption
    font.bold: active
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      Keys.forwardTo: [digitCatcher]
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        var delta = dx !== 0 ? dx : dy
        if (delta !== 0)
          root.step(delta)
      }
      onTextKey: function(t) {
        if (t === "t" || t === "T") {
          root.toneMode = !root.toneMode
          return
        }
        if (root.toneMode && t >= "1" && t <= "6")
          root.playWedgeDegree(parseInt(t, 10))
      }

      Item {
        id: digitCatcher
        Keys.onPressed: function(event) {
          if (!root.toneMode)
            return
          var degree = root.degreeFromKey(event)
          if (degree <= 0)
            return
          root.playWedgeDegree(degree)
          event.accepted = true
        }
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        Text {
          width: parent.width
          text: selected.major + " major  ·  " + selected.minor + " minor"
          color: root.barForeground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          width: parent.width
          text: selected.accidentals === "0" ? "no sharps or flats" : selected.accidentals
          color: root.barForeground
          opacity: 0.7
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
        }

        Item {
          id: ring
          width: parent.width
          height: Math.min(width, Style.space(268))

          property int hoverIndex: -1
          property string hoverRing: ""

          readonly property real cx: width / 2
          readonly property real cy: height / 2
          readonly property real outerR: Math.min(width, height) / 2 - Style.space(6)
          readonly property real majorOuterR: outerR
          readonly property real majorInnerR: outerR * 0.64
          readonly property real minorOuterR: outerR * 0.60
          readonly property real minorInnerR: outerR * 0.32
          readonly property real splitR: (majorInnerR + minorOuterR) / 2
          readonly property real majorLabelR: (majorOuterR + majorInnerR) / 2
          readonly property real minorLabelR: (minorOuterR + minorInnerR) / 2

          function pick(px, py) {
            return Model.hitTest(px, py, cx, cy, minorInnerR, minorOuterR, majorInnerR, majorOuterR)
          }

          function setHover(px, py) {
            var hit = pick(px, py)
            if (hit) {
              hoverIndex = hit.index
              hoverRing = hit.ring
            } else {
              hoverIndex = -1
              hoverRing = ""
            }
          }

          Repeater {
            model: 12
            delegate: AnnularWedge {
              required property int index
              readonly property bool inWedge: Model.inKeyWedge(index, root.tonicIndex)
              anchors.fill: parent
              cx: ring.cx
              cy: ring.cy
              rInner: ring.majorInnerR
              rOuter: ring.majorOuterR
              startDeg: Model.sectorStartDeg(index)
              sweepDeg: Model.sectorSweepDeg()
              fill: root.cellFill(index, "major")
              stroke: inWedge ? root.barForeground : "transparent"
              strokeWidth: inWedge ? root.cellStroke : 0
            }
          }

          Repeater {
            model: 12
            delegate: AnnularWedge {
              required property int index
              readonly property bool inWedge: Model.inKeyWedge(index, root.tonicIndex)
              anchors.fill: parent
              cx: ring.cx
              cy: ring.cy
              rInner: ring.minorInnerR
              rOuter: ring.minorOuterR
              startDeg: Model.sectorStartDeg(index)
              sweepDeg: Model.sectorSweepDeg()
              fill: root.cellFill(index, "minor")
              stroke: inWedge ? root.barForeground : "transparent"
              strokeWidth: inWedge ? root.cellStroke : 0
            }
          }

          RingOutline { ringRadius: ring.majorOuterR }
          RingOutline { ringRadius: ring.splitR }
          RingOutline { ringRadius: ring.minorInnerR }

          Shape {
            anchors.fill: parent
            antialiasing: true
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
              fillColor: "transparent"
              strokeColor: root.gridColor
              strokeWidth: 1
              capStyle: ShapePath.FlatCap
              PathSvg { path: Model.radialSvg(ring.cx, ring.cy, ring.minorInnerR, ring.majorOuterR) }
            }
          }

          AnnularWedge {
            z: 4
            anchors.fill: parent
            cx: ring.cx
            cy: ring.cy
            rInner: ring.minorInnerR
            rOuter: ring.majorOuterR
            startDeg: Model.wedgeStartDeg(root.tonicIndex)
            sweepDeg: Model.wedgeSweepDeg()
            fill: "transparent"
            stroke: root.barForeground
            strokeWidth: root.wedgeStroke
          }

          Repeater {
            model: 12
            delegate: KeyLabel {
              required property int index
              sector: index
              labelRadius: ring.majorLabelR
              majorRing: true
            }
          }

          Repeater {
            model: 12
            delegate: KeyLabel {
              required property int index
              sector: index
              labelRadius: ring.minorLabelR
              majorRing: false
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: ring.hoverIndex >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
            onPositionChanged: function(mouse) { ring.setHover(mouse.x, mouse.y) }
            onExited: {
              ring.hoverIndex = -1
              ring.hoverRing = ""
            }
            onClicked: function(mouse) {
              var hit = ring.pick(mouse.x, mouse.y)
              if (hit)
                root.onChordClicked(hit.index, hit.ring)
            }
          }
        }

        Text {
          width: parent.width
          text: "I " + chords.I
                + "   IV " + chords.IV
                + "   V " + chords.V
                + "   vi " + chords.vi
          color: root.barForeground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(8)

          Button {
            id: toneButton
            text: root.toneMode ? "Tone on" : "Tone"
            selected: root.toneMode
            bordered: true
            foreground: root.barForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            fontSize: Style.font.bodySmall
            tooltipText: root.toneMode
              ? "Clicks and arrows play chords in the key wedge"
              : "Play clicked triads"
            onClicked: {
              root.toneMode = !root.toneMode
              keyCatcher.forceActiveFocus()
            }
          }

          Button {
            text: root.earcons ? ("PC in " + root.tonicMajor) : "Tune PC"
            selected: root.earcons
            bordered: true
            foreground: root.barForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            fontSize: Style.font.bodySmall
            tooltipText: root.earcons
              ? "This PC is tuned to " + root.tonicMajor + ". Click to restore silent notifications."
              : "Tune this PC so notifications sound in the selected key"
            onClicked: {
              root.earcons = !root.earcons
              keyCatcher.forceActiveFocus()
            }
          }
        }

        Text {
          width: parent.width
          text: root.toneMode
                ? "1–6 chords   ← → cycle   T toggle   Esc close"
                : "← → change key   T tone   Esc close"
          color: root.barForeground
          opacity: 0.55
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption ? Style.font.caption : Style.font.body
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }
}
