import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.markschellhas.circle-of-fifths"

  property int tonicIndex: 0
  property bool earcons: false
  property bool applyingSettings: false
  property bool ready: false
  property real longestLabelWidth: 0
  property int panelRev: 0

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false
  readonly property string playScript: decodeURIComponent(
    Qt.resolvedUrl("play-triad.py").toString().replace(/^file:\/\//, ""))
  readonly property string popupDir: Quickshell.env("HOME") + "/.local/state/omarchy/notifications"
  readonly property real forkSize: Math.max(6, Math.round(button.fontSize * 0.47))
  readonly property real forkGap: Math.max(4, Math.round(button.fontSize * 0.36))
  readonly property real chipWidth: Math.ceil(
    longestLabelWidth + forkSize + forkGap + button.scaledHorizontalMargin * 2
  )

  function reloadPanel() {
    var wasOpen = root.opened
    panelLoader.active = false
    root.panelRev += 1
    Qt.callLater(function() {
      panelLoader.active = true
      if (wasOpen)
        Qt.callLater(root.open)
    })
  }

  function refreshLongestLabel() {
    var max = 0
    for (var i = 0; i < 12; i++) {
      labelMetrics.text = Model.label(i)
      if (labelMetrics.width > max)
        max = labelMetrics.width
    }
    longestLabelWidth = max
  }

  function open() {
    if (panelLoader.item)
      panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item)
      panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item)
      panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item)
      panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    if (!panelLoader.item)
      return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
    panelLoader.item.tonicIndex = root.tonicIndex
    panelLoader.item.earcons = root.earcons
  }

  function hydrateFromSettings() {
    root.applyingSettings = true
    var n = Number(setting("tonicIndex", root.tonicIndex))
    if (isFinite(n))
      root.tonicIndex = Model.wrap(n)
    root.earcons = setting("earcons", false) === true
    root.applyingSettings = false
  }

  function persistSoon() {
    if (!root.ready || root.applyingSettings)
      return
    persistTimer.restart()
  }

  function persistNow() {
    if (!root.ready || root.applyingSettings)
      return
    var entry = { id: root.moduleName }
    for (var key in root.settings)
      if (key !== "id")
        entry[key] = root.settings[key]
    entry.tonicIndex = root.tonicIndex
    entry.earcons = root.earcons
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function handlePopupFile(name) {
    name = String(name || "").replace(/^\s+|\s+$/g, "")
    if (name.length < 6 || name.indexOf(".json") !== name.length - 5)
      return
    if (name.indexOf("/") !== -1 || name.indexOf("..") !== -1)
      return
    Quickshell.execDetached([
      "python3", root.playScript, "--earcon",
      String(root.tonicIndex),
      root.popupDir + "/" + name
    ])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    root.hydrateFromSettings()
    root.refreshLongestLabel()
    root.ready = true
  }

  onBarChanged: {
    root.refreshLongestLabel()
    root.injectPanel()
  }
  onSettingsChanged: {
    if (root.ready)
      root.hydrateFromSettings()
  }
  onTonicIndexChanged: {
    if (panelLoader.item)
      panelLoader.item.tonicIndex = root.tonicIndex
    root.persistSoon()
  }
  onEarconsChanged: {
    if (panelLoader.item)
      panelLoader.item.earcons = root.earcons
    root.persistSoon()
  }

  Timer {
    id: persistTimer
    interval: 250
    onTriggered: root.persistNow()
  }

  Process {
    id: popupWatch
    running: root.earcons
    command: [
      "bash", "-c",
      "mkdir -p \"$1\" && exec inotifywait -m -q -e close_write --format '%f' \"$1\"",
      "--", root.popupDir
    ]
    stdout: SplitParser {
      onRead: function(line) { root.handlePopupFile(line) }
    }
    onExited: {
      if (root.earcons)
        restartWatch.restart()
    }
  }

  Timer {
    id: restartWatch
    interval: 800
    onTriggered: {
      if (root.earcons && !popupWatch.running)
        popupWatch.running = true
    }
  }

  FileView {
    path: decodeURIComponent(Qt.resolvedUrl("Panel.qml").toString().replace(/^file:\/\//, ""))
    watchChanges: true
    printErrors: false
    onFileChanged: root.reloadPanel()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml") + "?rev=" + root.panelRev
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
      if (panelLoader.item) {
        panelLoader.item.tonicIndexChanged.connect(function() {
          root.tonicIndex = panelLoader.item.tonicIndex
        })
        panelLoader.item.earconsChanged.connect(function() {
          root.earcons = panelLoader.item.earcons
        })
      }
    }
  }

  TextMetrics {
    id: labelMetrics
    font.family: button.fontFamily
    font.pixelSize: button.fontSize
  }

  Connections {
    target: button
    function onFontFamilyChanged() { root.refreshLongestLabel() }
    function onFontSizeChanged() { root.refreshLongestLabel() }
  }

  component TuningFork: Item {
    id: fork
    property color color: button.foreground

    Shape {
      anchors.fill: parent
      antialiasing: true
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeColor: fork.color
        fillColor: "transparent"
        strokeWidth: Math.max(1.25, fork.width * 0.18)
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: fork.width * 0.18
        startY: fork.height * 0.06
        PathLine { x: fork.width * 0.18; y: fork.height * 0.40 }
        PathLine { x: fork.width * 0.82; y: fork.height * 0.40 }
        PathLine { x: fork.width * 0.82; y: fork.height * 0.06 }
      }

      ShapePath {
        strokeColor: fork.color
        fillColor: "transparent"
        strokeWidth: Math.max(1.25, fork.width * 0.18)
        capStyle: ShapePath.RoundCap
        startX: fork.width * 0.50
        startY: fork.height * 0.40
        PathLine { x: fork.width * 0.50; y: fork.height * 0.94 }
      }
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    z: 1
    bar: root.bar
    text: Model.label(root.tonicIndex)
    labelVisible: false
    keepSpace: true
    fixedWidth: root.vertical ? -1 : root.chipWidth
    tooltipText: root.earcons
      ? "Circle of fifths · tuned to " + Model.keyAt(root.tonicIndex).major
      : "Circle of fifths"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton)
        root.toggle()
    }
  }

  Row {
    anchors.centerIn: parent
    spacing: root.forkGap
    z: 0

    Item {
      visible: root.earcons
      width: visible ? root.forkSize : 0
      height: chipLabel.height

      TuningFork {
        width: root.forkSize
        height: Math.round(button.fontSize * 0.70)
        anchors.centerIn: parent
      }
    }

    Text {
      id: chipLabel
      text: Model.label(root.tonicIndex)
      color: button.foreground
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      renderType: Text.NativeRendering
    }
  }
}
