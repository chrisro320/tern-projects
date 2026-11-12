#!/usr/bin/env python3
"""Exercise the Projects Recents All/This folder scope without a model or network."""
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
    root = Path(__file__).resolve().parent.parent
    fixture = r'''
local assertions = 0
local function check(value, message)
    assert(value, message)
    assertions += 1
end
local function node(kind, props, children)
    return {kind = kind, props = props or {}, children = children or {}}
end
tern = {
    ui = {node = node, el = node, col = function(children) return node("col", nil, children) end, span = function(text) return node("span", {text = text}) end},
    json = {array = function(value) return value end, null = false, decode = function(value) return value end},
    fs = {exists = function() return true end, write = function() end},
    pane = {list = function() return {{pane = 1}} end},
    plugin = {data = "/tmp/recents-test/plugin"},
    runtime = {os = "linux"},
    getenv = function() return nil end,
    now = function() return 1 end,
    timer = function(_, _) return {cancel = function() end} end,
    kv = {get = function() return nil end, set = function() end},
}
local global_recent = {{uid = "all-1", title = "All one"}, {uid = "all-2", title = "All two"}}
local scoped_recent = {{uid = "repo-1", title = "Repo one"}}
local calls, pending = {}, {}
local modules = {picker = {}, updates = {get = function() return {} end, subscribe = function() return function() end end}}
modules.cli = {
    status = function() return nil end,
    run = function(_, _, cb) if cb then cb({}) end end,
    request = function(payload, cb) table.insert(calls, payload); table.insert(pending, {payload = payload, cb = cb}) end,
}
local function require(path)
    local name = string.match(path, "([^/]+)$")
    return assert(modules[name], "unknown fixture dependency: " .. path)
end
__MODULES__
local panel = modules.panel
local function settle()
    local job = table.remove(pending, 1)
    if not job then return end
    local p = job.payload
    local data = {}
    if p.op == "snapshot" then
        data = {projects = {}, settings = {}, pinned = {}, recent = if p.recent_cwd then table.clone(scoped_recent) else table.clone(global_recent)}
    end
    job.cb(data, nil)
end
local function flush()
    local count = 0
    while #pending > 0 do
        count += 1
        assert(count < 100, "unexpected request loop")
        settle()
    end
end
local cx = {pane = 1, render = function() end, frame = function() end, toast = function() end, open = function() end, copy = function() end}
local function action(s, act, value)
    panel.event(s, {ev = "action", act = act, value = value}, cx)
end
local function last_snapshot()
    for i = #calls, 1, -1 do if calls[i].op == "snapshot" then return calls[i] end end
end
local function uids(list)
    local out = {}
    for _, chat in list do table.insert(out, chat.uid) end
    return table.concat(out, ",")
end
local function start(saved)
    local s = panel.init(cx, {"projects", "/tmp/recents/repo"}, saved)
    flush()
    return s
end
local s = start(nil)
check(s.recent_filter == "all", "Recents defaults to All")
check(last_snapshot().recent_cwd == nil, "All sends the global snapshot without a folder")
check(uids(s.recent) == "all-1,all-2", "All keeps the unchanged newest-first list")
check(s.rows["recent:all-1"] ~= nil and s.rows["recent:repo-1"] == nil, "All rows come from the global list")
action(s, "recent", "folder"); flush()
check(s.recent_filter == "folder", "This folder is selected")
check(last_snapshot().recent_cwd == "/tmp/recents/repo", "This folder scopes the snapshot to the panel path")
check(uids(s.recent) == "repo-1", "This folder shows only its chats")
check(s.rows["recent:repo-1"] ~= nil and s.rows["recent:all-1"] == nil, "This folder replaces the global rows")
-- An empty folder says so instead of showing chats from elsewhere.
scoped_recent = {}
action(s, "reload"); flush()
check(s.rows["recent:none"] ~= nil and s.rows["recent:none"].ref.label == "No chats in this folder yet", "an empty folder shows its empty state")
-- A different panel path follows the scope.
scoped_recent = {{uid = "other-1", title = "Other one"}}
action(s, "open=projects:/tmp/recents/other"); flush()
check(last_snapshot().recent_cwd == "/tmp/recents/other", "changing the panel path scopes This folder to it")
check(uids(s.recent) == "other-1", "changing the panel path refreshes the folder list")
-- Switching back restores the unchanged global list.
action(s, "recent", "all"); flush()
check(last_snapshot().recent_cwd == nil and uids(s.recent) == "all-1,all-2", "All restores the global list")
-- The choice survives a reopened panel, and old saves without it stay on All.
local saved = panel.save(s)
check(saved.recent_filter == "all", "the panel saves the chosen scope")
local legacy = panel.save(s)
legacy.recent_filter = nil
check(start(legacy).recent_filter == "all", "an old saved state without the field means All")
local folder = start(nil)
action(folder, "recent", "folder"); flush()
check(panel.save(folder).recent_filter == "folder", "This folder is persisted")
local restored = start(panel.save(folder))
check(restored.recent_filter == "folder", "a reopened panel restores This folder")
check(last_snapshot().recent_cwd == "/tmp/recents/repo", "the restored scope applies on load")
-- The keyboard menu reaches both scopes.
action(restored, "panel-options")
check(restored.menu ~= nil, "panel options open")
local ids = table.concat(restored.menu.ids, ",")
check(string.find(ids, "recent=all", 1, true) and string.find(ids, "recent=folder", 1, true), "panel options list both Recents scopes")
panel.event(restored, {ev = "action", id = "layer.menu", act = "menu", value = "recent=all"}, cx); flush()
check(restored.recent_filter == "all" and restored.menu == nil, "the menu switches the scope")
print("Recents scope: " .. tostring(assertions) .. " assertions passed (no model or network)")
'''
    modules = []
    for name in ("textfield", "fmt", "input", "ui", "project-editor", "workspaces", "panel"):
        path = root / ("blocks/panel.luau" if name == "panel" else f"lib/{name}.luau")
        modules.append(f'modules["{name}"] = (function()\n{path.read_text()}\nend)()')
    fixture = fixture.replace("__MODULES__", "\n".join(modules))
    with tempfile.TemporaryDirectory(prefix="recents-") as directory:
        file = Path(directory) / "recents.luau"
        file.write_text(fixture)
        return subprocess.run([runtime, str(file)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
