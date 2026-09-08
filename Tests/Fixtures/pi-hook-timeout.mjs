import assert from "node:assert/strict"
import childProcess from "node:child_process"
import { writeFileSync, readFileSync } from "node:fs"
import { syncBuiltinESMExports } from "node:module"
import { dirname, join } from "node:path"
import { pathToFileURL } from "node:url"

const templatePath = process.argv[2]
const directory = dirname(templatePath)
const children = []
const originalSpawn = childProcess.spawn
childProcess.spawn = (...args) => {
    const child = originalSpawn(...args)
    const closed = new Promise(resolve => child.once("close", (code, signal) => resolve({ code, signal })))
    children.push({ child, closed })
    return child
}
syncBuiltinESMExports()

// This deadline also cleans up children when the unpatched template hangs.
let timedOut = false
const watchdog = setTimeout(() => {
    timedOut = true
    for (const { child } of children) child.kill("SIGKILL")
    console.error("Pi hook did not finish within the test deadline")
    process.exitCode = 1
}, 5000)

try {
    const { default: extension } = await import(pathToFileURL(templatePath))
    const handlers = new Map()
    extension({ on: (name, handler) => handlers.set(name, handler) })
    const context = { sessionManager: { getSessionId: () => "test-session" } }
    const output = join(directory, "payload.json")
    const helper = join(directory, "helper")
    process.env.AWESOMUX_AGENT_EVENT_PROTOCOL = "awesomux-agent-v1"
    process.env.AWESOMUX_AGENT_EVENT_FILE = output
    process.env.AWESOMUX_AGENT_HOOK = helper
    writeFileSync(helper, `#!${process.execPath}\nconst fs = require("node:fs"); let text = ""; process.stdin.on("data", chunk => text += chunk); process.stdin.on("end", () => fs.writeFileSync(process.env.AWESOMUX_AGENT_EVENT_FILE, text));\n`, { mode: 0o700 })
    await handlers.get("session_start")({}, context)
    assert.deepEqual(JSON.parse(readFileSync(output, "utf8")), {
        hook_event_name: "SessionStart", session_id: "test-session",
    })
    assert.deepEqual(await children.at(-1).closed, { code: 0, signal: null })

    writeFileSync(helper, `#!${process.execPath}\nprocess.on("SIGTERM", () => {}); setInterval(() => {}, 1000);\n`)
    await handlers.get("tool_execution_start")({}, context)
    assert.deepEqual(await children.at(-1).closed, { code: null, signal: "SIGKILL" })

    process.env.AWESOMUX_AGENT_HOOK = join(directory, "missing-helper")
    await handlers.get("session_shutdown")({}, context)
    await children.at(-1).closed
    assert.equal(children.length, 3)
    assert.equal(timedOut, false, "Pi hook exceeded the test deadline")
    console.log("Pi hook: normal exit, hung helper cleanup, and spawn failure passed")
} finally {
    clearTimeout(watchdog)
    for (const { child } of children) {
        if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL")
    }
    childProcess.spawn = originalSpawn
    syncBuiltinESMExports()
}
