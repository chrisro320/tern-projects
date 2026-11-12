--!strict
-- Window-only bridge. Native Tern state, never terminal scraping, prompts or OMP configuration.
local fmt = require("./fmt")
local M = {}
local KEY = "workspace-results:v1"
local known: {[string]: any} = {}
local loaded = false

local function results(): any
	local ok, value = pcall(tern.kv.get, KEY)
	if not ok then error("Cannot read workspace agent results: " .. tostring(value)) end
	return if type(value) == "table" then value else {}
end
local function panes(cx: any): any
	local out = {}
	for _, p in cx.session:panes() do out[tostring(p.pane)] = p end
	return out
end
function M.snapshot(cx: any): any
	local marks, visible, rows = results(), panes(cx), {}
	for _, agent in cx.agents:list() do
		local key = tostring(agent.pane)
		local row = {pane = agent.pane, cwd = agent.cwd, state = agent.state, live = agent.state ~= "exited", title = "Agent"}
		local p = visible[key]
		if p then row.title = p.title or "Agent" end
		if agent.state ~= "working" and agent.state ~= "waiting_input" and marks[key] then row.state = marks[key].state end
		known[key] = row
		rows[key] = row
	end
	-- Tern can retain an exited agent pane after removing it from agents:list().
	-- Without a recorded finish event its result is unknown, never inferred from old terminal text.
	for key, pane in visible do
		if pane.kind == "agent" and not rows[key] and not marks[key] then
			rows[key] = {pane = pane.pane, cwd = pane.cwd, state = "idle", live = pane.exited == nil, title = pane.title or "Agent"}
			known[key] = rows[key]
		end
	end
	for key, mark in marks do
		if not rows[key] then
			rows[key] = {pane = mark.pane, cwd = mark.cwd, state = mark.state, live = false, title = mark.title or "Agent"}
			known[key] = rows[key]
		end
	end
	local list = {}
	for _, row in rows do table.insert(list, row) end
	table.sort(list, function(a, b) return a.pane < b.pane end)
	return list
end
local function publish(cx: any)
	local rows = M.snapshot(cx)
	for _, p in cx.session:panes() do
		if p.block == "tern-projects.panel" then
			local focused = panes(cx)[tostring(cx.session:focused())]
			local payload = tern.json.encode({agents = rows, visible = focused ~= nil and focused.tab == p.tab})
			cx.session:event(p.pane, {ev = "action", id = "main", act = "workspace-agents", value = payload})
		end
	end
end
function M.start()
	if loaded then return end
	loaded = true
	tern.on("agent_state", function(ev: any, cx: any)
		if not cx then return end
		if ev.new == "working" or ev.new == "waiting_input" then
			local marks, key = results(), tostring(ev.pane)
			if marks[key] then marks[key] = nil; tern.kv.set(KEY, marks) end
		end
		publish(cx)
	end)
	tern.on("agent_finished", function(ev: any, cx: any)
		if not cx then return end
		local key = tostring(ev.pane)
		local row = known[key]
		if not row then M.snapshot(cx); row = known[key] end
		if row then
			local marks = results()
			local state = if ev.result == "failed" then "failed" elseif ev.result == "done" or ev.result == "exited" then "done" else "idle"
			if ev.result == "closed" and marks[key] then state = marks[key].state end
			-- An exited process is only failed when Tern reports its nonzero status.
			for _, p in cx.session:panes() do if p.pane == ev.pane and type(p.exited) == "number" and p.exited ~= 0 then state = "failed" end end
			marks[key] = {pane = ev.pane, cwd = row.cwd, title = row.title, state = state}
			tern.kv.set(KEY, marks)
		end
		publish(cx)
	end)
	tern.on("focus", function(ev: any, cx: any)
		if not cx then return end
		local marks, changed = results(), false
		-- Seeing a tab acknowledges its finished marks, not only its focused split.
		for _, p in cx.session:panes() do
			local key = tostring(p.pane)
			if p.tab == ev.tab and marks[key] and marks[key].state ~= "idle" then marks[key].state = "idle"; changed = true end
		end
		if changed then tern.kv.set(KEY, marks) end
		publish(cx)
	end)
	tern.on("pane_closed", function(_ev: any, cx: any) if cx then publish(cx) end end)
	tern.timer(300, function(cx: any) if cx then publish(cx) end end)
	tern.route.link(function(link: any, cx: any)
		local q = string.match(link.url, "^tern%-projects://workspace%?(.*)$")
		if not q or not link.pane then return nil end
		local origin = panes(cx)[tostring(link.pane)]
		if not origin or origin.block ~= "tern-projects.panel" or cx.hosts:current().kind ~= "local" then return {handled = true} end
		local focus = tonumber(string.match(q, "focus=(%d+)"))
		if focus then
			for _, row in M.snapshot(cx) do
				if row.pane == focus then
					if panes(cx)[tostring(focus)] then cx.layout:focus(focus)
					else cx:toast("info", "Agent pane is closed", "Its last recorded result is retained in Workspaces.") end
					break
				end
			end
		else
			local nonce = fmt.unpct(string.match(q, "nonce=([^&]*)") or "")
			local focused = panes(cx)[tostring(cx.session:focused())]
			cx.session:event(link.pane, {ev = "action", id = "main", act = "workspace-agents", value = tern.json.encode({agents = M.snapshot(cx), nonce = nonce, visible = focused ~= nil and focused.tab == origin.tab})})
		end
		return {handled = true}
	end)
end
return M
