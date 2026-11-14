//! Read-only chat transcripts for the panel's preview pane.

use std::path::{Component, Path};

use anyhow::{bail, ensure, Context, Result};
use rusqlite::OptionalExtension;
use serde_json::{json, Value};

use crate::text::clean_user;

/// Tern caps one canvas update at 256 KiB, measured on the encoded view; leave room for escaping.
const BUDGET: usize = 128 * 1024;
/// A pasted log or a long answer must not crowd out the rest of the chat.
const PART_CAP: usize = 16 * 1024;
const TURN_CAP: usize = 64 * 1024;
/// Tern caps a canvas view at 2000 nodes; each turn draws a few.
const MAX_TURNS: usize = 400;

#[derive(Clone, Copy, PartialEq, Debug)]
enum Role {
    User,
    Assistant,
}

enum Part {
    Text(String),
    /// Consecutive tool calls with their counts, in first-call order.
    Tools(Vec<(String, usize)>),
}

struct Turn {
    role: Role,
    parts: Vec<Part>,
}

#[derive(Default)]
struct Transcript {
    turns: Vec<Turn>,
}

impl Transcript {
    fn push_text(&mut self, role: Role, text: String) {
        match self.turns.last_mut() {
            Some(turn) if turn.role == role => turn.parts.push(Part::Text(text)),
            _ => self.turns.push(Turn { role, parts: vec![Part::Text(text)] }),
        }
    }

    fn push_tool(&mut self, name: &str) {
        if self.turns.last().is_none_or(|turn| turn.role != Role::Assistant) {
            self.turns.push(Turn { role: Role::Assistant, parts: Vec::new() });
        }
        let parts = &mut self.turns.last_mut().expect("assistant turn").parts;
        if let Some(Part::Tools(tools)) = parts.last_mut() {
            match tools.iter_mut().find(|(known, _)| known == name) {
                Some(entry) => entry.1 += 1,
                None => tools.push((name.to_owned(), 1)),
            }
        } else {
            parts.push(Part::Tools(vec![(name.to_owned(), 1)]));
        }
    }

    fn user(&mut self, content: Option<&Value>) {
        let mut text = String::new();
        let mut images = 0;
        match content {
            Some(Value::String(s)) => text.push_str(s),
            Some(Value::Array(items)) => {
                // Tool output (including screenshots returned with it) stays out of the preview.
                if items.iter().any(|item| item.get("type").and_then(Value::as_str) == Some("tool_result")) {
                    return;
                }
                for item in items {
                    match item.get("type").and_then(Value::as_str) {
                        Some("text") => {
                            if let Some(t) = item.get("text").and_then(Value::as_str) {
                                if !text.is_empty() {
                                    text.push('\n');
                                }
                                text.push_str(t);
                            }
                        }
                        Some("image") => images += 1,
                        _ => {}
                    }
                }
            }
            _ => {}
        }
        let mut text = clean_user(&text).unwrap_or_default();
        if images > 0 {
            if !text.is_empty() {
                text.push_str("\n\n");
            }
            text.push_str(&format!("_[{images} image{}]_", if images == 1 { "" } else { "s" }));
        }
        if !text.is_empty() {
            self.push_text(Role::User, text);
        }
    }

    fn assistant(&mut self, content: Option<&Value>, tool_type: &str) {
        match content {
            Some(Value::String(s)) => self.say(s),
            Some(Value::Array(items)) => {
                for item in items {
                    match item.get("type").and_then(Value::as_str) {
                        Some("text") => {
                            if let Some(t) = item.get("text").and_then(Value::as_str) {
                                self.say(t);
                            }
                        }
                        Some(kind) if kind == tool_type => {
                            self.push_tool(item.get("name").and_then(Value::as_str).unwrap_or("tool"));
                        }
                        // Thinking stays out of the preview.
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }

    fn say(&mut self, text: &str) {
        let text = text.trim();
        if !text.is_empty() {
            self.push_text(Role::Assistant, text.to_owned());
        }
    }
}

fn read_omp(content: &str) -> Transcript {
    let mut out = Transcript::default();
    for line in content.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
        if v.get("type").and_then(Value::as_str) != Some("message") {
            continue;
        }
        let msg = v.get("message").unwrap_or(&v);
        match msg.get("role").and_then(Value::as_str) {
            Some("user") => out.user(msg.get("content")),
            Some("assistant") => out.assistant(msg.get("content"), "toolCall"),
            _ => {}
        }
    }
    out
}

fn read_claude(content: &str) -> Transcript {
    let mut out = Transcript::default();
    for line in content.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
        let flag = |key: &str| v.get(key).and_then(Value::as_bool).unwrap_or(false);
        // Compaction summaries are written as user records but are Claude Code's own text.
        if flag("isSidechain") || flag("isMeta") || flag("isCompactSummary") {
            continue;
        }
        let content = v.pointer("/message/content").or_else(|| v.get("content"));
        match v.get("type").and_then(Value::as_str) {
            Some("user") => out.user(content),
            Some("assistant") => out.assistant(content, "tool_use"),
            _ => {}
        }
    }
    out
}

/// Close a code fence left open, so one message cannot swallow the rest of the preview.
fn close_fences(text: &mut String) {
    let mut open: Option<&'static str> = None;
    for line in text.lines() {
        let line = line.trim_start();
        for marker in ["```", "~~~"] {
            if line.starts_with(marker) {
                open = match open {
                    None => Some(marker),
                    Some(current) if current == marker => None,
                    other => other,
                };
                break;
            }
        }
    }
    if let Some(marker) = open {
        text.push('\n');
        text.push_str(marker);
    }
}

fn floor_boundary(s: &str, mut at: usize) -> usize {
    while at > 0 && !s.is_char_boundary(at) {
        at -= 1;
    }
    at
}

fn render_part(part: &Part) -> String {
    match part {
        Part::Text(text) => {
            let truncated = text.len() > PART_CAP;
            // Control bytes (ANSI escapes in pasted logs) render as noise and inflate the encoded view.
            let mut out: String = text[..floor_boundary(text, PART_CAP.min(text.len()))]
                .chars()
                .filter(|c| !c.is_control() || *c == '\n' || *c == '\t')
                .collect();
            close_fences(&mut out);
            if truncated {
                out.push_str("\n\n_… message truncated_");
            }
            out
        }
        Part::Tools(tools) => {
            let names: Vec<String> = tools
                .iter()
                .map(|(name, count)| {
                    let name = name.replace('`', "");
                    if *count > 1 { format!("`{name}` ×{count}") } else { format!("`{name}`") }
                })
                .collect();
            format!("_Tools: {}_", names.join(" · "))
        }
    }
}

fn render_turn(turn: &Turn) -> String {
    // Keep the end of an oversized turn: the final answer matters most.
    let mut parts: Vec<String> = Vec::new();
    let mut used = 0;
    let mut cut = false;
    for part in turn.parts.iter().rev() {
        let block = render_part(part);
        if !parts.is_empty() && used + block.len() > TURN_CAP {
            cut = true;
            break;
        }
        used += block.len() + 2;
        parts.push(block);
    }
    if cut {
        parts.push("_… earlier part of this reply omitted_".to_owned());
    }
    parts.reverse();
    parts.join("\n\n")
}

/// Markdown per turn for the newest turns that fit the budget, oldest first, and how many are hidden.
fn render(transcript: &Transcript) -> (Vec<(Role, String)>, usize) {
    let mut shown: Vec<(Role, String)> = Vec::new();
    let mut used = 0;
    for turn in transcript.turns.iter().rev().take(MAX_TURNS) {
        let markdown = render_turn(turn);
        if !shown.is_empty() && used + markdown.len() > BUDGET {
            break;
        }
        used += markdown.len();
        shown.push((turn.role, markdown));
    }
    shown.reverse();
    let hidden = transcript.turns.len() - shown.len();
    (shown, hidden)
}

pub fn preview(db_path: &Path, home: &Path, uid: &str) -> Result<Value> {
    let conn = crate::db::open_readonly(db_path)?;
    let (agent, source, title, cwd): (String, String, String, String) = conn
        .query_row("SELECT agent, source, title, cwd FROM sessions WHERE uid=?1", [uid], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
        })
        .optional()?
        .context("Chat not found. Refresh the index and try again.")?;
    let (label, root) = match agent.as_str() {
        "omp" => ("OMP", home.join(".omp/agent/sessions")),
        "claude" => ("Claude Code", home.join(".claude/projects")),
        other => bail!("Preview is not available for {other} chats."),
    };
    let path = Path::new(source.strip_prefix(&format!("{agent}:")).context("Unexpected chat source")?);
    // The index names the file; read only inside the harness's own history folder.
    ensure!(
        path.starts_with(&root) && !path.components().any(|c| c == Component::ParentDir),
        "Chat transcript is outside the {label} history folder."
    );
    let content = std::fs::read_to_string(path).with_context(|| format!("Reading {}", path.display()))?;
    let transcript = if agent == "omp" { read_omp(&content) } else { read_claude(&content) };
    let (shown, hidden) = render(&transcript);
    let turns: Vec<Value> = shown
        .into_iter()
        .map(|(role, markdown)| json!({"role": if role == Role::User { "user" } else { "assistant" }, "markdown": markdown}))
        .collect();
    Ok(json!({
        "uid": uid,
        "title": title,
        "agent": agent,
        "label": label,
        "cwd": cwd,
        "hidden": hidden,
        "turns": turns,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_calls_between_replies_condense_into_one_line() {
        let jsonl = [
            r#"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"Fix it"}]}}"#,
            r#"{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"secret"},{"type":"text","text":"Looking."},{"type":"toolCall","name":"read"}]}}"#,
            r#"{"type":"message","message":{"role":"toolResult","content":[{"type":"text","text":"file body"}]}}"#,
            r#"{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall","name":"read"},{"type":"toolCall","name":"edit"}]}}"#,
            r#"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}"#,
        ]
        .join("\n");
        let (turns, hidden) = render(&read_omp(&jsonl));
        assert_eq!(hidden, 0);
        assert_eq!(turns.len(), 2);
        assert_eq!(turns[0], (Role::User, "Fix it".to_owned()));
        assert_eq!(turns[1], (Role::Assistant, "Looking.\n\n_Tools: `read` ×2 · `edit`_\n\nDone.".to_owned()));
    }

    #[test]
    fn long_chats_keep_the_newest_turns_within_budget() {
        let body = "x".repeat(PART_CAP);
        let lines: Vec<String> = (0..40)
            .map(|i| {
                let role = if i % 2 == 0 { "user" } else { "assistant" };
                json!({"type": role, "message": {"content": [{"type": "text", "text": format!("turn{i} {body}")}]}})
                    .to_string()
            })
            .collect();
        let transcript = read_claude(&lines.join("\n"));
        let (turns, hidden) = render(&transcript);
        let size: usize = turns.iter().map(|(_, md)| md.len()).sum();
        assert!(size <= BUDGET, "{size}");
        assert!(hidden > 0 && hidden + turns.len() == 40);
        assert!(turns.last().is_some_and(|(_, md)| md.starts_with("turn39 ")), "newest turn kept");
        assert!(turns.iter().all(|(_, md)| !md.starts_with("turn0 ")), "oldest turn dropped");
    }

    #[test]
    fn claude_summaries_and_tool_output_never_appear_as_user_turns() {
        let jsonl = [
            r#"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued from a previous conversation"}}"#,
            r#"{"type":"user","message":{"role":"user","content":"Pick a tree"}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{}}]}}"#,
            r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"chosen"},{"type":"image","source":{}}]}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Using tree 3."}]}}"#,
        ]
        .join("\n");
        let (turns, hidden) = render(&read_claude(&jsonl));
        assert_eq!(hidden, 0);
        assert_eq!(turns, vec![
            (Role::User, "Pick a tree".to_owned()),
            (Role::Assistant, "_Tools: `AskUserQuestion`_\n\nUsing tree 3.".to_owned()),
        ]);
    }

    #[test]
    fn truncated_message_closes_its_code_fence() {
        let text = format!("```rust\n{}", "let a = 1;\n".repeat(PART_CAP));
        let out = render_part(&Part::Text(text));
        let fences = out.lines().filter(|l| l.trim_start().starts_with("```")).count();
        assert_eq!(fences % 2, 0, "fence left open");
        assert!(out.ends_with("_… message truncated_"));
    }
}
