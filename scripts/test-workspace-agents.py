#!/usr/bin/env python3
"""Exercise the actual window agent bridge without a terminal, model or configuration."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", default="luau")
    args = parser.parse_args()
    runtime = shutil.which(args.runtime)
    if runtime is None:
        parser.error(f"Luau runtime not found: {args.runtime}")
    source = (Path(__file__).resolve().parent.parent / "lib/workspace-agents.luau").read_text()
    source = source.replace('local fmt = require("./fmt")', 'local fmt = {unpct = function(s) return s end}', 1)
    fixture = r'''
local store, hooks = {}, {}
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in value do out[k] = copy(v) end
    return out
end
local assertions = 0
local function check(value, message)
    assert(value, message)
    assertions += 1
end
tern = {
    kv = {get = function(k) return copy(store[k]) end, set = function(k, v) store[k] = copy(v) end},
    on = function(k, fn) hooks[k] = fn end,
    timer = function() end,
    route = {link = function() end},
    json = {encode = function() return "{}" end},
}
local pane = {pane = 1, kind = "agent", cwd = "/mount/test", title = "mock", exited = 0, tab = 10}
local active, focused = {}, 2
local pane_present = true
local cx = {
    agents = {list = function() return active end},
    session = {
        panes = function()
            local out = {{pane = 2, kind = "terminal", cwd = "/outside", tab = 20}, {pane = 3, kind = "terminal", tab = 10}}
            if pane_present then table.insert(out, pane) end
            return out
        end,
        focused = function() return focused end,
    },
}
local function load_bridge()
    return (function()
__SOURCE__
    end)()
end
local bridge = load_bridge()
bridge.start()
check(bridge.snapshot(cx)[1].state == "idle", "unknown finished result must be idle")
check(not bridge.snapshot(cx)[1].live, "exited pane is not a live agent")
check(#bridge.snapshot(cx) == 1, "ordinary terminal panes are not agents")
hooks.agent_finished({pane = 1, result = "done"}, cx)
check(bridge.snapshot(cx)[1].state == "done", "only finish events record completion")
bridge = load_bridge()
bridge.start()
check(bridge.snapshot(cx)[1].state == "done", "finish result survives module reload")
focused = 1
hooks.focus({pane = 1, tab = 10}, cx)
focused = 2
bridge = load_bridge()
bridge.start()
check(bridge.snapshot(cx)[1].state == "idle", "focus acknowledgement is persisted across reload")
pane.exited = 7
hooks.agent_finished({pane = 1, result = "exited"}, cx)
check(bridge.snapshot(cx)[1].state == "failed", "nonzero native exit is failed")
hooks.agent_finished({pane = 1, result = "closed"}, cx)
check(bridge.snapshot(cx)[1].state == "failed", "closing a failed pane does not overwrite its result")
for _, state in {"working", "waiting_input"} do
    pane.exited = nil
    active = {{pane = 1, cwd = pane.cwd, state = state}}
    hooks.agent_state({pane = 1, new = state}, cx)
    check(bridge.snapshot(cx)[1].state == state, "restart uses native state")
    check(store["workspace-results:v1"]["1"] == nil, "restart persists removal of the old finish result")
    active[1].state = "idle"
    bridge = load_bridge()
    bridge.start()
    check(bridge.snapshot(cx)[1].state == "idle", "restart clearing survives reload without a native-state mask")
    active = {}
    pane.exited = 0
    hooks.agent_finished({pane = 1, result = "done"}, cx)
end
focused = 3 -- The agent's tab is shown, but its other split has focus.
for _, result in {"done", "failed"} do
    pane.exited = if result == "failed" then 7 else 0
    hooks.agent_finished({pane = 1, result = result}, cx)
    check(store["workspace-results:v1"]["1"].state == "idle", "finish in an already shown tab is acknowledged immediately")
    focused = 2
    bridge = load_bridge()
    bridge.start()
    check(bridge.snapshot(cx)[1].state == "idle", "already-shown acknowledgement survives reload")
    focused = 3
end
store["workspace-results:v1"]["1"].state = "done"
check(bridge.snapshot(cx)[1].state == "idle", "publishing also acknowledges an already shown result")
focused = 2
bridge = load_bridge()
bridge.start()
check(bridge.snapshot(cx)[1].state == "idle", "publish acknowledgement is persisted across reload")
focused = 3
pane_present = false -- Successful commands may auto-close before agent_finished.
hooks.agent_finished({pane = 1, result = "done"}, cx)
check(store["workspace-results:v1"]["1"].state == "idle", "auto-closed result remembers its already-shown tab")
focused = 2
bridge = load_bridge()
bridge.start()
check(bridge.snapshot(cx)[1].state == "idle", "auto-close acknowledgement survives reload")
print("Workspace agent bridge: " .. tostring(assertions) .. " assertions passed (no model or network)")
'''.replace("__SOURCE__", source)
    with tempfile.TemporaryDirectory(prefix="workspace-agents-") as directory:
        file = Path(directory) / "agent-bridge.luau"
        file.write_text(fixture)
        return subprocess.run([runtime, str(file)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
