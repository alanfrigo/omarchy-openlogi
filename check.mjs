import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'

const code = readFileSync(new URL('./Model.js', import.meta.url), 'utf8').replace(/^\.pragma library\s*\n/, '')
const model = vm.createContext({})
vm.runInContext(code, model, { filename: 'Model.js' })

const id = '9007199254740993'
const slot = { slot: 'Top', label: 'Copy', iconSvg: '<svg xmlns="http://www.w3.org/2000/svg"></svg>', x: 153, y: 31 }
const ring = model.parseMessage(JSON.stringify({ type: 'ring', invocation: { sessionId: id, slots: [slot] } }))
assert.equal(ring.invocation.sessionId, id)
assert.equal(model.canInteract(id, ring.invocation.sessionId, ring.invocation.slots, 'Top'), true)
assert.equal(model.canInteract('17', ring.invocation.sessionId, ring.invocation.slots, 'Top'), false)
assert.equal(model.canInteract(id, ring.invocation.sessionId, ring.invocation.slots, 'Bottom'), false)
assert.throws(() => model.parseMessage('{"type":"ring","invocation":{"sessionId":9007199254740993,"slots":[]}}'))
assert.throws(() => model.parseMessage('{"type":"ring","invocation":{"sessionId":"18446744073709551616","slots":[]}}'))
assert.throws(() => model.parseMessage(JSON.stringify({ type: 'ring', invocation: { sessionId: id, slots: [{ ...slot, slot: 'Center' }] } })))
assert.throws(() => model.parseMessage(JSON.stringify({ type: 'ring', invocation: { sessionId: id, slots: [{ ...slot, iconSvg: '<svg onload="alert(1)"></svg>' }] } })))
assert.throws(() => model.parseMessage(JSON.stringify({ type: 'ring', invocation: { sessionId: id, slots: [{ ...slot, iconSvg: '<svg><style>@import "https://example.org/a"</style></svg>' }] } })))
assert.throws(() => model.parseMessage(JSON.stringify({ type: 'ring', invocation: { sessionId: id, slots: [slot, slot] } })))
assert.throws(() => model.parseMessage('{"type":"hello","version":34,"displayLifetimeMs":15000}'))
assert.equal(model.parseMessage('{"type":"status","agent":"connected","inventory":"ready","devices":[]}').devices.length, 0)

const screen = { x: -1920, y: -200, width: 1920, height: 1080 }
function location(cursor, display = screen) {
  const point = model.placeRing(display, cursor, 360)
  const size = 360 * point.scale
  assert(point.x >= 0 && point.y >= 0 && point.x + size <= display.width && point.y + size <= display.height)
  return point
}
assert.equal(location({ x: -1920, y: -200 }).x, 0)
assert.equal(location({ x: -1, y: 879 }).y, 720)
assert.equal(location({ x: -960, y: 340 }).x, 780)
const small = { x: -240, y: 150, width: 240, height: 180 }
assert.equal(location({ x: -120, y: 240 }, small).scale, 0.5)
assert.throws(() => model.placeRing(screen, { x: 0, y: 300 }, 360))
console.log('OpenLogi model checks passed')
