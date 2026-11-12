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
tern = {
    kv = {get = function(k) return store[k] end, set = function(k, v) store[k] = v end},
    on = function(k, fn) hooks[k] = fn end,
    timer = function() end,
    route = {link = function() end},
    json = {encode = function() return "{}" end},
}
local pane = {pane = 1, kind = "agent", cwd = "/mount/test", title = "mock", exited = 0, tab = 10}
local active = {}
local cx = {
    agents = {list = function() return active end},
    session = {
        panes = function() return {pane, {pane = 2, kind = "terminal", cwd = "/outside", tab = 20}} end,
        focused = function() return 2 end,
    },
}
local function load_bridge()
    return (function()
__SOURCE__
    end)()
end
local bridge = load_bridge()
bridge.start()
assert(bridge.snapshot(cx)[1].state == "idle", "unknown finished result must be idle")
assert(not bridge.snapshot(cx)[1].live, "exited pane is not a live agent")
assert(#bridge.snapshot(cx) == 1, "ordinary terminal panes are not agents")
hooks.agent_finished({pane = 1, result = "done"}, cx)
assert(bridge.snapshot(cx)[1].state == "done", "only finish events record completion")
bridge = load_bridge()
bridge.start()
assert(bridge.snapshot(cx)[1].state == "done", "finish result survives module reload")
hooks.focus({pane = 1, tab = 10}, cx)
assert(bridge.snapshot(cx)[1].state == "idle", "viewing the tab acknowledges completion")
pane.exited = 7
hooks.agent_finished({pane = 1, result = "exited"}, cx)
assert(bridge.snapshot(cx)[1].state == "failed", "nonzero native exit is failed")
hooks.agent_finished({pane = 1, result = "closed"}, cx)
assert(bridge.snapshot(cx)[1].state == "failed", "closing a failed pane does not overwrite its result")
pane.exited = nil
active = {{pane = 1, cwd = pane.cwd, state = "working"}}
hooks.agent_state({pane = 1, new = "working"}, cx)
assert(bridge.snapshot(cx)[1].state == "working", "restart uses native state")
assert(store["workspace-results:v1"]["1"] == nil, "restart clears the old finish result")
active[1].state = "waiting_input"
assert(bridge.snapshot(cx)[1].state == "waiting_input", "waiting state is not guessed from terminal text")
print("Workspace agent bridge: 11 assertions passed (no model or network)")
'''.replace("__SOURCE__", source)
    with tempfile.TemporaryDirectory(prefix="workspace-agents-") as directory:
        file = Path(directory) / "agent-bridge.luau"
        file.write_text(fixture)
        return subprocess.run([runtime, str(file)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
