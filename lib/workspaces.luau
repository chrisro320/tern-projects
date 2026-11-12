--!strict
-- Host-only management facade and tab view. All OVNFS/Git argv live in the Rust adapter.
local cli = require("./cli")
local fmt = require("./fmt")
local tf = require("./textfield")
local input = require("./input")
local c = require("./ui")
local ui = tern.ui
local M = {}
local running = 0
local queue: {any} = {}
local pump: () -> ()
pump = function()
	while running < 3 and #queue > 0 do
		local job = table.remove(queue, 1)
		if job.current() then
			running += 1
			cli.request({op = "workspaces", request = job.payload}, function(data: any, err: string?)
				running -= 1
				if job.current() then job.cb(data, err) end
				pump()
			end)
		end
	end
end
local function request(payload: any, cb: (any, string?) -> (), current: () -> boolean)
	table.insert(queue, {payload = payload, cb = cb, current = current})
	pump()
end
local function act(verb: string, key: string?): string return "ws=" .. verb .. ":" .. fmt.pct(key or "") end
local function under(path: string, root: string): boolean return path == root or string.sub(path, 1, #root + 1) == root .. "/" end
local function target(w: any, key: string): any
	for _, checkout in w.checkouts do if checkout.name == key then return checkout end end
	return nil
end
local function grouped_agents(w: any): any
	local out = {}
	for _, agent in w.agents do
		local best = nil
		for _, checkout in w.checkouts do
			if type(agent.cwd) == "string" and under(agent.cwd, checkout.path) and (not best or #checkout.path > #best.path) then best = checkout end
		end
		if best then
			out[best.name] = out[best.name] or {}
			table.insert(out[best.name], agent)
		end
	end
	return out
end
local function blocked(w: any, checkout: any, removing: boolean): string?
	for _, agent in grouped_agents(w)[checkout.name] or {} do
		if (removing and agent.live) or agent.state == "working" or agent.state == "waiting_input" then
			return if removing then "An agent is still live here. Close its tab before removing this workspace." else "An agent is working or waiting for you here. Finish or stop it before applying."
		end
	end
	return nil
end
local function payload(checkout: any, verb: string): any return {action = verb, name = checkout.name, identity = checkout.identity} end
local function note_paths(title: string, paths: {any}): {any}
	local kids: {any} = {c.label(title, tostring(#paths))}
	if #paths == 0 then table.insert(kids, c.note("None")) end
	for i, item in paths do
		local text = if type(item) == "string" then item else tostring(item.path) .. (if item.reason then " · " .. item.reason else "")
		table.insert(kids, ui.node("text", {key = title .. ":" .. tostring(i), text = text, lines = 2, role = "tern-projects.workspace-path"}))
	end
	return kids
end
local function append(out: {any}, nodes: {any}) for _, node in nodes do table.insert(out, node) end end
local function result_body(data: any): {any}
	local merged, conflicts, untouched = {}, {}, {}
	for _, item in data.applied or {} do table.insert(merged, item.path) end
	for _, path in data.merged or {} do table.insert(merged, path .. " · three-way merge") end
	for _, item in data.conflicts or {} do table.insert(if item.markers then conflicts else untouched, item) end
	local body = {c.note("Target: " .. tostring(data.source or "")), c.note("Source-only edits are retained. Conflicts with markers need resolving in the target folder.")}
	append(body, note_paths("已合併 / Applied + merged", merged))
	append(body, note_paths("有衝突 / Conflict markers", conflicts))
	append(body, note_paths("未動 / Left untouched", untouched))
	return body
end
local function info_body(info: any): {any}
	local body = {}
	append(body, note_paths("原始碼改動 / Source changes", info.changes or {}))
	if info.commits and type(info.commits) == "table" then
		append(body, note_paths(tostring(info.commits.count) .. " commits not brought back", info.commits.titles or {}))
		if info.commits.count > 25 then table.insert(body, c.note("Showing the newest 25 commit titles.")) end
	end
	if type(info.error) == "string" then table.insert(body, c.banner("git-error", "error", "warn", info.error)) end
	return body
end
local function dialog(w: any, kind: string, title: string, body: {any}, buttons: {any}, extra: any?): any
	local d = extra or {}
	d.kind = kind; d.title = title; d.body = body; d.buttons = buttons; d.focus = 1
	w.dialog = d
	return d
end
local function close(w: any)
	if w.authorization then w.busy = false end
	w.dialog = nil; w.nonce = nil; w.authorization = nil; w.flow += 1
end
local function failure(s: any, err: string)
	local w = s.workspaces
	if w.dialog and w.dialog.kind == "menu" then close(w) end
	w.error = fmt.error(err)
	if w.dialog then w.dialog.error = w.error end
	s.cx:toast("error", "Workspace operation blocked", w.error)
	s.cx:render()
end
function M.init(s: any, live: (any) -> boolean, launch: (any, string) -> ())
	s.workspaces = {state = "loading", projects = {}, checkouts = {}, cache = {}, agents = {}, order = {}, rows = {}, seq = 0, flow = 0, live = live, launch = launch, active = false, busy = false}
end
local function alive(s: any): boolean return s.workspaces.live(s) end
local function agent_request(s: any)
	if alive(s) then s.cx:open("tern-projects://workspace?nonce=" .. fmt.pct(s.workspaces.nonce or "")) end
end
local function details(s: any, checkout: any, cb: (any) -> (), verb: string?)
	local w, flow = s.workspaces, s.workspaces.flow
	request(payload(checkout, verb or "details"), function(data, err)
		if err then failure(s, err) else cb(data); s.cx:render() end
	end, function() return alive(s) and w.active and w.flow == flow end)
end
function M.refresh(s: any)
	local w = s.workspaces
	if not alive(s) or not w.active or w.polling then return end
	agent_request(s)
	if not w.visible then return end
	w.polling = true
	local seq = w.seq
	local current = function() return alive(s) and w.active and w.seq == seq end
	request({action = "poll"}, function(data, err)
		w.polling = false
		if err then w.state = "error"; w.status_error = err; s.cx:render(); return end
		w.state, w.status_error, w.external_busy = data.state, data.error, data.busy
		local old_pid = w.pid
		w.pid = data.pid
		w.checkouts = if data.state == "running" then data.checkouts or {} else {}
		local wanted = {}
		for _, project in w.projects do for _, folder in project.folders or {} do wanted[folder] = true end end
		for _, checkout in w.checkouts do
			local key = checkout.identity .. ":" .. checkout.touched .. ":" .. tostring(w.pid)
			local cached = w.cache[checkout.name]
			if wanted[checkout.source] and (not cached or cached.key ~= key or old_pid ~= w.pid) then
				w.cache[checkout.name] = {key = key, loading = true}
				request(payload(checkout, "details"), function(info, detail_error)
					if w.cache[checkout.name] and w.cache[checkout.name].key == key then
						w.cache[checkout.name] = {key = key, info = info, error = detail_error}
						s.cx:render()
					end
				end, current)
			end
		end
		s.cx:render()
	end, current)
end
function M.enter(s: any)
	local w = s.workspaces
	if w.active then return end
	w.active = true; w.seq += 1; w.polling = false
	local seq = w.seq
	cli.request({op = "snapshot", view = "mine", per = 0, recent = 0}, function(data: any, err: string?)
		if not alive(s) or not w.active or w.seq ~= seq then return end
		if err then w.error = err else w.projects = data.projects or {} end
		M.refresh(s); s.cx:render()
	end)
	M.refresh(s)
	local function tick()
		tern.timer(2000, function()
			if not alive(s) or not w.active or w.seq ~= seq then return end
			M.refresh(s); tick()
		end)
	end
	tick()
end
function M.leave(s: any)
	local w = s.workspaces
	w.active = false; w.seq += 1; w.polling = false; close(w)
end
function M.library_changed(s: any)
	local w = s.workspaces
	if not w.active then M.enter(s); return end
	w.active = false
	M.enter(s)
end
local function operate(s: any, req: any, checkout: any?, cb: (any) -> ())
	local w = s.workspaces
	if w.busy or w.external_busy then failure(s, "A workspace operation is still running. Refresh before trying again."); return end
	w.busy = true; w.error = nil
	local function start()
		if checkout then
			local reason = blocked(w, checkout, req.action == "remove" or req.action == "save-remove")
			if reason then w.busy = false; failure(s, reason); return end
		end
		-- Mutations outlive their view. Keep the callback even when the dialog/tab closes.
		request(req, function(data, err)
			w.busy = false; w.cache = {}
			if not alive(s) then return end
			if err then failure(s, err) else w.error = nil; cb(data) end
			M.refresh(s); s.cx:render()
		end, function() return true end)
	end
	if checkout then
		w.nonce = tostring(tern.now()) .. ":" .. tostring(s.cx.pane)
		w.authorization = start
		agent_request(s)
		local nonce = w.nonce
		tern.timer(2000, function()
			if w.nonce == nonce and w.authorization then w.authorization = nil; w.nonce = nil; w.busy = false; if alive(s) then failure(s, "Cannot read live Tern agents. Focus this local Projects panel and retry.") end end
		end)
	else start() end
end
local function buttons(): {any} return {{id = "cancel", label = "Cancel"}} end
local function form(s: any, kind: string, checkout: any?, source: string?)
	local w = s.workspaces
	close(w)
	local titles = {new = "New workspace", fork = "Fork workspace", branch = "Save commits as a new branch", ["save-remove"] = "Save commits as branch, then remove"}
	local d = dialog(w, kind, titles[kind], {c.note(if source then "Source: " .. source else "Workspace: " .. checkout.name)}, {{id = "cancel", label = "Cancel"}, {id = "submit", label = if kind == "save-remove" then "Save branch & remove" else "Create", variant = if kind == "save-remove" then "danger" else "primary"}}, {checkout = checkout, source = source, field = tf.new(""), all = false})
	if kind == "branch" or kind == "save-remove" then table.insert(d.body, c.note("Commits only; working-tree source changes are not applied. Choose a branch that does not exist in the source repository."))
	else table.insert(d.body, c.note("1–64 lowercase letters, numbers, dots, underscores or hyphens; begin with a letter or number. Names are unique across OVNFS.")) end
	d.focus = 2
	s.cx:frame({{"focus", "layer.workspace.form.name"}})
end
local function show(s: any, checkout: any, kind: string)
	local w = s.workspaces
	close(w)
	local d = dialog(w, "loading", "Checking " .. checkout.name .. "…", {c.note("Reading OVNFS and Git…")}, buttons())
	details(s, checkout, function(data)
		if w.dialog ~= d then return end
		if kind == "preview" then
			local body = result_body(data)
			table.insert(body, c.note("This preview does not write files. Applying writes clean changes and conflict markers into the target folder."))
			if data.details.commits and type(data.details.commits) == "table" and data.details.commits.count > 0 then table.insert(body, c.note(tostring(data.details.commits.count) .. " commits are not carried by Apply. Save them as a new branch separately.", "warning")) end
			dialog(w, "apply", "Preview apply: " .. checkout.name, body, {{id = "cancel", label = "Cancel"}, {id = "apply", label = "Apply to source", variant = "primary"}}, {checkout = checkout, info = data})
		elseif kind == "remove" then
			local body = {c.note("Remove " .. checkout.path .. "? The source folder is not deleted."), c.note("Ignored files, caches (including node_modules), and files over 100 MB are NOT counted in source changes. They are deleted too. Unreturned commits are lost unless saved as a branch.", "warning")}
			append(body, info_body(data))
			local choices = {{id = "cancel", label = "Cancel"}}
			if data.commits and type(data.commits) == "table" and data.commits.count > 0 then table.insert(choices, {id = "save-remove", label = "Save branch, then remove", variant = "primary"}) end
			table.insert(choices, {id = "remove", label = "Remove", variant = "danger", disabled = type(data.error) == "string"})
			dialog(w, "remove", "Remove workspace: " .. checkout.name, body, choices, {checkout = checkout, info = data})
		else dialog(w, "changes", "Changes: " .. checkout.name, info_body(data), {{id = "cancel", label = "Close"}}) end
	end, if kind == "preview" then "preview" else "details")
end
local function submit(s: any, id: string)
	local w, d = s.workspaces, s.workspaces.dialog
	if not d then return end
	if id == "cancel" then if not w.busy then close(w) else w.dialog = nil end; return end
	if w.busy then return end
	if id == "save-remove" then
		local checkout, info = d.checkout, d.info
		form(s, "save-remove", checkout, nil); w.dialog.info = info
		return
	end
	local checkout, req = d.checkout, nil
	if id == "submit" then
		local text = d.field.text
		if d.kind == "new" then req = {action = "new", source = d.source, name = text}
		elseif d.kind == "fork" then req = payload(checkout, "fork"); req.branch = text
		else req = payload(checkout, d.kind); req.branch = text; if d.info then req.expected = d.info.token end end
	elseif id == "apply" or id == "remove" then req = payload(checkout, id); req.expected = d.info.token end
	if not req then return end
	operate(s, req, checkout, function(data)
		if req.action == "apply" then dialog(w, "result", "Apply result: " .. checkout.name, result_body(data), {{id = "cancel", label = "Close"}})
		else close(w); s.cx:toast("success", if req.action == "remove" or req.action == "save-remove" then "Workspace removed" elseif req.action == "branch" then "Commits saved as branch" else "Workspace created", req.name) end
	end)
end
local function choose(s: any, verb: string, key: string)
	local w = s.workspaces
	if verb == "refresh" then w.error = nil; w.cache = {}; M.refresh(s); return end
	if verb == "cancel" then close(w); return end
	if verb == "start" then operate(s, {action = "start"}, nil, function() close(w) end); return end
	if verb == "new" then form(s, "new", nil, key); return end
	if verb == "select" then w.selected = key; return end
	if verb == "agent" then s.cx:open("tern-projects://workspace?focus=" .. key); return end
	local checkout = target(w, key)
	if not checkout then return end
	if verb == "menu" then
		local choices = {}
		for _, item in {{"open", "Open new OMP", "play"}, {"changes", "Show source changes / commits", "search"}, {"fork", "Fork workspace", "branch"}, {"preview", "Preview apply to source", "arrow-up"}, {"branch", "Save commits as branch", "branch"}, {"remove", "Remove workspace", "trash"}} do
			if item[1] ~= "branch" or checkout.git then table.insert(choices, {id = item[1], label = item[2], icon = item[3]}) end
		end
		close(w); dialog(w, "menu", checkout.name, {}, choices, {checkout = checkout}); return
	end
	if verb == "open" then close(w); w.launch(s, checkout.path)
	elseif verb == "fork" or verb == "branch" then form(s, verb, checkout, nil)
	elseif verb == "changes" or verb == "preview" or verb == "remove" then
		local reason = if verb ~= "changes" then blocked(w, checkout, verb == "remove") else nil
		if reason then failure(s, reason); return end
		show(s, checkout, verb)
	end
end
function M.event(s: any, ev: any): boolean
	local w = s.workspaces
	if ev.ev == "action" and ev.act == "workspace-agents" then
		local ok, data = pcall(tern.json.decode, ev.value or "")
		if ok and type(data) == "table" then
			local became_visible = data.visible == true and not w.visible
			w.visible = data.visible == true
			w.agents = data.agents or {}
			if w.nonce and data.nonce == w.nonce and w.authorization then
				local authorized = w.authorization
				w.authorization = nil; w.nonce = nil
				authorized()
			end
			if became_visible and w.active then M.refresh(s) end
		end
		return true
	end
	if not w.active then return false end
	if w.dialog and w.dialog.field and (ev.ev == "edit" or ev.ev == "focus") and ev.id == "layer.workspace.form.name" then
		if ev.ev == "edit" then input.edit(w.dialog.field, ev); w.dialog.all = false end
		return true
	end
	if ev.ev == "action" and ev.act == "ws" then
		local verb, key = string.match(ev.value or "", "^([^:]+):(.*)$")
		if not verb then return true end
		key = fmt.unpct(key)
		if verb == "dialog" then
			local d = w.dialog
			if d and d.kind == "menu" then choose(s, key, d.checkout.name) else submit(s, key) end
		else choose(s, verb, key) end
		return true
	end
	if (ev.ev == "select" or ev.ev == "activate") and ev.id == "main.workspace" then
		local key = string.match(ev.item or "", "^main%.workspace%.(.+)$") or ev.item
		w.selected = key
		if ev.ev == "activate" and w.rows[key] then choose(s, w.rows[key].kind, w.rows[key].key) end
		return true
	end
	return false
end
function M.key(s: any, k: any): boolean
	local w, d = s.workspaces, s.workspaces.dialog
	if d then
		if k.name == "escape" then submit(s, "cancel")
		elseif w.busy then return true
		elseif k.name == "enter" then
			local b = d.buttons[if d.field then #d.buttons else d.focus]
			if b and not b.disabled then if d.kind == "menu" then choose(s, b.id, d.checkout.name) else submit(s, b.id) end end
		elseif k.name == "tab" or (not d.field and (k.name == "up" or k.name == "down" or k.name == "left" or k.name == "right")) then
			d.focus = (d.focus - 1 + (if k.shift or k.name == "up" or k.name == "left" then -1 else 1)) % #d.buttons + 1
		elseif d.field then local _, all = input.key(d.field, d.all, k, tern.runtime.os); d.all = all end
		return true
	end
	if k.name == "tab" or k.name == "/" then return false end
	if k.name == "r" and k.ctrl then choose(s, "refresh", ""); return true end
	local idx = table.find(w.order, w.selected) or 0
	if #w.order > 0 and (k.name == "down" or k.name == "up") then w.selected = w.order[math.clamp(idx + (if k.name == "down" then 1 else -1), 1, #w.order)]; return true end
	local row = w.rows[w.selected or ""]
	if row and k.name == "enter" then choose(s, row.kind, row.key); return true end
	if row and k.name == "f10" and k.shift and row.kind == "menu" then choose(s, "menu", row.key); return true end
	return false
end
function M.view(s: any): {any}
	local w, rows, order, keys = s.workspaces, {}, {}, {}
	local function row(key: string, label: string, detail: string?, kind: string, value: string, icon: string, depth: number)
		keys[key] = {kind = kind, key = value}; table.insert(order, key)
		table.insert(rows, ui.node("item", {key = key, label = string.rep("\u{00a0}\u{00a0}", depth) .. label, detail = detail, icon = icon, role = "tern-projects.workspace-row", title = label .. (if detail then "\n" .. detail else ""), actions = {click = act(kind, value)}}))
	end
	local nodes: {any} = {ui.el("div", {key = "wsbar", class = "tp-bar"}, {c.note("OVNFS · " .. w.state), c.grow(), c.button("Add project", "create", {size = "sm", icon = "plus"}), c.icon_button("redo", act("refresh"), "Refresh workspaces", {size = "sm"})})}
	if w.state ~= "running" then
		local text = if w.state == "loading" then "Checking OVNFS…" elseif w.state == "missing" then "OVNFS is not installed" elseif w.state == "stopped" then "OVNFS is not running" else "OVNFS error"
		table.insert(nodes, c.banner("ws-status", if w.state == "error" or w.state == "missing" then "error" else "info", nil, text .. (if w.status_error then ": " .. fmt.error(w.status_error) else ""), if w.state == "stopped" then {c.button("Start", act("start"), {size = "sm", variant = "primary"})} else nil))
	end
	if w.external_busy or w.busy then table.insert(nodes, c.banner("ws-pending", "info", nil, "A workspace operation is in progress. It continues across plugin reloads; no operation will be replayed.", nil, true)) end
	if w.error then table.insert(nodes, c.banner("ws-error", "error", "warn", w.error)) end
	local agents = grouped_agents(w)
	for _, project in w.projects do
		table.insert(rows, c.header("project:" .. tostring(project.id), project.name))
		for _, folder in project.folders or {} do
			local prefix = tostring(project.id) .. ":" .. folder .. ":"
			row(prefix .. "folder", fmt.path(folder), "New workspace", "new", folder, "folder-plus", 0)
			local seen = {}
			local function checkout_row(checkout: any, depth: number)
				if seen[checkout.name] then return end
				seen[checkout.name] = true
				local cached = w.cache[checkout.name]
				local info = cached and cached.info
				local count = if info then tostring(#(info.changes or {})) else "…"
				local description = count .. " source changes"
				if info and info.commits and type(info.commits) == "table" then description ..= " · " .. tostring(info.commits.count) .. " commits not brought back" end
				if cached and (cached.error or (info and type(info.error) == "string")) then description ..= " · details unavailable" end
				description ..= " · " .. string.sub(checkout.touched, 1, 19):gsub("T", " ")
				row(prefix .. checkout.name, checkout.name, description, "menu", checkout.name, if depth > 1 then "branch" else "folder-open", depth)
				for _, agent in agents[checkout.name] or {} do
					local labels = {working = "工作中 / Working", waiting_input = "等你回覆 / Waiting for you", idle = "閒置 / Idle", done = "完成 / Done", failed = "失敗 / Failed", exited = "閒置 / Idle"}
					row(prefix .. "agent:" .. tostring(agent.pane), labels[agent.state] or labels.idle, agent.title, "agent", tostring(agent.pane), if agent.state == "working" then "play" elseif agent.state == "waiting_input" then "bell" elseif agent.state == "failed" then "warn" else "circle", depth + 1)
				end
				for _, child in w.checkouts do if child.source == folder and child.parent_name == checkout.name then checkout_row(child, depth + 1) end end
			end
			for _, checkout in w.checkouts do if checkout.source == folder and not checkout.parent_name then checkout_row(checkout, 1) end end
			for _, checkout in w.checkouts do if checkout.source == folder then checkout_row(checkout, 1) end end
		end
	end
	if #w.projects == 0 then table.insert(rows, c.empty("ws-empty", "folder-plus", "Add a project to see its workspaces", "Uses the same curated Mine projects and folders as Projects. Non-Git folders work too.")) end
	w.rows, w.order = keys, order
	table.insert(nodes, ui.node("list", {key = "workspace", selected = w.selected, role = "tern-projects.rows"}, rows))
	return nodes
end
function M.layer(s: any): any
	local w, d = s.workspaces, s.workspaces.dialog
	if not d then return nil end
	local body = table.clone(d.body)
	if d.field then
		table.insert(body, c.label(if d.kind == "branch" or d.kind == "save-remove" then "New branch name" else "Workspace name"))
		table.insert(body, ui.el("div", {key = "form"}, {ui.node("input", {key = "name", text = d.field.text, cursor = tf.utf16(d.field), anchor = if d.all then 0 else nil, placeholder = if d.kind == "branch" or d.kind == "save-remove" then "saved-work" else "workspace-name", aria = "Workspace or branch name"})}))
	end
	if w.busy then table.insert(body, c.note("Working… The operation continues if this panel closes or the plugin reloads.")) end
	if d.error then table.insert(body, c.banner("error", "error", "warn", d.error)) end
	local choices = {}
	for i, b in d.buttons do table.insert(choices, c.button(b.label, act("dialog", b.id), {key = b.id, variant = b.variant, icon = b.icon, focused = d.focus == i, disabled = b.disabled or (w.busy and b.id ~= "cancel")})) end
	if d.kind == "menu" then
		return ui.node("overlay", {key = "workspace", modal = true, size = "sm", head = d.title, role = "tern-projects.dialog"}, {ui.el("div", {class = "tp-ws-menu"}, choices), c.footer({c.button("Cancel", act("dialog", "cancel"), {variant = "ghost"})})})
	end
	return ui.node("overlay", {key = "workspace", modal = true, size = if d.kind == "remove" then "md" else "sm", head = d.title, role = "tern-projects.dialog"}, {ui.el("div", {class = "tp-form tp-ws-form"}, body), c.footer(choices)})
end
return M
