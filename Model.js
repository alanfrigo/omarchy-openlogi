.pragma library

var SLOT_NAMES = ["Top", "TopRight", "Right", "BottomRight", "Bottom", "BottomLeft", "Left", "TopLeft"]
var MAX_U64 = "18446744073709551615"

function sessionId(value) {
  if (typeof value !== "string" || !/^[1-9][0-9]*$/.test(value)
      || value.length > MAX_U64.length
      || (value.length === MAX_U64.length && value > MAX_U64))
    throw new Error("Invalid sessionId")
  return value
}

function exactKeys(value, required) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Expected object")
  var keys = Object.keys(value)
  if (keys.length !== required.length || required.some(function(key) { return !Object.prototype.hasOwnProperty.call(value, key) }))
    throw new Error("Unexpected protocol fields")
}

function parseMessage(line) {
  var message = JSON.parse(line)
  if (!message || typeof message !== "object" || Array.isArray(message)) throw new Error("Invalid bridge message")
  switch (message.type) {
  case "hello":
    exactKeys(message, ["type", "version", "displayLifetimeMs"])
    if (message.version !== 1 || !Number.isSafeInteger(message.displayLifetimeMs) || message.displayLifetimeMs <= 0)
      throw new Error("Incompatible bridge protocol")
    break
  case "status":
    exactKeys(message, ["type", "agent", "inventory", "devices"])
    if (["connecting", "connected", "unavailable", "incompatible"].indexOf(message.agent) < 0
        || ["scanning", "ready", "unavailable", "unknown"].indexOf(message.inventory) < 0
        || !Array.isArray(message.devices) || message.devices.some(function(name) { return typeof name !== "string" }))
      throw new Error("Invalid bridge status")
    break
  case "ring":
    exactKeys(message, ["type", "invocation"])
    if (message.invocation !== null) {
      exactKeys(message.invocation, ["sessionId", "slots"])
      sessionId(message.invocation.sessionId)
      if (!Array.isArray(message.invocation.slots) || message.invocation.slots.length > SLOT_NAMES.length)
        throw new Error("Invalid ring slots")
      var seen = {}
      message.invocation.slots.forEach(function(entry) {
        exactKeys(entry, ["slot", "label", "iconSvg", "x", "y"])
        if (SLOT_NAMES.indexOf(entry.slot) < 0 || seen[entry.slot]
            || typeof entry.label !== "string" || typeof entry.iconSvg !== "string"
            || !/^\s*<svg\b/i.test(entry.iconSvg) || !/<\/svg>\s*$/i.test(entry.iconSvg)
            || /<!|<\s*(script|style|image|use|foreignObject)\b|\bon\w+\s*=|\b(?:href|src)\s*=|\burl\s*\(|@import|&[a-z#]/i.test(entry.iconSvg)
            || typeof entry.x !== "number" || !Number.isFinite(entry.x) || entry.x < 0 || entry.x > 306
            || typeof entry.y !== "number" || !Number.isFinite(entry.y) || entry.y < 0 || entry.y > 306)
          throw new Error("Invalid ring slot")
        seen[entry.slot] = true
      })
    }
    break
  case "error":
    exactKeys(message, ["type", "message"])
    if (typeof message.message !== "string") throw new Error("Invalid bridge error")
    break
  default:
    throw new Error("Unknown bridge message")
  }
  return message
}

function placeRing(screen, cursor, extent) {
  if (!screen || !cursor || ![screen.x, screen.y, screen.width, screen.height, cursor.x, cursor.y, extent]
      .every(function(value) { return typeof value === "number" && Number.isFinite(value) })
      || screen.width <= 0 || screen.height <= 0 || extent <= 0
      || cursor.x < screen.x || cursor.y < screen.y
      || cursor.x >= screen.x + screen.width || cursor.y >= screen.y + screen.height)
    throw new Error("Cursor outside valid screen")
  var scale = Math.min(1, screen.width / extent, screen.height / extent)
  var size = extent * scale
  return {
    x: Math.max(0, Math.min(screen.width - size, cursor.x - screen.x - size / 2)),
    y: Math.max(0, Math.min(screen.height - size, cursor.y - screen.y - size / 2)),
    scale: scale
  }
}

function canInteract(currentId, incomingId, slots, slot) {
  if (typeof currentId !== "string" || currentId !== incomingId || !Array.isArray(slots)) return false
  return slots.some(function(entry) { return entry && entry.slot === slot && SLOT_NAMES.indexOf(slot) !== -1 })
}
