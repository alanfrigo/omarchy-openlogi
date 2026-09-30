pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import "Model.js" as Model

Item {
  id: root
  property var shell: null
  property var service: null
  property bool opened: false
  property string activeSession: ""
  property string pendingId: ""
  property string pendingSlot: ""
  property string previousAddress: ""
  property var ringScreen: null
  property var ringMonitor: null
  property int workspaceId: 0
  property real ringX: 0
  property real ringY: 0
  property real ringScale: 1
  property string hoveredSlot: ""
  property int focusIndex: 0
  property var cursorResult: null
  property var focusResult: null
  property bool restoreStarted: false
  property bool verifyStarted: false
  readonly property var slots: service && service.invocation && service.invocation.sessionId === activeSession
    ? service.invocation.slots : []

  function pendingValid(id) {
    return !!id && id === pendingId && !!service
      && service.pendingId === id && service.pendingSlot === pendingSlot

  }


  function screenAvailable() {
    if (!ringScreen) return false
    for (var i = 0; i < Quickshell.screens.length; i++) {
      if (Quickshell.screens[i] === ringScreen && ringScreen.width > 0 && ringScreen.height > 0)
        return true
    }
    return false
  }

  function workspaceAvailable() {
    return screenAvailable() && !!ringMonitor && !!ringMonitor.activeWorkspace
      && ringMonitor.activeWorkspace.id === workspaceId
  }

  function reset() {
    opened = false
    activeSession = ""
    pendingId = ""
    pendingSlot = ""
    previousAddress = ""
    ringScreen = null
    ringMonitor = null
    cursorResult = null
    focusResult = null
    hoveredSlot = ""
    focusIndex = 0
    restoreStarted = false
    verifyStarted = false
  }

  function failPresentation(id, message) {
    if (id !== activeSession || !id || pendingId) return
    reset()
    if (service) service.failPresentation(id, message)
  }

  function failActivation(id, message) {
    if (!pendingValid(id)) return
    reset()
    service.failActivation(id, message)
  }

  function open(payload) {
    // Payload is deliberately ignored: only the live service owns ring sessions.
    var invocation = service && service.invocation
    if (!invocation || !invocation.sessionId || !Array.isArray(invocation.slots)) return
    var id = invocation.sessionId
    if (id === activeSession || id === pendingId) return
    reset()
    activeSession = id
    startCursor(id)
    startInitialFocus(id)
  }

  function close() {
    var id = activeSession
    var wasInteractive = !!id && !pendingId
    var wasPending = pendingValid(pendingId)
    var pending = pendingId
    reset()
    if (wasPending) service.failActivation(pending, "OpenLogi: overlay closed before focus restoration")
    else if (wasInteractive && service) service.cancel(id)
  }

  function cancel() {
    if (!activeSession || pendingId) return
    var id = activeSession
    reset()
    if (service) service.cancel(id) // Service hides via shell after clearing its invocation.
  }

  function startCursor(id) {
    if (cursorProc.running) { cursorProc.queued = id; return }
    cursorProc.session = id
    cursorProc.collected = ""
    cursorProc.running = true
  }

  function startInitialFocus(id) {
    if (initialFocusProc.running) { initialFocusProc.queued = id; return }
    initialFocusProc.session = id
    initialFocusProc.collected = ""
    initialFocusProc.running = true
  }

  function cursorFinished(id, exitCode, text) {
    if (id !== activeSession || pendingId) return
    try {
      if (exitCode !== 0) throw new Error("hyprctl cursorpos failed")
      var point = JSON.parse(text)
      if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y))
        throw new Error("Invalid cursor position")
      cursorResult = point
      tryPresent(id)
    } catch (e) { failPresentation(id, "OpenLogi: cursor unavailable: " + e.message) }
  }

  function initialFocusFinished(id, exitCode, text) {
    if (id !== activeSession || pendingId) return
    try {
      if (exitCode !== 0) throw new Error("hyprctl activewindow failed")
      var window = JSON.parse(text)
      if (!window || typeof window !== "object" || Array.isArray(window))
        throw new Error("Invalid active window")
      var address = window.address || ""
      if (address && !/^0x[0-9a-fA-F]+$/.test(address))
        throw new Error("Invalid active window address")
      focusResult = address
      tryPresent(id)
    } catch (e) { failPresentation(id, "OpenLogi: active window unavailable: " + e.message) }
  }

  function tryPresent(id) {
    if (id !== activeSession || !cursorResult || focusResult === null || pendingId) return
    var point = cursorResult
    var target = null
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (point.x >= screen.x && point.x < screen.x + screen.width
          && point.y >= screen.y && point.y < screen.y + screen.height) {
        target = screen
        break
      }
    }
    if (!target) { failPresentation(id, "OpenLogi: cursor is outside available monitors"); return }
    var monitor = Hyprland.monitorFor(target)
    if (!monitor || !monitor.activeWorkspace) {
      failPresentation(id, "OpenLogi: monitor workspace unavailable")
      return
    }
    var position
    try { position = Model.placeRing(target, point, 360) }
    catch (e) { failPresentation(id, "OpenLogi: invalid ring placement: " + e.message); return }
    if (!position || !Number.isFinite(position.x) || !Number.isFinite(position.y)
        || !Number.isFinite(position.scale) || position.scale <= 0) {
      failPresentation(id, "OpenLogi: invalid ring placement")
      return
    }
    ringScreen = target
    ringMonitor = monitor
    workspaceId = monitor.activeWorkspace.id
    previousAddress = focusResult
    ringX = position.x
    ringY = position.y
    ringScale = position.scale
    focusIndex = 0
    hoveredSlot = ""
    opened = true
  }

  function hover(slot) {
    if (!opened || hoveredSlot === slot || !service || !service.invocation
        || service.invocation.sessionId !== activeSession || pendingId) return
    hoveredSlot = slot
    service.hover(activeSession, slot)
  }

  function activate(slot) {
    if (!opened || !service || pendingId || !Model.canInteract(activeSession,
        service.invocation && service.invocation.sessionId, slots, slot)) return
    var id = activeSession
    if (service.beginActivation(id, slot) !== true) return
    pendingId = id
    pendingSlot = slot
    opened = false
    // Do not unload via shell.hide here: the service must outlive focus restoration.
    if (!panel.backingWindowVisible) Qt.callLater(function() { root.restoreFocus(id) })
  }

  function restoreFocus(id) {
    if (!pendingValid(id) || panel.backingWindowVisible) return
    if (!workspaceAvailable()) {
      failActivation(id, "OpenLogi: monitor or workspace changed before activation")
      return
    }
    if (!previousAddress) {
      var slot = pendingSlot
      if (!pendingValid(id)) return
      reset()
      service.sendActivation(id, slot)
      return
    }
    if (!/^0x[0-9a-fA-F]+$/.test(previousAddress)) {
      failActivation(id, "OpenLogi: invalid focus target")
      return
    }
    if (restoreStarted) return
    if (restoreProc.running) { restoreProc.queued = id; return }
    restoreStarted = true
    restoreProc.session = id
    restoreProc.collected = ""
    restoreProc.command = ["hyprctl", "dispatch",
      'hl.dsp.focus({ window = "address:' + previousAddress + '" })']
    restoreProc.running = true
  }

  function verifyFocus(id) {
    if (!pendingValid(id)) return
    if (!workspaceAvailable()) {
      failActivation(id, "OpenLogi: monitor or workspace changed during focus restoration")
      return
    }
    if (verifyStarted) return
    if (verifyProc.running) { verifyProc.queued = id; return }
    verifyStarted = true
    verifyProc.session = id
    verifyProc.collected = ""
    verifyProc.running = true
  }

  function verificationFinished(id, exitCode, text) {
    if (!pendingValid(id)) return
    try {
      if (exitCode !== 0 || !workspaceAvailable()) throw new Error("Focus verification failed")
      var window = JSON.parse(text)
      if (!window || window.address !== previousAddress || window.mapped === false
          || window.hidden === true || window.visible === false)
        throw new Error("Previous window is no longer active")
      if (window.workspace && window.workspace.id !== workspaceId)
        throw new Error("Previous window changed workspace")
      if (!pendingValid(id)) return
      var slot = pendingSlot
      reset()
      service.sendActivation(id, slot)
    } catch (e) { failActivation(id, "OpenLogi: " + e.message) }
  }

  function handleKey(event) {
    if (!opened || pendingId) return
    if (event.key === Qt.Key_Escape) {
      cancel()
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      var step = event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1
      focusIndex = (focusIndex + step + slots.length + 1) % (slots.length + 1)
      if (focusIndex === 0) cancelControl.forceActiveFocus()
      else slotRepeater.itemAt(focusIndex - 1).forceActiveFocus()
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
      if (focusIndex === 0) cancel()
      else activate(slots[focusIndex - 1].slot)
    } else return
    event.accepted = true
  }

  onServiceChanged: if (service && service.invocation) open("{}")
  Connections {
    target: root.service
    function onInvocationChanged() {
      var invocation = root.service && root.service.invocation
      if (!invocation) root.reset()
      else if (invocation.sessionId !== root.activeSession && invocation.sessionId !== root.pendingId)
        root.open("{}")
    }
  }
  Connections {
    target: Quickshell
    function onScreensChanged() {
      if (root.pendingId && !root.screenAvailable())
        root.failActivation(root.pendingId, "OpenLogi: monitor removed during activation")
      else if (root.opened && !root.screenAvailable())
        root.failPresentation(root.activeSession, "OpenLogi: monitor removed")
    }
  }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!/^(workspace(v2)?|focusedmon|moveworkspace(v2)?|monitorremoved|activespecial(v2)?)$/.test(event.name)) return
      if (root.pendingId && !root.workspaceAvailable())
        root.failActivation(root.pendingId, "OpenLogi: workspace changed during activation")
      else if (root.opened && !root.workspaceAvailable())
        root.failPresentation(root.activeSession, "OpenLogi: workspace changed")
    }
  }
  Connections {
    target: root.ringMonitor
    function onActiveWorkspaceChanged() {
      if (root.pendingId && !root.workspaceAvailable())
        root.failActivation(root.pendingId, "OpenLogi: workspace changed during activation")
      else if (root.opened && !root.workspaceAvailable())
        root.failPresentation(root.activeSession, "OpenLogi: workspace changed")
    }
  }

  Process {
    id: cursorProc
    property string session: ""
    property string queued: ""
    property string collected: ""
    command: ["hyprctl", "-j", "cursorpos"]
    stdout: SplitParser { onRead: function(line) { cursorProc.collected += line + "\n" } }
    onExited: function(exitCode) {
      root.cursorFinished(session, exitCode, collected)
      var next = queued
      queued = ""
      if (next && next === root.activeSession)
        Qt.callLater(function() { if (next === root.activeSession) root.startCursor(next) })
    }
  }
  Process {
    id: initialFocusProc
    property string session: ""
    property string queued: ""
    property string collected: ""
    command: ["hyprctl", "-j", "activewindow"]
    stdout: SplitParser { onRead: function(line) { initialFocusProc.collected += line + "\n" } }
    onExited: function(exitCode) {
      root.initialFocusFinished(session, exitCode, collected)
      var next = queued
      queued = ""
      if (next && next === root.activeSession)
        Qt.callLater(function() { if (next === root.activeSession) root.startInitialFocus(next) })
    }
  }
  Process {
    id: restoreProc
    property string session: ""
    property string queued: ""
    property string collected: ""
    stdout: SplitParser { onRead: function(line) { restoreProc.collected += line + "\n" } }
    onExited: function(exitCode) {
      var id = session
      if (root.pendingValid(id)) {
        if (exitCode !== 0 || collected.trim() !== "ok")
          root.failActivation(id, "OpenLogi: failed to restore previous window focus")
        else root.verifyFocus(id)
      }
      var next = queued
      queued = ""
      if (root.pendingValid(next))
        Qt.callLater(function() { if (root.pendingValid(next)) root.restoreFocus(next) })
    }
  }
  Process {
    id: verifyProc
    property string session: ""
    property string queued: ""
    property string collected: ""
    command: ["hyprctl", "-j", "activewindow"]
    stdout: SplitParser { onRead: function(line) { verifyProc.collected += line + "\n" } }
    onExited: function(exitCode) {
      root.verificationFinished(session, exitCode, collected)
      var next = queued
      queued = ""
      if (root.pendingValid(next))
        Qt.callLater(function() { if (root.pendingValid(next)) root.verifyFocus(next) })
    }
  }

  PanelWindow {
    id: panel
    screen: root.ringScreen
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-openlogi-action-ring"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    onBackingWindowVisibleChanged: {
      if (!backingWindowVisible && root.pendingId) root.restoreFocus(root.pendingId)
      else if (backingWindowVisible && root.opened) {
        var id = root.activeSession
        Qt.callLater(function() {
          if (id === root.activeSession && root.opened && panel.backingWindowVisible)
            cancelControl.forceActiveFocus()
        })
      }
    }

    // Full-screen input region consumes click-away instead of leaking it to an app.
    MouseArea {
      anchors.fill: parent
      enabled: root.opened
      onClicked: root.cancel()
    }

    Item {
      id: canvas
      visible: root.opened
      x: root.ringX
      y: root.ringY
      width: 360 * root.ringScale
      height: 360 * root.ringScale

      Item {
        width: 360
        height: 360
        scale: root.ringScale
        transformOrigin: Item.TopLeft

        Rectangle {
          x: 18; y: 18; width: 324; height: 324; radius: 162
          color: "#d10f0f0f"
          border.color: "#555555"
          MouseArea { anchors.fill: parent; onClicked: root.cancel() }
        }

        Rectangle {
          id: cancelControl
          x: 156; y: 156; width: 48; height: 48; radius: 24
          color: activeFocus ? Color.accent : "#333333"
          border.width: activeFocus ? 2 : 0
          border.color: "white"
          focus: root.opened
          activeFocusOnTab: true
          Accessible.role: Accessible.Button
          Accessible.name: "Cancelar OpenLogi"
          Accessible.description: "Fechar anel de ações sem executar ação"
          Accessible.onPressAction: root.cancel()
          onActiveFocusChanged: if (activeFocus) root.focusIndex = 0
          Keys.onPressed: function(event) { root.handleKey(event) }
          Text {
            anchors.centerIn: parent
            text: "×"
            color: "#f5f5f5"
            font.pixelSize: 27
            textFormat: Text.PlainText
          }
          MouseArea { anchors.fill: parent; onClicked: root.cancel() }
        }

        Repeater {
          id: slotRepeater
          model: root.slots
          delegate: Rectangle {
            id: slotControl
            required property var modelData
            required property int index
            readonly property var entry: modelData
            x: entry.x; y: entry.y; width: 54; height: 54; radius: 27
            color: activeFocus || root.hoveredSlot === entry.slot ? Color.accent : "#292929"
            border.width: activeFocus || root.hoveredSlot === entry.slot ? 2 : 0
            border.color: "#ececec"
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: entry.label
            Accessible.description: "Ativar ação OpenLogi"
            Accessible.onPressAction: root.activate(slotControl.entry.slot)
            onActiveFocusChanged: {
              if (activeFocus) {
                root.focusIndex = index + 1
                root.hover(entry.slot)
              }
            }
            Keys.onPressed: function(event) { root.handleKey(event) }
            Image {
              anchors.centerIn: parent
              width: 22; height: 22
              sourceSize.width: 22; sourceSize.height: 22
              source: "data:image/svg+xml;charset=utf-8," + encodeURIComponent(slotControl.entry.iconSvg.replace(/currentColor/g, "#f5f5f5"))
              fillMode: Image.PreserveAspectFit
            }
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: root.hover(slotControl.entry.slot)
              onClicked: root.activate(slotControl.entry.slot)
            }
          }
        }

        Text {
          x: 100; y: 214; width: 160
          horizontalAlignment: Text.AlignHCenter
          color: "#f0f0f0"
          font.pixelSize: 14
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: {
            for (var i = 0; i < root.slots.length; i++)
              if (root.slots[i].slot === root.hoveredSlot) return root.slots[i].label
            return ""
          }
        }
      }
    }
  }
}
