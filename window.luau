--!strict
-- tern-projects window half: commands, toggle logic, and guarded launch routes.
-- iOS has no tern.process; skip setup on that platform.
if tern.runtime.os == "ios" then
	return
end

local fmt = require("./lib/fmt")
local cli = require("./lib/cli")
local unpct = fmt.unpct
local pct = fmt.pct

local KIND = "tern-projects.panel"
local WIDTH = 44

local LAUNCH_CLAIM_LIFETIME = 10 -- seconds; must match the panel's one-shot claim lifetime
-- Per-pane state for toggle tracking.
local last_mode: { [number]: string } = {}
local prev_focus: { [number]: number } = {}
-- Chat previews: one read-only canvas per Projects panel, showing only its newest request.
local previews: { [number]: number } = {}
local preview_latest: { [number]: number } = {}
local preview_counter = 0
local PREVIEW_ABOUT = "Read-only preview of a chat from the Projects panel. Selecting another chat there switches it; closing this pane stops previewing."

-- Look a pane up through the window's pane list: cx.session:pane(id) can return nil for a live pane.
local function find_pane(cx: SessionContext, id: number?): PaneInfo?
	if id == nil then return nil end
	for _, p in cx.session:panes() do
		if p.pane == id then return p end
	end
	return nil
end

-- Toggle or open the projects panel in `mode` for the current tab.
local function toggle(cx: SessionContext, mode: string)
	local f = cx.session:focused()
	local fi = find_pane(cx, f)
	local tab = fi ~= nil and fi.tab or nil
	if tab == nil then
		return
	end

	-- Find an existing panel pane on this tab.
	local panel: number? = nil
	for _, p in cx.session:panes() do
		if p.block == KIND and p.tab == tab then
			panel = p.pane
			break
		end
	end

	if panel ~= nil then
		if f == panel and last_mode[panel] == mode then
			-- Same key again while panel is focused: close it.
			cx.layout:close(panel)
			local pf = prev_focus[panel]
			if pf ~= nil then
				-- Try to refocus the previous pane.
				for _, p in cx.session:panes() do
					if p.pane == pf then
						cx.layout:focus(pf)
						break
					end
				end
			end
			return
		end
		-- Retarget the existing panel to the new mode/cwd.
		local new_cwd = (f ~= panel and fi ~= nil) and (fi.cwd or "") or ""
		cx.session:event(panel, {
			ev = "action",
			id = "main",
			act = "open=" .. mode .. ":" .. new_cwd,
			value = mode .. ":" .. new_cwd,
		})
		cx.layout:focus(panel)
		last_mode[panel] = mode
		if f ~= panel then
			prev_focus[panel] = f :: number
		end
		return
	end

	-- Create a new panel.
	pcall(tern.fs.remove, tern.plugin.data .. "/panel-cols")
	local new_cwd = fi ~= nil and (fi.cwd or "") or ""
	local new_pane = cx.layout:split(f :: number, "left", { block = KIND, args = { mode, new_cwd } })
	if new_pane == nil then
		-- Tern 0.9.5 cannot resolve some live pane ids passed back to split; open beside the focused pane instead.
		new_pane = cx:new_block(KIND, { mode, new_cwd }, "split")
	end
	if new_pane == nil then
		cx:toast("error", "Projects block unavailable", "tern plugin list")
		return
	end
	last_mode[new_pane] = mode
	prev_focus[new_pane] = f :: number

	-- After the block reports its width, resize the split.
	tern.timer(400, function(cx2: SessionContext)
		local ok, data = pcall(tern.fs.read, tern.plugin.data .. "/panel-cols")
		if not ok then
			return
		end
		local c = tonumber(data)
		if c ~= nil and c > WIDTH + 2 then
			cx2.layout:resize(new_pane :: number, "right", -(c - WIDTH))
		end
	end)
end

-- Canvas titles hold at most 80 characters.
local function preview_title(title: string): string
	local n = utf8.len(title)
	if n ~= nil and n <= 80 then return title end
	local cut = utf8.offset(title, 80)
	return if cut ~= nil then string.sub(title, 1, cut - 1) .. "…" else "Chat preview"
end

-- Open beside the pane the panel was opened from, so the preview sits between the list and the work.
local function preview_target(cx: any, panel: number, tab: number): (number, Dir)
	local fallback: number? = nil
	for _, p in cx.session:panes() do
		if p.tab == tab and p.pane ~= panel and p.pane ~= previews[panel] then
			if p.pane == prev_focus[panel] then return p.pane, "left" end
			if fallback == nil then fallback = p.pane end
		end
	end
	if fallback ~= nil then return fallback, "left" end
	return panel, "right"
end

-- Pane ids alone can go stale (`tern close` sends no pane_closed); confirm the pane is still one of our previews.
local function is_preview(cx: any, pane: number?): boolean
	if pane == nil then return false end
	local info = cx.canvas:get(pane)
	return info ~= nil and info.owner == tern.plugin.id and info.about == PREVIEW_ABOUT
end

-- A reload restarts every panel without its preview; close previews left from before it.
tern.timer(0, function(cx: any?)
	if cx == nil then return end
	for _, info in cx.canvas:list() do
		if info.owner == tern.plugin.id and info.about == PREVIEW_ABOUT then
			pcall(function() cx.layout:close(info.pane) end)
		end
	end
end)

-- Chat layout: your messages on the right, the agent's on the left.
local function preview_view(data: any): any
	local ui = tern.ui
	local label = if type(data.label) == "string" then data.label else "Agent"
	local kids: { any } = { ui.el("div", { key = "meta", class = "tp-chat-meta", text = label .. " · " .. tostring(data.cwd or "") }) }
	local hidden = tonumber(data.hidden) or 0
	if hidden > 0 then
		table.insert(kids, ui.el("div", { key = "hidden", class = "tp-chat-meta", text = string.format("%d earlier message%s omitted", hidden, if hidden == 1 then "" else "s") }))
	end
	for i, turn in data.turns do
		local user = turn.role == "user"
		table.insert(kids, ui.el("div", { key = "t" .. tostring(i), class = "tp-chat-msg " .. (if user then "user" else "agent") }, {
			ui.el("div", { class = "tp-chat-who", text = if user then "You" else label }),
			ui.md(turn.markdown),
		}))
	end
	if #data.turns == 0 then table.insert(kids, ui.el("div", { key = "empty", class = "tp-chat-meta", text = "No messages to show." })) end
	return ui.el("div", { class = "tp-chat" }, kids)
end

local function error_view(err: string): any
	local ui = tern.ui
	return ui.el("div", { class = "tp-chat" }, {
		ui.el("div", { class = "tp-chat-meta", text = "Cannot preview this chat." }),
		ui.el("div", { class = "tp-chat-msg agent", text = fmt.error(err) }),
	})
end

local function notify_panel(cx: any, panel: number, act: string, value: string?)
	if find_pane(cx, panel) ~= nil then
		pcall(function() cx.session:event(panel, { ev = "action", id = "main", act = act, value = value }) end)
	end
end

local function stop_following(cx: any, panel: number)
	previews[panel] = nil
	preview_latest[panel] = nil
	notify_panel(cx, panel, "preview-closed")
end

-- `follow` updates come from selection changes: they never reopen a preview the user closed.
-- The panel learns which chat is shown only from here, so a dropped update is retried.
local function show_preview(cx: any, panel: number, uid: string, title: string, view: any, follow: boolean)
	local origin = find_pane(cx, panel)
	if origin == nil then return end
	local current = previews[panel]
	if current ~= nil and not is_preview(cx, current) then current = nil end
	if current ~= nil then
		local ok, err = pcall(function() cx.canvas:set(current, { title = preview_title(title), view = view }) end)
		if ok then previews[panel] = current; notify_panel(cx, panel, "preview-shown", uid); return end
		tern.log.error("Cannot update chat preview: " .. tostring(err))
	end
	if follow then stop_following(cx, panel); return end
	local target, dir = preview_target(cx, panel, origin.tab)
	local ok, pane, err = pcall(function()
		return cx.canvas:open({ title = preview_title(title), view = view, about = PREVIEW_ABOUT, target = target, dir = dir, ratio = 0.5, focus = false })
	end)
	if not ok or pane == nil then
		cx:toast("error", "Cannot open chat preview", tostring(if ok then err else pane))
		return
	end
	previews[panel] = pane
	notify_panel(cx, panel, "preview-shown", uid)
end

local function request_preview(panel: number, uid: string, follow: boolean)
	preview_counter += 1
	local seq = preview_counter
	preview_latest[panel] = seq
	cli.request({ op = "transcript", uid = uid }, function(data: any?, err: string?)
		if preview_latest[panel] ~= seq then return end
		-- The backend reply carries no window context; take one on the next tick.
		tern.timer(0, function(cx: any?)
			if cx == nil or preview_latest[panel] ~= seq then return end
			if err ~= nil or type(data) ~= "table" or type(data.turns) ~= "table" then
				show_preview(cx, panel, uid, "Chat preview", error_view(err or "The backend returned no transcript."), follow)
			else
				show_preview(cx, panel, uid, if type(data.title) == "string" and data.title ~= "" then data.title else "Chat preview", preview_view(data), follow)
			end
		end)
	end)
end

-- User overrides take precedence over plugin defaults. Migrate only exact old actions.
local function migrate_keybinds(cx: SessionContext)
	local replacements = {
		["plugin.tern-sessions.sessions"] = "plugin.tern-projects.projects",
		["plugin.tern-sessions.search"] = "plugin.tern-projects.search",
	}
	for chord, value in cx.settings:keybinds() do
		if type(value) == "string" then
			local replacement = replacements[value]
			if replacement ~= nil then cx.settings:bind(chord, replacement) end
		else
			local changed = false
			local actions: { string } = {}
			for _, action in value do
				local replacement = replacements[action]
				table.insert(actions, replacement or action)
				if replacement ~= nil then changed = true end
			end
			if changed then cx.settings:bind(chord, actions) end
		end
	end
end

-- The installer reloads the plugin and can close its panel. Deliver from the
-- window instead, acknowledging separately so updater preferences stay host-owned.
local function update_toast(cx: SessionContext, remaining: number)
	local ok, record = pcall(tern.kv.get, "plugin-updates:v1")
	if not ok or type(record) ~= "table" then return end
	if record.pending then
		if remaining > 0 then
			tern.timer(2000, function(next_cx: SessionContext)
				update_toast(next_cx, remaining - 1)
			end)
		end
		return
	end
	if record.failure then return end
	local version = record.completed_version
	if type(version) ~= "string" then return end
	local read, acknowledged = pcall(tern.kv.get, "plugin-update-toast:v1")
	if not read or acknowledged == version then return end
	-- Record delivery before showing to avoid replay on subsequent reloads.
	local saved, err = pcall(tern.kv.set, "plugin-update-toast:v1", version)
	if not saved then
		tern.log.error("Cannot acknowledge plugin update toast: " .. tostring(err))
		return
	end
	cx:toast("success", "Updated!", "Projects " .. version)
end

tern.on("window_start", function(cx: SessionContext)
	migrate_keybinds(cx)
end)

-- Module load also runs on plugin reload; window_start may already have fired.
-- Poll only while an installation is pending, for at most 130 seconds.
tern.timer(500, function(cx: SessionContext)
	update_toast(cx, 65)
end)

tern.command({
	id = "projects",
	title = "Projects",
	icon = "folder",
	keys = { if tern.runtime.os == "macos" then "cmd+alt+s" else "ctrl+alt+s" },
	run = function(cx)
		migrate_keybinds(cx)
		toggle(cx, "projects")
	end,
})

tern.command({
	id = "search",
	title = "Projects: Search",
	icon = "search",
	keys = { if tern.runtime.os == "macos" then "ctrl+alt+cmd+s" else "ctrl+alt+shift+s" },
	run = function(cx)
		migrate_keybinds(cx)
		toggle(cx, "search")
	end,
})

tern.command({
	id = "settings",
	title = "Projects: Settings",
	icon = "settings",
	run = function(cx) toggle(cx, "settings") end,
})

-- Clean up tracking state when a pane closes.
tern.on("pane_closed", function(ev: any, cx: any)
	last_mode[ev.pane] = nil
	prev_focus[ev.pane] = nil
	-- A closed preview stops following the panel's selection.
	for panel, pane in previews do
		if pane == ev.pane then stop_following(cx, panel) end
	end
	-- A closed panel takes its preview with it.
	local own = previews[ev.pane]
	previews[ev.pane] = nil
	preview_latest[ev.pane] = nil
	if own ~= nil and cx ~= nil and is_preview(cx, own) then
		pcall(function() cx.layout:close(own) end)
	end
end)

local function publish_shortcuts(cx: SessionContext, pane: number)
	local ok, keymap = pcall(function() return cx.actions:keys() end)
	local bindings: {[string]: {string}} = {projects = {}, search = {}, settings = {}}
	if ok then
		for chord, actions in keymap do
			for _, id in actions do
				local name = string.match(id, "^plugin%.tern%-projects%.([a-z]+)$")
				if name and bindings[name] then table.insert(bindings[name], chord) end
			end
		end
		for _, chords in bindings do table.sort(chords) end
	end
	cx.session:event(pane, {
		ev = "action", id = "main", act = "shortcut-state",
		value = tern.json.encode(if ok then {bindings = bindings} else {error = tostring(keymap)}),
	})
end

-- Host-generated commands must execute only on the originating local window.
tern.route.link(function(link: any, cx: SessionContext)
	local route, q = string.match(link.url, "^tern%-projects://([a-z]+)%?(.*)$")
	if route ~= "resume" and route ~= "launch" and route ~= "preview" and route ~= "shortcuts" and route ~= "keyboard" and route ~= "keyconfig" then return nil end
	if link.pane == nil then return { handled = true } end
	local origin = find_pane(cx, link.pane)
	if route == "shortcuts" or route == "keyboard" or route == "keyconfig" then
		if origin == nil or origin.block ~= KIND or cx.session:focused() ~= link.pane then
			return { handled = true }
		end
		if route == "shortcuts" then
			publish_shortcuts(cx, link.pane)
		elseif route == "keyconfig" then
			cx:command("open_config")
		else
			cx:command("preferences")
			cx:toast("info", "Customize Projects shortcuts", "Choose Keyboard and search for Projects.")
		end
		return { handled = true }
	end
	if route == "preview" then
		-- Links are credited to the focused pane, so an update sent after focus left the panel is
		-- dropped here; the panel resends it, as it only trusts the chat the window says it showed.
		if origin == nil or origin.block ~= KIND or cx.session:focused() ~= link.pane then return { handled = true } end
		local follow = string.match(q, "follow=1") ~= nil
		-- The transcript and its index live on this machine only.
		if cx.hosts:current().kind ~= "local" then
			cx:toast("error", "Cannot preview a chat on a remote host", "Switch to the local host first.")
			return { handled = true }
		end
		local uid = unpct(string.match(q, "uid=([^&]*)") or "")
		if uid ~= "" then request_preview(link.pane, uid, follow) end
		return { handled = true }
	end
	local key = ""
	local pending: any = nil
	if route == "launch" then
		local nonce = unpct(string.match(q, "n=([^&]*)") or "")
		if nonce == "" then return { handled = true } end
		key = "launch:" .. nonce
		local ok, claim = pcall(tern.kv.get, key)
		if not ok or type(claim) ~= "table" then return { handled = true } end
		pending = claim
	end
	-- A claim never substitutes for a live Projects panel in this window. In particular,
	-- a link credited to a newly focused pane cannot authorize a different pane's launch.
	if origin == nil or origin.block ~= KIND or (pending and pending.pane ~= link.pane) then
		if pending then cx:toast("error", "Chat not started", "Focus the Projects panel and try again.") end
		return { handled = true }
	end
	if cx.session:focused() ~= link.pane then
		if pending then cx:toast("error", "Chat not started", "Focus the Projects panel and try again.") end
		return { handled = true }
	end
	if cx.hosts:current().kind ~= "local" then
		cx:toast("error", "Cannot launch a local chat on a remote host", "Switch to the local host first.")
		return { handled = true }
	end
	local cwd = unpct(string.match(q, "cwd=([^&]*)") or "")
	local cmd = unpct(string.match(q, "cmd=([^&]*)") or "")
	if cmd == "" or cwd == "" or string.find(cwd, "[%z\r\n]") or string.find(cmd, "[%z\r\n]") then
		cx:toast("error", "Invalid chat launch", "The working directory or command is missing or invalid.")
		return { handled = true }
	end
	if pending then
		local created = pending.created
		local age = if type(created) == "number" then os.time() - created else LAUNCH_CLAIM_LIFETIME
		if age < 0 or age >= LAUNCH_CLAIM_LIFETIME or pending.cwd ~= cwd or pending.command ~= cmd then
			return { handled = true }
		end
		-- Only the matching, authorized window consumes this nonce. Reject replay even
		-- when tab creation fails, and fail closed if removing the claim fails.
		local consumed = pcall(tern.kv.set, key, nil)
		if not consumed then
			cx:toast("error", "Chat not started", "Cannot consume the chat launch authorization. Try again.")
			return { handled = true }
		end
	end
	local ok, pane = pcall(function()
		return cx.layout:new_tab({ cwd = cwd, command = cmd })
	end)
	if not ok or pane == nil then
		cx:toast("error", "Could not open chat tab", if ok then "Tern did not create a tab." else tostring(pane))
	end
	return { handled = true }
end)

-- Suppress unused warning for pct (used by blocks/panel.luau via lib/fmt.luau).
local _ = pct
