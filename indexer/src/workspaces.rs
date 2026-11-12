//! OVNFS is authoritative: no stored checkout list, automatic daemon startup or operation replay.
use anyhow::{bail, ensure, Context, Result};
use fs2::FileExt;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{File, OpenOptions};
use std::path::Path;
use std::process::{Command, Output};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub action: String,
    pub name: Option<String>,
    pub source: Option<String>,
    pub identity: Option<String>,
    pub expected: Option<String>,
    pub branch: Option<String>,
}

fn run(program: &str, args: &[&str]) -> Result<Output> {
    Command::new(program).args(args).output().with_context(|| format!("cannot run {program}"))
}
fn output(out: Output, conflicts: bool) -> Result<Value> {
    let value = serde_json::from_slice::<Value>(&out.stdout);
    if out.status.success() || (conflicts && out.status.code() == Some(1)
        && value.as_ref().ok().and_then(|v| v.get("conflicts")).is_some_and(Value::is_array)) {
        return value.context("invalid OVNFS JSON");
    }
    bail!("{}", String::from_utf8_lossy(&out.stderr).trim());
}
fn ovnfs(args: &[&str], conflicts: bool) -> Result<Value> { output(run("ovnfs", args)?, conflicts) }
fn git(path: &str, args: &[&str]) -> Result<String> {
    let mut argv = vec!["-C", path];
    argv.extend_from_slice(args);
    let out = run("git", &argv)?;
    ensure!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr).trim());
    Ok(String::from_utf8(out.stdout)?.trim().to_owned())
}
fn hash(value: &Value) -> String { format!("{:x}", Sha256::digest(value.to_string().as_bytes())) }
fn identity(c: &Value) -> String { hash(&json!([c["name"], c["source"], c["path"], c["created"], c["base"]])) }
fn lock_file(db: &Path) -> Result<File> {
    if let Some(parent) = db.parent() { std::fs::create_dir_all(parent)?; }
    Ok(OpenOptions::new().write(true).create(true).truncate(false).open(db.with_extension("workspaces.lock"))?)
}
fn busy(db: &Path) -> Result<bool> {
    let file = lock_file(db)?;
    match FileExt::try_lock_shared(&file) {
        Ok(()) => Ok(false),
        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => Ok(true),
        Err(e) => Err(e.into()),
    }
}
fn status() -> Result<Value> {
    let out = match run("ovnfs", &["status", "--json"]) {
        Ok(out) => out,
        Err(e) if e.downcast_ref::<std::io::Error>().is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
            return Ok(json!({"state":"missing", "error":"OVNFS is not installed or is not on PATH."})),
        Err(e) => return Ok(json!({"state":"error", "error":format!("{e:#}")})),
    };
    let stderr = String::from_utf8_lossy(&out.stderr).trim().to_owned();
    if out.status.code() == Some(127) { return Ok(json!({"state":"missing", "error":stderr})); }
    if out.status.code() == Some(1) && out.stdout.is_empty() && stderr == "not running" {
        return Ok(json!({"state":"stopped", "error":"OVNFS is not running."}));
    }
    if !out.status.success() { return Ok(json!({"state":"error", "error":stderr})); }
    let mut value = output(out, false)?;
    value["state"] = json!("running");
    Ok(value)
}
// Go's RFC3339Nano omits trailing fractional zeroes, so raw strings do not sort chronologically.
fn timestamp_key(value: &Value) -> Option<(&str, u32)> {
    let text = value.as_str()?.strip_suffix('Z')?;
    let (date, fraction) = text.split_once('.').unwrap_or((text, ""));
    if date.len() != 19 || fraction.len() > 9 { return None; }
    let mut nanos = 0;
    for digit in fraction.bytes() {
        if !digit.is_ascii_digit() { return None; }
        nanos = nanos * 10 + u32::from(digit - b'0');
    }
    Some((date, nanos * 10u32.pow(9 - fraction.len() as u32)))
}
fn listing() -> Result<Value> {
    let mut data = ovnfs(&["ls", "--json"], false)?;
    let snapshots = data.as_object_mut().context("OVNFS listing must be an object")?
        .remove("snapshots").context("OVNFS snapshots missing")?;
    let snapshots = snapshots.as_array().context("OVNFS snapshots must be an array")?;
    let checkouts = data["checkouts"].as_array_mut().context("OVNFS checkouts missing")?;
    for c in checkouts.iter_mut() { c["identity"] = json!(identity(c)); }
    // Snapshot names are not identities: a removed parent's reused name must not adopt its children.
    let parents: Vec<_> = checkouts.iter().map(|c| {
        let snap = snapshots.iter().find(|s| !c["parent"].is_null() && s["id"] == c["parent"])?;
        let parent = checkouts.iter().find(|p| p["name"] == snap["checkout"] && p["name"] != c["name"]
            && p["source"] == c["source"] && timestamp_key(&p["created"]).zip(timestamp_key(&snap["created"])).is_some_and(|(a, b)| a <= b))?;
        Some(parent["name"].clone())
    }).collect();
    for (c, parent) in checkouts.iter_mut().zip(parents) {
        if let Some(name) = parent { c["parent_name"] = name; }
    }
    Ok(data)
}
fn checkout(req: &Request) -> Result<Value> {
    let name = req.name.as_deref().context("workspace name required")?;
    ensure!(status()?["state"] == "running", "OVNFS is not running; refresh its status first");
    let data = listing()?;
    let c = data["checkouts"].as_array().unwrap().iter().find(|c| c["name"] == name)
        .context("workspace no longer exists; refresh")?;
    ensure!(req.identity.as_deref() == c["identity"].as_str(), "workspace identity changed; refresh");
    Ok(c.clone())
}
fn commits(c: &Value) -> Result<Value> {
    if c["git"] != true { return Ok(Value::Null); }
    let source = c["source"].as_str().context("source missing")?;
    let path = c["path"].as_str().context("workspace path missing")?;
    let tip = git(source, &["rev-parse", "--verify", "HEAD"])?;
    let range = format!("{tip}..HEAD");
    let count: u64 = git(path, &["rev-list", "--count", &range])?.parse()?;
    let log = git(path, &["log", "-25", "--format=%h %s", &range])?;
    Ok(json!({"count": count, "tip":tip, "head":git(path, &["rev-parse", "HEAD"])?, "titles":log.lines().collect::<Vec<_>>()}))
}
fn details(c: &Value) -> Result<Value> {
    let diff = ovnfs(&["diff", c["name"].as_str().unwrap(), "--json"], false)?;
    let (commits, error) = match commits(c) {
        Ok(v) => (v, Value::Null),
        Err(e) => (Value::Null, json!(format!("Cannot count commits: {e:#}"))),
    };
    let token = hash(&json!([c["identity"], c["touched"], diff, commits]));
    Ok(json!({"changes":diff["changes"], "commits":commits, "error":error, "token":token}))
}
fn preview(c: &Value) -> Result<Value> {
    let mut result = ovnfs(&["apply", c["name"].as_str().unwrap(), "--dry-run", "--json"], true)?;
    let info = details(c)?;
    result["token"] = json!(hash(&json!([info["token"], result])));
    result["details"] = info;
    Ok(result)
}
fn validate_name(name: &str) -> Result<()> {
    ensure!(name.len() <= 64 && name.as_bytes().first().is_some_and(|b| b.is_ascii_lowercase() || b.is_ascii_digit()),
        "Use 1–64 lowercase letters, numbers, dots, underscores or hyphens; start with a letter or number");
    ensure!(name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b)), "Invalid workspace name");
    Ok(())
}
fn save_branch(c: &Value, branch: &str) -> Result<Value> {
    ensure!(c["git"] == true, "This workspace is not a Git repository");
    ensure!(!branch.starts_with('-') && !branch.is_empty(), "A new branch name is required");
    let source = c["source"].as_str().unwrap();
    git(source, &["check-ref-format", "--branch", branch])?;
    let reference = format!("refs/heads/{branch}");
    let exists = run("git", &["-C", source, "show-ref", "--verify", "--quiet", &reference])?;
    ensure!(exists.status.code() == Some(1), "Branch already exists or cannot be checked; choose a new branch");
    ovnfs(&["apply", c["name"].as_str().unwrap(), "--branch", branch, "--json"], false)
}

pub fn dispatch(db: &Path, req: Request) -> Result<Value> {
    if req.action == "poll" {
        let mut state = status()?;
        state["busy"] = json!(busy(db)?);
        if state["state"] == "running" {
            match listing() {
                Ok(data) => { state["checkouts"] = data["checkouts"].clone(); },
                Err(e) => { state["state"] = json!("error"); state["error"] = json!(format!("{e:#}")); },
            }
        }
        return Ok(state);
    }
    if req.action == "details" { return details(&checkout(&req)?); }
    if req.action == "preview" { return preview(&checkout(&req)?); }
    // The OS-held guard outlives a plugin reload with its CLI child. No journal and no replay.
    let guard = lock_file(db)?;
    guard.try_lock_exclusive().context("A workspace operation is still running; refresh before trying again")?;
    if req.action == "start" { return ovnfs(&["--json", "start"], false); }
    if req.action == "new" {
        let name = req.name.as_deref().context("workspace name required")?;
        validate_name(name)?;
        ensure!(status()?["state"] == "running", "Start OVNFS first");
        let source = req.source.as_deref().context("source folder required")?;
        ensure!(Path::new(source).is_absolute(), "Choose an absolute source folder");
        return ovnfs(&["new", source, "--name", name, "--json"], false);
    }
    let c = checkout(&req)?;
    let name = c["name"].as_str().unwrap();
    match req.action.as_str() {
        "fork" => {
            let child = req.branch.as_deref().context("fork name required")?;
            validate_name(child)?;
            ovnfs(&["fork", name, "--name", child, "--json"], false)
        },
        "apply" => {
            let current = preview(&c)?;
            ensure!(req.expected.as_deref() == current["token"].as_str(), "Preview changed; cancel and preview again");
            ovnfs(&["apply", name, "--json"], true)
        },
        "remove" | "save-remove" => {
            let info = details(&c)?;
            ensure!(req.expected.as_deref() == info["token"].as_str(), "Workspace changed; cancel and review removal again");
            ensure!(info["error"].is_null(), "Cannot safely check unreturned commits; fix the Git error first");
            if req.action == "save-remove" { save_branch(&c, req.branch.as_deref().context("new branch required")?)?; }
            ovnfs(&["rm", name, "--json"], false)
        },
        "branch" => save_branch(&c, req.branch.as_deref().context("new branch required")?),
        _ => bail!("unknown workspace operation"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn names_are_bounded_and_not_options() {
        for n in ["hello", "a._-9", "0"] { assert!(validate_name(n).is_ok()); }
        for n in ["", "-flag", ".hidden", "UPPER", "with space", "a/b", &"a".repeat(65)] { assert!(validate_name(n).is_err()); }
    }
    #[test]
    fn fractional_timestamps_compare_chronologically() {
        let a = json!("2026-11-12T00:00:00.12Z");
        let b = json!("2026-11-12T00:00:00.123Z");
        assert!(timestamp_key(&a) < timestamp_key(&b));
        assert_eq!(timestamp_key(&a), timestamp_key(&json!("2026-11-12T00:00:00.120000000Z")));
        assert!(timestamp_key(&json!("malformed")).is_none());
    }
    #[test]
    fn conflict_exit_is_a_successful_result_not_a_retry() {
        #[cfg(unix)] {
            use std::os::unix::process::ExitStatusExt;
            let out = Output {status: std::process::ExitStatus::from_raw(256), stdout: br#"{"conflicts":[{"path":"a","markers":true}]}"#.to_vec(), stderr: b"has conflicts".to_vec()};
            assert_eq!(output(out, true).unwrap()["conflicts"][0]["path"], "a");
        }
    }
    #[test]
    fn guard_survives_a_new_request() {
        let temp = tempfile::tempdir().unwrap();
        let db = temp.path().join("index.sqlite");
        let guard = lock_file(&db).unwrap();
        guard.try_lock_exclusive().unwrap();
        assert!(busy(&db).unwrap());
        drop(guard);
        assert!(!busy(&db).unwrap());
    }
}
