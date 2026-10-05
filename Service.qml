import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var shell: null
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string privateBin: (Quickshell.env("XDG_DATA_HOME") || home + "/.local/share") + "/omarchy-openlogi/bin"
  property string agentState: "connecting"
  property string inventoryState: "unknown"
  property var deviceNames: []
  property string lastError: ""
  property var invocation: null
  property bool protocolReady: false
  property string pendingId: ""
  property string pendingSlot: ""
  property bool interactive: false
  property bool active: true
  property bool started: false
  property bool incompatible: false
  property string previousStatus: ""
  property bool stopping: false
  property int helloTicks: 0

  function hideRing() {
    if (shell) shell.hide("alanfrigo.openlogi")
  }

  function clearRing() {
    invocation = null
    interactive = false
    pendingId = ""
    pendingSlot = ""
    hideRing()
  }

  function stopForProtocol(message) {
    lastError = message
    incompatible = true
    protocolReady = false
    agentState = "incompatible"
    inventoryState = "unknown"
    deviceNames = []
    clearRing()
    retry.stop()
    stopping = true
    bridge.running = false
  }

  function handleLine(line) {
    if (!active || stopping) return
    var message
    try {
      message = Model.parseMessage(line)
    } catch (error) {
      stopForProtocol("Protocolo OpenLogi inválido: " + String(error))
      return
    }
    if (!protocolReady) {
      if (message.type !== "hello") {
        stopForProtocol("Ponte OpenLogi não enviou hello")
        return
      }
      retry.stop()
      protocolReady = true
      lastError = ""
      return
    }
    if (message.type === "hello") {
      stopForProtocol("Ponte OpenLogi enviou hello duplicado")
    } else if (message.type === "status") {
      var status = JSON.stringify(message)
      if (status === previousStatus) return
      previousStatus = status
      agentState = message.agent
      inventoryState = message.inventory
      deviceNames = message.devices
      if (message.agent === "incompatible") incompatible = true
      if (message.agent !== "connected") clearRing()
    } else if (message.type === "ring") {
      if (message.invocation === null) {
        clearRing()
      } else {
        // A new presentation supersedes both an interactive ring and pending focus restoration.
        interactive = true
        pendingId = ""
        pendingSlot = ""
        invocation = message.invocation
        if (shell && !shell.summon("alanfrigo.openlogi", "{}"))
          failPresentation(invocation.sessionId, "Não foi possível abrir o Action Ring")
      }
    } else if (message.type === "error") {
      lastError = message.message
      if (agentState === "incompatible") {
        incompatible = true
        bridge.running = false
      }
    }
  }

  function validSlot(sessionId, slot) {
    return protocolReady && bridge.running && interactive && invocation !== null
      && Model.canInteract(invocation.sessionId, sessionId, invocation.slots, slot)
  }

  function writeCommand(command) {
    if (!protocolReady || !bridge.running) return false
    bridge.write(JSON.stringify(command) + "\n")
    return true
  }

  function hover(sessionId, slot) {
    if (!validSlot(sessionId, slot)) return false
    return writeCommand({ type: "hover", sessionId: sessionId, slot: slot })
  }

  function cancel(sessionId) {
    if (!interactive || !invocation || invocation.sessionId !== sessionId) return false
    interactive = false
    invocation = null
    var sent = writeCommand({ type: "cancel", sessionId: sessionId })
    hideRing()
    return sent
  }

  function failPresentation(sessionId, message) {
    if (!interactive || !invocation || invocation.sessionId !== sessionId) return false
    lastError = String(message)
    return cancel(sessionId)
  }

  // Activation is a two-phase operation: only sendActivation may reach the agent.
  function activate(sessionId, slot) { return beginActivation(sessionId, slot) }

  function beginActivation(sessionId, slot) {
    if (!validSlot(sessionId, slot)) return false
    interactive = false
    pendingId = sessionId
    pendingSlot = slot
    return true
  }

  function sendActivation(sessionId, slot) {
    if (!pendingId || pendingId !== sessionId || pendingSlot !== slot
        || !invocation || invocation.sessionId !== sessionId) return false
    pendingId = ""
    pendingSlot = ""
    invocation = null
    var sent = writeCommand({ type: "activate", sessionId: sessionId, slot: slot })
    hideRing()
    return sent
  }

  function failActivation(sessionId, message) {
    if (!pendingId || pendingId !== sessionId || !invocation || invocation.sessionId !== sessionId) return false
    lastError = String(message)
    pendingId = ""
    pendingSlot = ""
    invocation = null
    var sent = writeCommand({ type: "cancel", sessionId: sessionId })
    hideRing()
    return sent
  }

  function openDesktop() {
    desktop.startDetached()
  }

  function bridgeStopped() {
    if (!active || stopping) return
    protocolReady = false
    previousStatus = ""
    clearRing()
    inventoryState = "unknown"
    deviceNames = []
    if (incompatible) {
      agentState = "incompatible"
      return
    }
    agentState = "unavailable"
    if (!started) {
      lastError = "Ponte OpenLogi não pôde iniciar; confira o build privado"
      stopping = true
      retry.stop()
      return
    }
    retry.restart()
  }

  Component.onCompleted: {
    bridge.running = true
    retry.start()
  }
  Component.onDestruction: {
    active = false
    retry.stop()
    bridge.running = false
  }

  Process {
    id: bridge
    command: [root.privateBin + "/openlogi-overlay", "--stdio"]
    environment: ({ OPENLOGI_OVERLAY_BACKEND: "external", OPENLOGI_RUN: null })
    stdinEnabled: true
    onStarted: {
      root.started = true
      root.helloTicks = 0
      retry.restart()
    }
    onRunningChanged: if (!running) root.bridgeStopped()
    stdout: SplitParser { onRead: function(line) { if (root) root.handleLine(line) } }
    stderr: SplitParser {
      onRead: function(line) {
        if (line) console.warn("OpenLogi bridge stderr (content redacted, " + Math.min(String(line).length, 4096) + " characters)")
      }
    }
  }

  Timer {
    id: retry
    interval: 1000
    repeat: false
    onTriggered: {
      if (!root.active || root.incompatible || root.stopping) return
      if (bridge.running) {
        if (root.protocolReady) return
        root.helloTicks++
        if (root.helloTicks >= 3) {
          if (root.started) root.stopForProtocol("Ponte OpenLogi não enviou hello a tempo")
          else {
            root.lastError = "Ponte OpenLogi não pôde iniciar; confira o build privado"
            root.agentState = "unavailable"
            root.stopping = true
            bridge.running = false
          }
        } else retry.restart()
        return
      }
      root.started = false
      root.helloTicks = 0
      root.agentState = "connecting"
      bridge.running = true
      retry.restart()
    }
  }

  Process {
    id: desktop
    command: [root.privateBin + "/openlogi-desktop"]
    environment: ({ OPENLOGI_OVERLAY_BACKEND: "external", OPENLOGI_RUN: null })
  }

  IpcHandler {
    target: "alanfrigo.openlogi"
    function status(): string {
      return JSON.stringify({
        protocolReady: root.protocolReady,
        agentState: root.agentState,
        inventoryState: root.inventoryState,
        deviceNames: root.deviceNames,
        lastError: root.lastError,
        sessionId: root.invocation ? root.invocation.sessionId : (root.pendingId || null)
      })
    }
  }
}
