mod files;
mod hotspot;
mod pairing;
mod server;
mod transfers;

use server::AppState;
use std::path::PathBuf;
use std::sync::{Arc, RwLock};
use std::time::Duration;
use tauri::{Emitter, Manager};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;
use transfers::Registry;

struct Desktop {
    state: AppState,
    key_path: PathBuf,
    port: u16,
    wifi: Option<(String, String)>, // the laptop's own network, if this Wi-Fi card could start it
}

#[derive(serde::Serialize)]
struct PairingView {
    qr_svg: String,
    name: String,
    urls: Vec<String>,
}

fn pairing_view(d: &Desktop) -> PairingView {
    // IPs are read fresh each time: the laptop may join a hotspot after Pasa started.
    let ips = pairing::lan_ips();
    let key = d.state.key.read().unwrap().clone();
    PairingView {
        qr_svg: pairing::qr_svg(&pairing::qr_payload(
            &ips,
            d.port,
            &key,
            &d.state.name,
            d.wifi.as_ref().map(|(s, p)| (s.as_str(), p.as_str())),
        )),
        name: d.state.name.clone(),
        urls: ips.iter().map(|ip| format!("{ip}:{}", d.port)).collect(),
    }
}

#[tauri::command]
fn get_pairing(d: tauri::State<Desktop>) -> PairingView {
    pairing_view(&d)
}

#[tauri::command]
fn send_files(d: tauri::State<Desktop>, paths: Vec<String>) {
    for p in paths {
        let _ = d.state.registry.add_outgoing(PathBuf::from(p)); // folders and unreadable paths are skipped
    }
}

#[tauri::command]
async fn pick_files(app: tauri::AppHandle) {
    let Some(picked) = app.dialog().file().blocking_pick_files() else { return };
    let d = app.state::<Desktop>();
    for f in picked {
        if let Ok(p) = f.into_path() {
            let _ = d.state.registry.add_outgoing(p);
        }
    }
}

#[tauri::command]
fn cancel_transfer(d: tauri::State<Desktop>, id: String) -> bool {
    d.state.registry.cancel(&id)
}

#[tauri::command]
fn open_receive_folder(app: tauri::AppHandle, d: tauri::State<Desktop>) {
    let _ = std::fs::create_dir_all(&d.state.receive_dir);
    let _ = app.opener().open_path(d.state.receive_dir.to_string_lossy(), None::<&str>);
}

#[tauri::command]
fn reveal(app: tauri::AppHandle, path: String) {
    let _ = app.opener().reveal_item_in_dir(path);
}

#[tauri::command]
fn forget_phones(d: tauri::State<Desktop>) -> Result<PairingView, String> {
    let k = pairing::rotate_key(&d.key_path).map_err(|e| e.to_string())?;
    *d.state.key.write().unwrap() = k;
    Ok(pairing_view(&d))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let key_path = app.path().app_config_dir()?.join("key");
            let key = pairing::load_or_create_key(&key_path)?;
            let state = AppState {
                key: Arc::new(RwLock::new(key)),
                registry: Arc::new(Registry::new()),
                receive_dir: app.path().download_dir()?.join("Pasa"),
                name: pairing::laptop_name(),
            };
            let port = tauri::async_runtime::block_on(server::serve(state.clone(), 47800))?;
            let registry = state.registry.clone();
            let (ssid, pass) = hotspot::wifi_credentials(&app.path().app_config_dir()?.join("wifi"), &state.name)?;
            let wifi = hotspot::start(ssid.clone(), pass.clone()).then_some((ssid, pass));
            app.manage(Desktop { state, key_path, port, wifi });

            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let mut was_connected = None;
                loop {
                    tokio::time::sleep(Duration::from_millis(150)).await;
                    if registry.take_dirty() {
                        let _ = handle.emit("transfers", registry.snapshot());
                    }
                    let now = registry.connected();
                    if was_connected != Some(now) {
                        was_connected = Some(now);
                        let _ = handle.emit("connection", now);
                    }
                }
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_pairing, send_files, pick_files, cancel_transfer, open_receive_folder, reveal, forget_phones
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
