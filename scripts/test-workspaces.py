#!/usr/bin/env python3
"""Exercise workspace grouping, detail scheduling and project-editor routing without a model."""
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
    ui = {node = node, el = node, col = function(children) return node("col", nil, children) end},
    json = {array = function(value) return value end, null = false},
    fs = {exists = function() return true end, write = function() end},
    pane = {list = function() return {{pane = 1}} end},
    plugin = {data = "/tmp/ws-test/plugin"},
    runtime = {os = "linux"},
    getenv = function() return nil end,
    now = function() return 1 end,
    timer = function() return {cancel = function() end} end,
    kv = {get = function() return nil end, set = function() end},
}
local projects, checkouts, pending, calls, pid = {}, {}, {}, {}, 10
local roots = {["/tmp/ws-test/repo/app"] = "/tmp/ws-test/repo"}
local active_workspace, peak_workspace = 0, 0
local modules = {
    picker = {},
    updates = {get = function() return {} end, subscribe = function() return function() end end},
}
modules.cli = {
    status = function() return nil end,
    run = function(_, _, cb) cb({}) end,
    request = function(payload, cb, current)
        table.insert(calls, payload)
        if payload.op == "workspaces" then
            active_workspace += 1
            peak_workspace = math.max(peak_workspace, active_workspace)
        end
        table.insert(pending, {payload = payload, cb = cb, current = current})
    end,
}
local function require(path)
    local name = string.match(path, "([^/]+)$")
    return assert(modules[name], "unknown fixture dependency: " .. path)
end
__MODULES__
local panel, workspaces, fmt, tf = modules.panel, modules.workspaces, modules.fmt, modules.textfield
local function flush()
    local count = 0
    while #pending > 0 do
        count += 1
        assert(count < 500, "unexpected request loop")
        local job = table.remove(pending, 1)
        local p, data = job.payload, {}
        if p.op == "workspaces" then active_workspace -= 1 end
        if job.current and not job.current() then continue end
        if p.op == "snapshot" then data = {projects = projects, settings = {}, pinned = {}, recent = {}}
        elseif p.op == "folders" then data = {path = p.path}
        elseif p.op == "project-save" then
            local project = {id = tostring(#projects + 1), name = p.name, folders = table.clone(p.folders)}
            table.insert(projects, project)
            data = {project = project}
        elseif p.op == "workspaces" then
            local r = p.request
            if r.action == "poll" then data = {state = "running", checkouts = checkouts, pid = pid}
            elseif r.action == "roots" then
                for _, path in r.paths do data[path] = {source = roots[path] or path} end
            elseif r.action == "details" then data = {changes = {"one.txt"}, commits = {count = 2, titles = {"one", "two"}}}
            elseif r.action == "preview" then data = {source = "/tmp/ws-test/other", applied = {}, merged = {}, conflicts = {}, details = {}}
            elseif r.action ~= "resolve" then error("unexpected operation: " .. r.action) end
        end
        job.cb(data, nil)
    end
end
local cx = {pane = 1, render = function() end, frame = function() end, toast = function() end, open = function() end}
local function start(mode)
    local s = panel.init(cx, {mode, "/tmp/ws-test/header"})
    s.workspaces.visible = true
    workspaces.refresh(s)
    flush()
    return s
end
local function action(s, act, value)
    panel.event(s, {ev = "action", act = act, value = value}, cx)
end
local function workspace_action(s, verb, value)
    action(s, "ws", verb .. ":" .. fmt.pct(value or ""))
end
local function all_nodes(nodes, out)
    out = out or {}
    for _, n in nodes do
        table.insert(out, n)
        all_nodes(n.children, out)
    end
    return out
end
local function view(s) return all_nodes(workspaces.view(s)) end
local function has_text(nodes, text)
    for _, n in nodes do
        if n.props.text == text or n.props.label == text then return true end
    end
    return false
end
local function checkout(name, source, parent)
    return {name = name, source = source, source_location = source, location = "/mount/" .. name, path = "/mount/" .. name, identity = name, touched = "2026-11-12T00:00:00Z", parent_name = parent}
end
local function detail_calls()
    local count = 0
    for _, p in calls do if p.op == "workspaces" and p.request.action == "details" then count += 1 end end
    return count
end
local s = start("workspaces")
check(has_text(view(s), "Add a project to see its workspaces"), "no projects and no checkouts keeps the empty state")
checkouts = {
    checkout("parent", "/tmp/ws-test/repo"),
    checkout("child", "/tmp/ws-test/repo", "parent"),
    checkout("other", "/tmp/ws-test/other"),
    checkout("orphan", "/tmp/ws-test/other", "gone"),
    checkout("unknown", "/tmp/ws-test/missing"),
}
checkouts[5].source_location = nil
workspaces.refresh(s); flush()
local nodes = view(s)
check(has_text(nodes, "Not in a project"), "zero projects still shows existing checkouts")
check(not has_text(nodes, "Add a project to see its workspaces"), "existing checkouts suppress the misleading empty state")
local add_buttons, checkout_rows = 0, {}
for _, n in nodes do
    if n.props.actions and n.props.actions.click and string.find(n.props.actions.click, "ws=add-project:", 1, true) then add_buttons += 1 end
    if n.kind == "item" and string.sub(n.props.key, 1, 9) == "checkout:" then checkout_rows[n.props.key] = n end
end
check(add_buttons == 3, "one Add as project button per source, including an unresolved source")
check(#s.workspaces.order == 5, "every unassigned checkout has a navigable row")
check(detail_calls() == 5, "unassigned checkout details are fetched on first load")
check(peak_workspace == 3, "detail requests use the existing three-process cap")
check(string.find(checkout_rows["checkout:unassigned:/tmp/ws-test/repo:child"].props.label, string.rep("\u{00a0}", 4), 1, true) == 1, "fork lineage is retained")
check(checkout_rows["checkout:unassigned:/tmp/ws-test/other:orphan"] ~= nil, "missing parents do not hide checkouts")
check(string.find(checkout_rows["checkout:unassigned:/tmp/ws-test/repo:parent"].props.detail, "1 source changes · 2 commits not brought back", 1, true) ~= nil, "unassigned rows show source and commit counts")
workspaces.refresh(s); flush()
check(detail_calls() == 5, "unchanged unassigned details stay cached")
checkouts[1].touched = "2026-11-12T01:00:00Z"
workspaces.refresh(s); flush()
check(detail_calls() == 6, "touched changes re-request unassigned details")
pid += 1
workspaces.refresh(s); flush()
check(detail_calls() == 11, "daemon pid changes re-request all details")
workspace_action(s, "refresh"); flush()
check(detail_calls() == 16, "explicit refresh recomputes all details")
projects = {{id = "git-subfolder", name = "App", folders = {"/tmp/ws-test/repo/app"}}}
workspaces.library_changed(s); flush(); view(s)
check(s.workspaces.rows["checkout:git-subfolder:/tmp/ws-test/repo/app:parent"] ~= nil, "Git-subfolder association uses the capture root")
check(s.workspaces.rows["checkout:unassigned:/tmp/ws-test/repo:parent"] == nil, "assigned checkouts are not duplicated as unassigned")
check(s.workspaces.rows["checkout:unassigned:/tmp/ws-test/other:other"] ~= nil, "unrelated sources remain unassigned")
s.workspaces.locations["/mount/other/sub"] = "/mount/other/sub"
s.workspaces.agents = {{pane = 99, cwd = "/mount/other/sub", state = "waiting_input", live = true, title = "mock"}}
check(has_text(view(s), "\u{00a0}\u{00a0}\u{00a0}\u{00a0}Waiting for you"), "agents also render under unassigned checkouts")
for state, label in {working = "Working", idle = "Idle", done = "Done", failed = "Failed"} do
    s.workspaces.agents[1].state = state
    check(has_text(view(s), string.rep("\u{00a0}", 4) .. label), "agent state labels are English-only")
end
s.workspaces.agents[1].state = "waiting_input"
workspace_action(s, "preview", "other")
check(s.workspaces.dialog == nil and s.workspaces.error ~= nil, "unassigned apply keeps the live-agent guard")
workspace_action(s, "remove", "other")
check(s.workspaces.dialog == nil, "unassigned removal keeps the live-agent guard")
s.workspaces.agents = {}
workspace_action(s, "changes", "other"); flush()
check(has_text(all_nodes({workspaces.layer(s)}), "Source changes"), "source-change dialog labels are English-only")
workspace_action(s, "cancel")
workspace_action(s, "preview", "other"); flush()
local preview = all_nodes({workspaces.layer(s)})
for _, label in {"Applied + merged", "Conflict markers", "Left untouched"} do
    check(has_text(preview, label), "apply preview group labels are English-only")
end
workspace_action(s, "cancel")
projects = {}
workspaces.library_changed(s); flush()
workspace_action(s, "add-project", "/tmp/ws-test/repo")
check(s.editor.name.text == "repo" and s.editor.folders[1] == "/tmp/ws-test/repo" and #s.editor.folders == 1, "Add as project prefills name and source")
check(s.editor.id == nil and s.editor.origin_mode == "workspaces", "prefill creates a new Workspaces-origin draft")
tf.set(s.editor.name, "Edited project")
action(s, "editor", "save"); flush(); nodes = view(s)
check(s.mode == "workspaces" and s.workspaces.active and not s.editor, "saving from Add as project stays in Workspaces")
check(projects[1].name == "Edited project", "the prefilled name remains editable")
check(s.sel == "project:1" and s.expanded["project:1"] and s.workspaces.selected == "project:1", "the saved project is expanded and selected")
check(s.workspaces.rows["checkout:1:/tmp/ws-test/repo:parent"] ~= nil and s.workspaces.rows["checkout:unassigned:/tmp/ws-test/repo:parent"] == nil, "saving refreshes and moves checkouts under their project")
check(s.workspaces.rows["checkout:unassigned:/tmp/ws-test/other:other"] ~= nil, "saving leaves unrelated checkouts unassigned")
action(s, "create"); flush()
check(s.editor.origin_mode == "workspaces" and s.editor.folders[1] == "/tmp/ws-test/header", "header Add project uses the existing folder prefill")
action(s, "editor", "save"); flush()
check(s.mode == "workspaces" and s.workspaces.selected == "project:2", "header Add project save stays in Workspaces and selects the project")
action(s, "create"); flush(); action(s, "editor", "cancel")
check(s.mode == "workspaces" and not s.editor, "header cancel returns to Workspaces")
workspace_action(s, "add-project", "/tmp/ws-test/other"); action(s, "editor", "cancel")
check(s.mode == "workspaces" and not s.editor, "Add as project cancel returns to Workspaces")
workspaces.leave(s)
local p = start("projects")
action(p, "create"); flush(); action(p, "editor", "save"); flush()
check(p.mode == "projects" and not p.editor and not p.workspaces.active, "Projects-origin saving retains Projects-mode behavior")
action(p, "create"); flush(); action(p, "editor", "cancel")
check(p.mode == "projects" and not p.editor, "Projects-origin cancellation remains unchanged")
print("Workspace frontend: " .. tostring(assertions) .. " assertions passed (no model or network)")
'''
    modules = []
    for name in ("textfield", "fmt", "input", "ui", "project-editor", "workspaces", "panel"):
        path = root / ("blocks/panel.luau" if name == "panel" else f"lib/{name}.luau")
        modules.append(f'modules["{name}"] = (function()\n{path.read_text()}\nend)()')
    fixture = fixture.replace("__MODULES__", "\n".join(modules))
    with tempfile.TemporaryDirectory(prefix="workspaces-") as directory:
        file = Path(directory) / "workspaces.luau"
        file.write_text(fixture)
        return subprocess.run([runtime, str(file)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
