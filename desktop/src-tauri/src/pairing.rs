use std::net::{IpAddr, Ipv4Addr};
use std::path::Path;

fn new_key() -> String {
    rand::random::<[u8; 32]>().iter().map(|b| format!("{b:02x}")).collect()
}

fn valid_key(k: &str) -> bool {
    k.len() == 64 && k.chars().all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c))
}

/// Reads the saved pairing key; writes a new one if missing or broken.
pub fn load_or_create_key(path: &Path) -> std::io::Result<String> {
    match std::fs::read_to_string(path) {
        Ok(k) if valid_key(k.trim()) => Ok(k.trim().to_string()),
        _ => rotate_key(path),
    }
}

/// New key: every phone paired before must scan again.
pub fn rotate_key(path: &Path) -> std::io::Result<String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let k = new_key();
    std::fs::write(path, &k)?;
    Ok(k)
}

/// Constant-time compare so the key can't be guessed byte by byte from timing.
pub fn keys_match(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

pub fn is_lan_ipv4(ip: Ipv4Addr) -> bool {
    ip.is_private()
}

pub fn lan_ips() -> Vec<Ipv4Addr> {
    let mut ips: Vec<Ipv4Addr> = local_ip_address::list_afinet_netifas()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|(_, ip)| match ip {
            IpAddr::V4(v4) if is_lan_ipv4(v4) => Some(v4),
            _ => None,
        })
        .collect();
    ips.sort();
    ips.dedup();
    ips
}

pub fn clean_name(raw: &str) -> String {
    raw.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '-' }).collect()
}

pub fn laptop_name() -> String {
    std::env::var("COMPUTERNAME").map(|n| clean_name(&n)).unwrap_or_else(|_| "Laptop".into())
}

pub fn qr_payload(ips: &[Ipv4Addr], port: u16, key: &str, name: &str) -> String {
    let hosts: Vec<String> = ips.iter().map(|i| i.to_string()).collect();
    format!("pasa://connect?v=1&h={}&p={port}&k={key}&n={name}", hosts.join(","))
}

pub fn qr_svg(payload: &str) -> String {
    qrcode::QrCode::new(payload.as_bytes())
        .map(|c| c.render::<qrcode::render::svg::Color>().min_dimensions(240, 240).quiet_zone(true).build())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_is_created_then_kept() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("key");
        let k1 = load_or_create_key(&p).unwrap();
        assert_eq!(k1.len(), 64);
        assert!(k1.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        assert_eq!(load_or_create_key(&p).unwrap(), k1);
        let k2 = rotate_key(&p).unwrap();
        assert_ne!(k1, k2);
        assert_eq!(load_or_create_key(&p).unwrap(), k2);
    }
    #[test]
    fn keys_compare() {
        assert!(keys_match("ab", "ab"));
        assert!(!keys_match("ab", "ac"));
        assert!(!keys_match("ab", "abc"));
    }
    #[test]
    fn lan_filter() {
        for ok in ["192.168.43.1", "10.0.0.5", "172.16.0.1", "172.31.255.1"] {
            assert!(is_lan_ipv4(ok.parse().unwrap()), "{ok}");
        }
        for bad in ["127.0.0.1", "169.254.3.4", "8.8.8.8", "172.32.0.1"] {
            assert!(!is_lan_ipv4(bad.parse().unwrap()), "{bad}");
        }
    }
    #[test]
    fn payload_format() {
        let ips = ["192.168.1.5".parse().unwrap(), "10.0.0.2".parse().unwrap()];
        assert_eq!(
            qr_payload(&ips, 47800, "ab", "DEWDEW-PC"),
            "pasa://connect?v=1&h=192.168.1.5,10.0.0.2&p=47800&k=ab&n=DEWDEW-PC"
        );
    }
    #[test]
    fn name_is_cleaned() {
        assert_eq!(clean_name("My PC.local"), "My-PC-local");
    }
    #[test]
    fn svg_renders() {
        assert!(qr_svg("pasa://connect?v=1").starts_with("<?xml"));
    }
}
