# tern-projects

A curated project sidebar and unified agent history search for [Tern](https://stencil.so/tern).

Bring order to your AI coding sessions across **OMP, Claude Code, Codex, Pi, OpenCode, and Cursor**.

![tern-projects sidebar overview](docs/screenshots/showcase-overview.png)

---

## Quickstart

Run this inside Tern:

```sh
tern plugin install github.com/thegeneralist01/tern-projects
```

**Toggle the sidebar:**
- **macOS:** `⌘ ⌥ S`
- **Windows / Linux:** `Ctrl + Alt + S`

*(Or open **Projects** from the Tern command palette).*

Tern fetches the plugin, and the background engine builds automatically on first load. Rust/Cargo and your platform's native C build tools are required; no manual compile step is needed.

Cargo discovery checks absolute entries in Tern's host `PATH` first, then `$CARGO_HOME/bin` (or `~/.cargo/bin`) and common Unix installation locations, including Homebrew. The build environment includes the resolved Cargo directory so `rustc` and sibling tools remain available even when the GUI host has a limited `PATH`.

On macOS, install Apple developer tools (`xcode-select --install` if needed) or select your Xcode installation. Automatic builds use the SDK selected by `xcrun --sdk macosx` and Apple's compiler/linker, rather than mixing an unrelated `cc` from `PATH` with a different SDK.

### Updates

Projects checks the official GitHub repository at startup when its last check is at least 6 hours old, then every 6 hours while Tern is running. "Startup" means the Tern daemon loading the plugin (for example after a reboot, quitting Tern, or a plugin reload); opening the Projects panel does not check. Checks compare stable versions in `plugin.toml`. Disable **Automatic checks**, or use **Check now**, under **Settings → Plugin updates**.

By default, installation requires manual approval: when a newer version is available, choose **Review…** and explicitly confirm **Install update**. You can also opt in to **Automatic installation** under Settings → Plugin updates (Off by default, requires Automatic checks). When enabled, newly checked official versions install without review. Enabling it while an update is available installs it immediately; re-enabling automatic checks likewise. Automatic installation makes at most one attempt per version; if an automatic installation fails, it is not retried automatically for the same version, and **Review…** remains available to retry or review manually.

When installing, Tern installs the latest official `main` branch and reloads the plugin; open Projects panes may close. The version shown is the last checked version, not a pinned download.

Successful in-app updates show an **Updated!** toast with the installed Projects version, including after the plugin reloads and when the Projects panel is closed. Failed or unconfirmed installations do not show a success toast.

For a manual update, run:
```sh
tern plugin install github.com/thegeneralist01/tern-projects --force
```

**Copy command** in Plugin updates copies that same command, including when a network check or installation fails. Tern's installer replaces plugin files, not your project library or plugin data; the history index remains a rebuildable cache. Tern refuses to overwrite linked development checkouts, so update the linked checkout instead.

In-app installation looks for Tern in the host's `PATH`, then standard user-local CLI and macOS application locations. If an older installation reports that it cannot start the Tern installer, run the manual command above from your terminal once to get the corrected updater.

The in-app installer refuses to run while permanent chat deletion is active, and deletion cannot start during installation. Wait for deletion to finish before running the manual command too.

---

## What it does

If you use multiple AI coding agents, your sessions are scattered across hidden SQLite databases and JSONL files. `tern-projects` unifies them into a fast, native sidebar:

- 📁 **Curated "My Projects" & Multi-Folder Workspaces** — Real projects rarely live in a single directory. Group an app, its backend API, shared libraries, and documentation into one named project with a custom icon.
- 🎯 **Primary Launch Directories** — Pick one folder as **Primary** (where fresh agent sessions spawn), while additional directories are automatically supplied via `--add-dir` to harnesses that support multi-folder workspaces (OMP, Claude Code, Codex).
- 🔍 **Instant Full-Text Search** — FTS5-powered search across all your past sessions. Filter by **Worktree**, **Repository**, or **All history** with live keyword highlighting.
- 🚀 **Fresh Chat Launching** — Press `⌘N` (`Ctrl+N`) to launch a new chat in your preferred CLI (`omp`, `claude`, `codex`, `pi`, `opencode`, or `cursor`).
- 📌 **Global Pins & Recents** — Keep critical threads pinned to the top of your sidebar. Recents keeps your 15 most recent chats one click away; by default it shows **This folder** — chats started in the panel's folder (the same matching as Search's Worktree scope) — and **All** switches to every folder. The choice is remembered.
- 📂 **Follows Your Terminal** — The panel's folder (used by **New chat**, Recents' **This folder** and Search's **Worktree** / **Repository**) follows the terminal or agent you last focused in the same tab, like Tern's Files pane: `cd` there, or click another terminal, and the panel updates without reopening. Open dialogs and the current page stay; **Refresh** reads the folder again.
- 👁️ **Read-only Chat Preview** — Select an OMP or Claude Code chat and choose **Preview** (or press `Space` in Projects) to read it in a drawer inside the panel without starting the agent: your messages on the right, the agent's on the left, tool calls condensed to one line, the newest part of long chats. The drawer follows your selection; `Esc`, `Space` or its close button closes it.
- 🗄️ **Local Archiving & Safe Deletion** — Archive threads to hide them without losing data, or permanently delete sessions via verified native CLI calls.
- **OVNFS Workspaces** — A Workspaces tab in the existing Projects panel: curated project → folder → checkout/fork → native Tern agents. Create, fork, open a fresh OMP, preview/apply source changes, preserve commits as a new branch, or explicitly remove a checkout.

Changing a project's name or source folders does not discard its existing indexed chats. When source folders change, existing automatic memberships (including archived chats) are retained in the durable library; project lists and scoped search keep using them after an index rebuild. New chats still follow the configured folders, so reusing an old path does not attach unrelated new chats. Explicit **Move to project** and **No project** choices take precedence. Original transcripts and their recorded working directories are not rewritten.

For chats already hidden by a folder change made before this fix, find them in **All history** and use **Move to project** to restore their association.

![tern-projects details, menus, and search results](docs/screenshots/showcase-details.png)

---
## OVNFS Workspaces

Install [OVNFS](https://github.com/stencil-hq/ovnfs) on the host, open **Projects → Workspaces**, and use **Add project** to choose one or more source folders (Git is optional). Click a folder for **New workspace**, or a checkout for its actions. This uses Projects' existing **Mine** library, not a second project list. Names are globally unique, start with a lowercase letter or number, and contain at most 64 lowercase letters, numbers, dots, underscores or hyphens.

Existing checkouts whose source is not in any Mine project appear under **Not in a project**, grouped by source folder, even when you have no projects. Their source changes, commits, agents and guarded actions work just like assigned workspaces. **Add as project** opens the project editor with the source folder and its basename filled in; you can edit either before saving. Both this button and the Workspaces header's **Add project** keep you in Workspaces on save or cancel. Saved projects are selected and expanded, and matching checkouts move under them. Workspace labels use the same English-only wording as the rest of Projects.
Unassigned groups appear only after the Mine library and source-root lookup have succeeded; while membership is unknown the tab shows loading or its error instead of offering a duplicate project. An unavailable curated folder keeps checkouts whose source exactly matches its stored path, shows the resolution error, and retries when visible. Use the arrow keys to focus **Add as project**, then Enter to open it.

For a curated subfolder inside a Git repository, **New workspace** shows both the project folder and the actual repository-wide **capture / apply target** before creation. The resulting checkouts stay listed under that project folder. Tab moves from the name field to Cancel and then Create; Enter activates the focused button, or the primary action only while the field is focused.

The tab checks OVNFS every two seconds while open. Missing binary, stopped daemon and command errors are distinct; only the explicit **Start** button starts the default daemon. `OVNFS_STATE` and `OVNFS_MOUNT` are inherited. At most three management requests run concurrently. Source-change counts come from `ovnfs diff`, **not** its `dirty` flag, and are refreshed after touched/pid changes or plugin operations, including snapshots, forks and daemon restarts.
Routine library refreshes (including the panel's 120-second refresh) preserve open workspace dialogs, drafts and confirmations; leaving Workspaces closes them.

Agent states come from Tern, including agents launched outside Projects. Cwds and checkout paths are compared after resolving symlinks and platform separators. If a cwd no longer resolves but is lexically beneath the checkout's raw or resolved path, that agent stays grouped there and still blocks the operation; unrelated unresolvable cwds do not disable management. Click a state row to reveal its pane. Finished results are recorded only from Tern's `agent_finished` events in plugin KV, retained across reopen/reload until the agent restarts or its tab is viewed (including a tab already shown at completion); unknown results are idle. Waiting/completion notifications use Tern's existing notifications, without duplicate plugin toasts. **Open new OMP** uses the existing verified fresh-chat launch path, never resumes a conversation and never submits a prompt.

**Apply** first shows a dry-run preview and target folder, then requires confirmation. Results separate applied/merged files, conflict markers, and files left untouched. Exit code 1 with conflict JSON is a normal partial-merge result, not a retry. Source-only edits are retained. Working or waiting agents block Apply; any live agent blocks removal. Revalidated checkout identities and confirmation tokens reject changed/reused workspaces. An OS-held backend guard survives plugin reloads: the tab re-reads state, blocks concurrent mutations and never automatically replays an operation.

Queued mutations require the confirmed checkout in a fresh successful OVNFS listing when their request slot opens. After slow listing/path authorization finishes, a second native agent snapshot is checked immediately before sending the mutation. New cwds that were not resolved during preparation require a review/retry rather than a stale-path assumption. Saving a branch before removal is a separate stage; removal repeats both authorization and the final snapshot after saving. Failed listings never stand in for an empty agent list. Git and OVNFS children discard inherited Git repository/index/object/ref-selection overrides, so a launching shell cannot redirect these checks to another repository.

The commit badge compares checkout HEAD with the source's current HEAD (`rev-list --count <source-tip>..HEAD`). An unborn source has an empty base, so all checkout commits are counted. When checkout HEAD is unborn, surviving local refs are counted instead, deduplicating shared history and excluding the source tip; only an empty ref graph reports zero. Unreadable refs/objects or Git metadata block removal. Click **Show source changes / commits** for the newest 25 titles. Plain Apply copies working-tree changes, **not commits**. **Save commits as branch** requires a new branch name and leaves the source working tree alone; an existing branch (especially the checked-out one) is refused. Removal warns that ignored files, caches and files over 100 MB are deleted too, even though source-change counts exclude them. Unreturned commits can be saved to a new source-repo branch before removal. No Worktrunk, OMP extension, settings edit, task or review integration is required.
If checkout HEAD is unborn but other refs contain commits, the removal dialog lists those refs and explains recovery. OVNFS's branch-save operation saves HEAD, not arbitrary refs: switch the workspace to a branch containing the commits (or create a branch at the retained ref), then use **Save commits as branch**. **Save branch, then remove** refuses an unborn HEAD without removing anything. Plain **Remove** remains available after the explicit commit-loss warning.

Scrolling lists, Settings, pickers and dialogs reserve a right-hand gutter so their content stays clear of Tern's overlay scrollbar.

---


## Keyboard-First Controls

Default controls are listed below. Tern’s preset and your overrides can change global shortcuts; **Settings → Global shortcuts** shows the bindings actually in effect.

| Action | macOS | Windows / Linux |
|---|---|---|
| **Toggle Projects sidebar** | `⌘ ⌥ S` | `Ctrl + Alt + S` |
| **Search everywhere** | `⌃ ⌥ ⌘ S` | `Ctrl + Alt + Shift + S` |
| **Cycle views** (Mine ➔ Found ➔ Workspaces ➔ Search ➔ Settings) | `Tab` / `Shift + Tab` | `Tab` / `Shift + Tab` |
| **Quick Search** from Projects or Settings | `/` | `/` |
| **New chat** (in current project/folder) | `⌘ N` | `Ctrl + N` |
| **New chat with…** (choose harness) | `⇧ ⌘ N` | `Shift + Ctrl + N` |
| **Resume chat** | `Enter` | `Enter` |
| **Preview chat** (OMP, Claude Code) | `Space` | `Space` |
| **Fold / unfold project** | `←` / `→` | `←` / `→` |
| **Context menu / Actions** | `Shift + F10` | `Shift + F10` |
| **Copy resume command** | `⌃ Y` | `Ctrl + Y` |
| **Dismiss / Clear search / Close modal** | `Esc` | `Esc` |

Inside any text field, standard terminal editing shortcuts just work (`⌘A`/`Ctrl+A` select all, `⌘⌫`/`Ctrl+U` delete line prefix, `⌥⌫`/`Ctrl+⌫` delete word).

### Customize global shortcuts

In Projects Settings, scroll to **Global shortcuts** and choose **Edit in Tern**. In Tern Settings, choose **Keyboard** and search for **Projects**. Use Tern’s shortcut recorder to add or remove bindings. Projects refreshes the displayed bindings while its Settings page is open, including multiple shortcuts and key sequences.

Tern currently omits some unbound plugin commands from its Keyboard page. For those, use the copy button beside the command, then **Open settings.json**. Merge the desired entries into your existing `keybinds` object, for example:

```json
{
  "keybinds": {
    "ctrl+alt+p": "plugin.tern-projects.projects",
    "ctrl+alt+shift+p": "plugin.tern-projects.search",
    "ctrl+alt+shift+o": "plugin.tern-projects.settings"
  }
}
```

These are examples, not new defaults. User bindings replace an occupied chord, so choose keys deliberately. Tern owns persistence and keymap precedence; Projects does not keep a separate shortcut configuration. See [Tern’s keymap layering](https://docs.stencil.so/tern/guides/commands.html#keymap-layering).

**Panel controls** such as arrows, Tab, New chat, and Refresh remain fixed, apply only inside the panel, and are listed separately from editable global shortcuts.

---

## Supported Coding Harnesses

| Agent | Fresh Launch Command | Native Resume | Multi-Folder Support | Deletion Support |
|---|---|---|---|---|
| **OMP** | `omp --cwd <primary> [--add-dir <extra>...]` | `omp --resume <path>` | ✅ Multiple `--add-dir` | Transcript, artifacts, and session-attributed prompt history |
| **Claude Code** | `claude [--add-dir <extra>...]` | `claude --resume <id>` | ✅ Multiple `--add-dir` | Exact session history filtering |
| **Codex** | `codex --cd <primary> [--add-dir <extra>...]` | `codex resume <id>` | ✅ Multiple `--add-dir` | `codex delete <uuid> --force` |
| **Pi** | `pi` | `pi --session <path>` | Single root | Exact file unlinking |
| **OpenCode** | `opencode <primary>` | `opencode --session <id>` | Single root | `opencode session delete <id>` |
| **Cursor** | `cursor-agent` / native CLI | Resumes in directory | Directory | Clean database record pruning |

OMP keeps one history entry per distinct prompt and associates it with the most recent session that used it. Deleting a chat removes entries currently attributed to that session; entries attributed to another session or with no recorded session are retained.

Permanent deletion refuses unknown history schemas or triggers, ambiguous source identities, busy stores, and stale confirmations. History cleanup is checked under a write transaction before transcripts are removed; unrelated chats, unattributed prompt history, and project files are retained. Filesystem removal and SQLite commit are not crash-atomic: a process crash or later filesystem/commit failure can leave partial cleanup. Such failures are reported, and the plugin does not automatically retry.

---

## How It Works

- **Read-only indexing**: indexing and search never alter project files or original transcripts. Only explicitly confirmed permanent chat deletion removes verified harness-owned data.
- **Fast SQLite FTS**: Full-text indexing runs in a separate local SQLite database (`index.sqlite`), refreshing in the background every two minutes.
- **Durable Library**: Your custom projects, icons, pins, and preferences are stored in an independent `library.sqlite` so reindexing the cache never wipes your setup.

---

## Contributing

Contributions are welcome! Open an issue before submitting a pull request, or use an existing issue that covers your change. Whether you are fixing a bug, improving Luau block performance, or adding support for a new AI coding assistant, see [CONTRIBUTING.md](CONTRIBUTING.md) for architecture notes and step-by-step instructions.

---

## Contributors

Thanks to everyone who has contributed to tern-projects.

<p>
<a href="https://github.com/flosrn"><img src="docs/contributors/flosrn.png" width="48" height="48" alt="@flosrn" title="@flosrn"></a>
<a href="https://github.com/lumiarna"><img src="docs/contributors/lumiarna.png" width="48" height="48" alt="@lumiarna" title="@lumiarna"></a>
<a href="https://github.com/Zestful-ss"><img src="docs/contributors/Zestful-ss.png" width="48" height="48" alt="@Zestful-ss" title="@Zestful-ss"></a>
</p>

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for release notes.

---

## License

[MIT](LICENSE) © 2026 thegeneralist01
