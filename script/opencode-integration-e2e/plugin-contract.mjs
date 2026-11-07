// Run with node --experimental-vm-modules. Exercises the shipped TUI source.
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { EventEmitter } from 'node:events'
import vm from 'node:vm'

const source = await readFile(new URL('../../Resources/AgentIntegrations/open_code/awesomux-opencode-tui.js.template', import.meta.url), 'utf8')
const effects = []
const emitted = []
let listener
let spawnMode = 'normal'
let killed = false
let route = { type: 'session', sessionID: 'root-a' }
const info = new Map([['root-a', { id: 'root-a' }], ['root-b', { id: 'root-b' }], ['child-a', { id: 'child-a', parentID: 'root-a' }]])
const statuses = new Map()
const permissions = new Map()
const forms = new Map()
const context = vm.createContext({ process: { env: {
    AWESOMUX_AGENT_EVENT_PROTOCOL: 'awesomux-agent-v1',
    AWESOMUX_AGENT_EVENT_FILE: '/unused/pane-a', AWESOMUX_AGENT_HOOK: '/path with spaces/hook',
} }, setTimeout, clearTimeout, queueMicrotask, console })
const solid = new vm.SyntheticModule(['createEffect'], function () {
    this.setExport('createEffect', fn => { effects.push(fn); fn() })
}, { context })
const childProcess = new vm.SyntheticModule(['spawn'], function () {
    this.setExport('spawn', (command, args, options) => {
        if (spawnMode === 'throw') throw new Error('missing helper')
        assert.equal(command, '/path with spaces/hook')
        assert.deepEqual(Array.from(args), ['--provider', 'opencode'])
        assert.equal(options.shell, undefined)
        const child = new EventEmitter()
        child.stdin = new EventEmitter()
        child.stdin.end = text => {
            const payload = JSON.parse(text)
            assert.deepEqual(Object.keys(payload).sort(), ['hook_event_name', 'session_id'])
            emitted.push(payload)
            if (spawnMode !== 'hang') queueMicrotask(() => child.emit('close', 0))
        }
        child.kill = () => { killed = true }
        return child
    })
}, { context })
const plugin = new vm.SourceTextModule(source, { context })
await plugin.link(specifier => {
    if (specifier === 'solid-js') return solid
    if (specifier === 'node:child_process') return childProcess
    throw new Error(`Unexpected dependency ${specifier}`)
})
await plugin.evaluate()
assert.equal(plugin.namespace.default.id, 'awesomux.status')
const pluginContext = {
    ui: { router: { current: () => route } },
    data: {
        listen: callback => { listener = callback; return () => { listener = undefined } },
        session: {
            get: id => info.get(id),
            root: id => info.get(id)?.parentID || id,
            family: id => id === 'root-a' ? ['root-a', 'child-a'] : [id],
            status: id => statuses.get(id) || 'idle',
            permission: { list: id => permissions.get(id) || [] },
            form: { list: id => forms.get(id) || [] },
        },
    },
}
const cleanup = plugin.namespace.default.setup(pluginContext)
async function tick(event) {
    if (event) listener?.({ details: event })
    effects.forEach(fn => fn())
    await new Promise(resolve => setTimeout(resolve, 5))
}
const last = () => emitted.at(-1)
await tick()
assert.equal(last().hook_event_name, 'Stop')
statuses.set('root-a', 'running')
await tick({ type: 'session.execution.started', data: { sessionID: 'root-a' } })
assert.equal(last().hook_event_name, 'UserPromptSubmit')
const count = emitted.length
await tick({ type: 'session.execution.succeeded', data: { sessionID: 'child-a' } })
await tick({ type: 'session.execution.failed', data: { sessionID: 'root-b' } })
assert.equal(emitted.length, count, 'child and other client must not stop this pane')
permissions.set('child-a', [{ id: 'permission', prompt: 'private content' }])
await tick()
assert.equal(last().hook_event_name, 'PermissionRequest')
permissions.set('child-a', [])
await tick()
assert(emitted.some(item => item.hook_event_name === 'PermissionReplied'))
assert.equal(last().hook_event_name, 'UserPromptSubmit')
forms.set('child-a', [{ id: 'form', title: 'private question' }])
await tick()
assert.equal(last().hook_event_name, 'Notification')
forms.set('child-a', [])
await tick()
assert.equal(last().hook_event_name, 'UserPromptSubmit')
statuses.set('root-a', 'idle')
await tick({ type: 'session.execution.failed', data: { sessionID: 'root-a' } })
assert.equal(last().hook_event_name, 'StopFailure')
await tick()
assert.equal(last().hook_event_name, 'StopFailure', 'idle must preserve failure')
route = { type: 'session', sessionID: 'root-b' }
await tick()
assert.equal(last().session_id, 'root-b')
assert.equal(last().hook_event_name, 'Stop')
assert(emitted.some(item => item.hook_event_name === 'SessionEnd' && item.session_id === 'root-a'))
route = { type: 'session', sessionID: 'child-a' }
await tick()
assert.equal(last().session_id, 'root-a', 'child navigation stays associated with root')
route = { type: 'home' }
await tick()
assert.equal(last().hook_event_name, 'SessionEnd')
await cleanup()
assert.equal(listener, undefined)
const finalCount = emitted.length
await tick()
assert.equal(emitted.length, finalCount, 'disposed plugin must stop emitting')
// Unknown sessions and incomplete ancestry must never become pane owners.
route = { type: 'session', sessionID: 'unknown' }
const cleanupUnknown = plugin.namespace.default.setup(pluginContext)
await tick()
assert.equal(emitted.length, finalCount)
await cleanupUnknown()
// Outside awesoMux, setup must not subscribe or inspect client state.
context.process.env.AWESOMUX_AGENT_EVENT_PROTOCOL = 'other-host'
assert.equal(plugin.namespace.default.setup({}), undefined)
context.process.env.AWESOMUX_AGENT_EVENT_PROTOCOL = 'awesomux-agent-v1'
// Missing and hung helpers cannot reject setup/cleanup or block forever.
route = { type: 'session', sessionID: 'root-b' }
spawnMode = 'throw'
const cleanupMissing = plugin.namespace.default.setup(pluginContext)
await tick()
await cleanupMissing()
spawnMode = 'hang'
const cleanupHung = plugin.namespace.default.setup(pluginContext)
await tick()
const started = Date.now()
await cleanupHung()
assert(killed, 'hung helpers must be terminated')
assert(Date.now() - started < 4000, 'each queued helper call must remain bounded')
console.log('PASS: V2 pane routing, lifecycle, child permissions/forms, errors, privacy, cleanup')
