//! The laptop's own Wi-Fi network (Wi-Fi Direct "legacy" mode), so the phone can join it
//! with one tap when the two aren't on the same Wi-Fi. Windows gives the laptop 192.168.137.1 on it.

use std::path::Path;

/// Network name "Pasa-<laptop>" (max 32 bytes) and a 16-char password, saved so phones can reconnect.
pub fn wifi_credentials(path: &Path, laptop_name: &str) -> std::io::Result<(String, String)> {
    let ssid: String = format!("Pasa-{laptop_name}").chars().take(32).collect();
    let pass = match std::fs::read_to_string(path) {
        Ok(p) if p.trim().len() == 16 => p.trim().to_string(),
        _ => {
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir)?;
            }
            let p: String = rand::random::<[u8; 8]>().iter().map(|b| format!("{b:02x}")).collect();
            std::fs::write(path, &p)?;
            p
        }
    };
    Ok((ssid, pass))
}

/// Starts the network on a background thread and keeps it up. Returns false if this Wi-Fi card can't.
#[cfg(windows)]
pub fn start(ssid: String, pass: String) -> bool {
    use windows::Devices::WiFiDirect::{WiFiDirectAdvertisementPublisher, WiFiDirectAdvertisementPublisherStatus as St};
    use windows::Security::Credentials::PasswordCredential;

    fn publisher(ssid: &str, pass: &str) -> windows::core::Result<WiFiDirectAdvertisementPublisher> {
        let p = WiFiDirectAdvertisementPublisher::new()?;
        let ad = p.Advertisement()?;
        ad.SetIsAutonomousGroupOwnerEnabled(true)?;
        let legacy = ad.LegacySettings()?;
        legacy.SetIsEnabled(true)?;
        legacy.SetSsid(&ssid.into())?;
        let cred = PasswordCredential::new()?;
        cred.SetPassword(&pass.into())?;
        legacy.SetPassphrase(&cred)?;
        p.Start()?;
        Ok(p)
    }

    let Ok(first) = publisher(&ssid, &pass) else { return false };
    std::thread::spawn(move || {
        let mut p = first;
        loop {
            std::thread::sleep(std::time::Duration::from_secs(10));
            // Windows can stop the network (sleep, Wi-Fi toggled); bring it back.
            if !matches!(p.Status(), Ok(St::Started)) {
                if let Ok(np) = publisher(&ssid, &pass) {
                    p = np;
                }
            }
        }
    });
    true
}

#[cfg(not(windows))]
pub fn start(_ssid: String, _pass: String) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credentials_are_created_then_kept() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("wifi");
        let (ssid, pass) = wifi_credentials(&p, "DELL").unwrap();
        assert_eq!(ssid, "Pasa-DELL");
        assert_eq!(pass.len(), 16);
        assert_eq!(wifi_credentials(&p, "DELL").unwrap(), (ssid, pass));
    }

    #[test]
    fn long_names_fit_wifi_limit() {
        let d = tempfile::tempdir().unwrap();
        let (ssid, _) = wifi_credentials(&d.path().join("wifi"), &"X".repeat(40)).unwrap();
        assert!(ssid.len() <= 32, "{ssid}");
    }
}
