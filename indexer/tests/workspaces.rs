#![cfg(unix)]
use serde_json::{json, Value};
use std::{fs, io::Write, os::unix::fs::PermissionsExt, path::Path, process::{Command, Output, Stdio}};
const BIN: &str = env!("CARGO_BIN_EXE_tern-projects");
fn command(root: &Path, request: Value) -> std::process::Child {
    let mut child = Command::new(BIN).args(["--db", root.join("index.sqlite").to_str().unwrap(), "library"])
        .env("PATH", format!("{}:/usr/bin:/bin", root.display())).env("WS_FIXTURE", root)
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
    child.stdin.take().unwrap().write_all(json!({"op":"workspaces", "request":request}).to_string().as_bytes()).unwrap();
    child
}
fn call(root: &Path, request: Value) -> Output { command(root, request).wait_with_output().unwrap() }
fn value(out: Output) -> Value {
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    serde_json::from_slice(&out.stdout).unwrap()
}
fn fixture() -> tempfile::TempDir {
    let temp = tempfile::tempdir().unwrap();
    fs::write(temp.path().join("ovnfs"), r##"#!/bin/sh
printf '%s\n' "$*" >> "$WS_FIXTURE/calls"
case "$1" in
 status)
  if test -f "$WS_FIXTURE/stopped"; then echo 'not running' >&2; exit 1; fi
  if test -f "$WS_FIXTURE/error"; then echo 'permission denied' >&2; exit 1; fi
  echo '{"pid":42}';;
 ls) cat "$WS_FIXTURE/list";;
 diff) echo '{"changes":[{"path":"a.txt","status":"M"}]}' ;;
 apply)
  if test "$3" = '--dry-run'; then echo '{"source":"/source","applied":[{"path":"a.txt","status":"M"}],"merged":[],"conflicts":[{"path":"b.txt","markers":true}]}'; exit 1; fi
  touch "$WS_FIXTURE/applying"; sleep 0.3; echo '{"source":"/source","applied":[],"merged":[],"conflicts":[]}' ;;
 *) echo '{}' ;;
esac
"##).unwrap();
    fs::set_permissions(temp.path().join("ovnfs"), fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(temp.path().join("list"), json!({"checkouts":[
        {"name":"parent", "path":"/mount/parent", "source":"/source", "base":"base", "created":"2026-01-01T00:00:00Z", "touched":"2026-02-01", "git":false},
        {"name":"child", "path":"/mount/child", "source":"/source", "base":"base", "created":"2026-03-01T00:00:00Z", "touched":"2026-03-01", "parent":"snap", "git":false}],
        "snapshots":[{"id":"snap", "checkout":"parent", "created":"2026-02-01T00:00:00Z"}]}).to_string()).unwrap();
    temp
}
#[test]
fn stopped_and_error_never_list_or_autostart() {
    let t = fixture();
    for (file, state) in [("stopped", "stopped"), ("error", "error")] {
        fs::write(t.path().join(file), "").unwrap();
        assert_eq!(value(call(t.path(), json!({"action":"poll"})))["state"], state);
        fs::remove_file(t.path().join(file)).unwrap();
    }
    assert_eq!(fs::read_to_string(t.path().join("calls")).unwrap(), "status --json\nstatus --json\n");
}
#[test]
fn snapshot_lineage_rejects_reused_parent_and_changed_identity() {
    let t = fixture();
    let first = value(call(t.path(), json!({"action":"poll"})));
    assert_eq!(first["checkouts"][1]["parent_name"], "parent");
    let stale = call(t.path(), json!({"action":"remove","name":"parent","identity":"wrong","expected":"wrong"}));
    assert!(!stale.status.success());
    assert!(!fs::read_to_string(t.path().join("calls")).unwrap().contains("rm "));
    let mut list: Value = serde_json::from_str(&fs::read_to_string(t.path().join("list")).unwrap()).unwrap();
    list["checkouts"][0]["created"] = json!("2026-04-01T00:00:00Z");
    fs::write(t.path().join("list"), list.to_string()).unwrap();
    assert!(value(call(t.path(), json!({"action":"poll"})))["checkouts"][1]["parent_name"].is_null());
}
#[test]
fn partial_conflict_preview_and_reload_guard() {
    let t = fixture();
    let poll = value(call(t.path(), json!({"action":"poll"})));
    let identity = &poll["checkouts"][0]["identity"];
    let preview = value(call(t.path(), json!({"action":"preview","name":"parent","identity":identity})));
    assert_eq!(preview["conflicts"][0]["markers"], true);
    let stale = call(t.path(), json!({"action":"apply","name":"parent","identity":identity,"expected":"stale"}));
    assert!(!stale.status.success());
    let applying = command(t.path(), json!({"action":"apply","name":"parent","identity":identity,"expected":preview["token"]}));
    // Wait for the fixture's handshake, not an arbitrary assumption about process scheduling.
    for _ in 0..200 {
        if t.path().join("applying").exists() { break; }
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
    assert!(t.path().join("applying").exists());
    assert_eq!(value(call(t.path(), json!({"action":"poll"})))["busy"], true);
    assert!(!call(t.path(), json!({"action":"remove","name":"parent","identity":identity,"expected":"anything"})).status.success());
    value(applying.wait_with_output().unwrap());
    assert_eq!(value(call(t.path(), json!({"action":"poll"})))["busy"], false);
}
