import QtQuick
import qs.Ui

BarWidget {
  id: root
  moduleName: "alanfrigo.openlogi"

  readonly property var openLogi: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
  readonly property string statusText: {
    if (!openLogi) return "Integração indisponível nesta barra"
    var state = openLogi.agentState
    if (state === "incompatible") return "OpenLogi incompatível"
    if (state === "unavailable") return "OpenLogi indisponível"
    if (state !== "connected" || !openLogi.protocolReady) return "Conectando ao OpenLogi"
    if (openLogi.inventoryState === "unavailable") return "OpenLogi: falha ao listar dispositivos"
    if (openLogi.inventoryState === "scanning" || openLogi.inventoryState === "unknown")
      return "OpenLogi: procurando dispositivos"
    var names = openLogi.deviceNames || []
    return names.length ? "OpenLogi conectado\n" + names.join("\n") : "Nenhum dispositivo conectado"
  }
  readonly property string detailText: statusText + (openLogi && openLogi.lastError ? "\n" + openLogi.lastError : "")

  function openDesktop() {
    if (openLogi) openLogi.openDesktop()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "Logi"
    tooltipText: root.detailText
    active: root.openLogi && root.openLogi.agentState === "connected" && root.openLogi.deviceNames.length > 0
    useActiveColor: false
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: "Abrir OpenLogi"
    Accessible.description: root.detailText
    onPressed: function(mouseButton) { if (mouseButton === Qt.LeftButton) root.openDesktop() }
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        root.openDesktop()
        event.accepted = true
      }
    }
  }
}
