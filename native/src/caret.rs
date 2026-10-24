//! `omarchy-dictate caret`: where the text cursor is, so the dictation bubble
//! appears next to it. Wayland only tells the input method; fcitx5 (Omarchy's)
//! passes it on to a KDE-style input panel through its kimpanel addon. This
//! serves org.kde.impanel on the session bus and prints one JSON line per
//! cursor move: {"type":"caret","address","x","y","w","h"} in layout pixels,
//! address being the Hyprland window that had the cursor.
//!
//! While it runs fcitx5 uses this panel instead of its own popups, which only
//! matters for input methods with candidate windows, so it serves only when
//! every configured input method is a keyboard layout; otherwise it prints
//! {"type":"unavailable","reason":"input_method"} (or "no_fcitx5") and exits.
//! SIGTERM (or the shell exiting) gives fcitx5 its own popups back.
use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    os::unix::net::UnixStream,
    path::PathBuf,
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::Duration,
};

fn emit(value: Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

fn hyprland(request: &str) -> Option<Value> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")?;
    let signature = std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE")?;
    let path = PathBuf::from(runtime).join("hypr").join(signature).join(".socket.sock");
    let mut stream = UnixStream::connect(path).ok()?;
    stream.set_read_timeout(Some(Duration::from_millis(500))).ok()?;
    stream.write_all(request.as_bytes()).ok()?;
    let mut reply = String::new();
    stream.take(1 << 20).read_to_string(&mut reply).ok()?;
    serde_json::from_str(&reply).ok()
}

/// Window-relative rectangles (Wayland clients) are in the surface's own
/// pixels; `scale` turns them into layout pixels from the window's corner.
pub fn absolute(window: &Value, x: i32, y: i32, w: i32, h: i32, scale: Option<f64>) -> Option<Value> {
    let address = window["address"].as_str().filter(|a| !a.is_empty())?;
    let (x, y, w, h) = match scale {
        None => (x as f64, y as f64, w as f64, h as f64),
        Some(s) => {
            let s = if s.is_finite() && s > 0.0 { s } else { 1.0 };
            (window["at"][0].as_f64()? + x as f64 / s, window["at"][1].as_f64()? + y as f64 / s, w as f64 / s, h as f64 / s)
        }
    };
    Some(json!({"type":"caret","address":address,"x":x.round(),"y":y.round(),"w":w.round(),"h":h.round()}))
}

fn report(x: i32, y: i32, w: i32, h: i32, scale: Option<f64>) {
    if let Some(event) = hyprland("j/activewindow").and_then(|window| absolute(&window, x, y, w, h, scale)) {
        emit(event);
    }
}

struct Panel;

#[zbus::interface(name = "org.kde.impanel2")]
impl Panel {
    #[zbus(name = "SetSpotRect")]
    fn set_spot_rect(&self, x: i32, y: i32, w: i32, h: i32) {
        report(x, y, w, h, None)
    }
    #[zbus(name = "SetRelativeSpotRect")]
    fn set_relative_spot_rect(&self, x: i32, y: i32, w: i32, h: i32) {
        report(x, y, w, h, Some(1.0))
    }
    #[zbus(name = "SetRelativeSpotRectV2")]
    fn set_relative_spot_rect_v2(&self, x: i32, y: i32, w: i32, h: i32, scale: f64) {
        report(x, y, w, h, Some(scale))
    }
}

fn keyboards_only(conn: &zbus::blocking::Connection) -> Option<bool> {
    let fcitx = zbus::blocking::Proxy::new(conn, "org.fcitx.Fcitx5", "/controller", "org.fcitx.Fcitx.Controller1").ok()?;
    let groups: Vec<String> = fcitx.call("InputMethodGroups", &()).ok()?;
    let mut all = true;
    for group in groups {
        let (_layout, items): (String, Vec<(String, String)>) = fcitx.call("InputMethodGroupInfo", &(group,)).ok()?;
        all &= items.iter().all(|(im, _)| im.starts_with("keyboard-"));
    }
    Some(all)
}

pub fn serve(cancel: &AtomicBool) {
    let Ok(conn) = zbus::blocking::Connection::session() else {
        emit(json!({"type":"unavailable","reason":"no_session_bus"}));
        return;
    };
    match keyboards_only(&conn) {
        None => return emit(json!({"type":"unavailable","reason":"no_fcitx5"})),
        Some(false) => return emit(json!({"type":"unavailable","reason":"input_method"})),
        Some(true) => {}
    }
    let served = conn.object_server().at("/org/kde/impanel", Panel).is_ok() && conn.request_name("org.kde.impanel").is_ok();
    if !served {
        return emit(json!({"type":"unavailable","reason":"panel_taken"}));
    }
    // fcitx5 watches the name; the signals make older versions notice too.
    let _ = conn.emit_signal(None::<&str>, "/org/kde/impanel", "org.kde.impanel2", "PanelCreated2", &());
    let _ = conn.emit_signal(None::<&str>, "/org/kde/impanel", "org.kde.impanel", "PanelCreated", &());
    emit(json!({"type":"ready"}));
    while !cancel.load(Ordering::SeqCst) {
        thread::sleep(Duration::from_millis(200));
    }
    let _ = conn.release_name("org.kde.impanel");
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rectangles_land_in_layout_pixels() {
        let window = json!({"address":"0xabc","at":[100,50]});
        assert_eq!(absolute(&window, 20, 40, 2, 30, Some(2.0)).unwrap(), json!({"type":"caret","address":"0xabc","x":110.0,"y":70.0,"w":1.0,"h":15.0}));
        assert_eq!(absolute(&window, 20, 40, 2, 30, None).unwrap()["x"], 20.0);
        assert_eq!(absolute(&window, 20, 40, 2, 30, Some(0.0)).unwrap()["x"], 120.0);
        assert!(absolute(&json!({}), 1, 1, 1, 1, None).is_none());
    }
}
