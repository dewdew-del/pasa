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

/// Keeps the network up on a background thread: turns the laptop's Wi-Fi on if it's off and
/// restarts the network whenever it drops.
#[cfg(windows)]
pub fn start(ssid: String, pass: String) {
    use windows::Devices::Radios::{Radio, RadioKind, RadioState};
    use windows::Devices::WiFiDirect::{WiFiDirectAdvertisementPublisher, WiFiDirectAdvertisementPublisherStatus as St};
    use windows::Security::Credentials::PasswordCredential;

    /// The Pasa network rides on the Wi-Fi radio; switch it on if the user turned it off.
    fn wifi_radio_on() -> windows::core::Result<()> {
        Radio::RequestAccessAsync()?.join()?;
        for r in Radio::GetRadiosAsync()?.join()? {
            if r.Kind()? == RadioKind::WiFi && r.State()? != RadioState::On {
                r.SetStateAsync(RadioState::On)?.join()?;
                std::thread::sleep(std::time::Duration::from_secs(3)); // let the card come up
            }
        }
        Ok(())
    }

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

    // Off the UI thread: turning the radio on waits a few seconds.
    std::thread::spawn(move || {
        let mut current = None;
        loop {
            // Windows stops the network when Wi-Fi is switched off or the laptop sleeps; bring both back.
            let up = current.as_ref().is_some_and(|p: &WiFiDirectAdvertisementPublisher| matches!(p.Status(), Ok(St::Started)));
            if !up {
                let _ = wifi_radio_on();
                current = publisher(&ssid, &pass).ok();
            }
            std::thread::sleep(std::time::Duration::from_secs(10));
        }
    });
}

#[cfg(not(windows))]
pub fn start(_ssid: String, _pass: String) {}

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
