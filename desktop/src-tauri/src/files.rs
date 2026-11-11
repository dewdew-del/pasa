use std::path::{Path, PathBuf};

const RESERVED: [&str; 22] = [
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
    "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
];

/// Turns a name sent by the phone into one safe to create inside the receive folder.
pub fn sanitize_filename(raw: &str) -> String {
    let base = raw.rsplit(['/', '\\']).next().unwrap_or("");
    let cleaned: String = base
        .chars()
        .map(|c| if "<>:\"|?*".contains(c) || (c as u32) < 0x20 { '_' } else { c })
        .collect();
    let mut name = cleaned.trim_start_matches(' ').trim_end_matches(['.', ' ']).to_string();
    let stem = name.split('.').next().unwrap_or("");
    if RESERVED.iter().any(|r| r.eq_ignore_ascii_case(stem)) {
        name.insert(0, '_');
    }
    if name.len() > 200 {
        let (stem, ext) = split_ext(&name);
        let ext = ext.to_string();
        let mut cut = 200usize.saturating_sub(ext.len());
        while !stem.is_char_boundary(cut) {
            cut -= 1;
        }
        name = format!("{}{}", &stem[..cut], ext);
    }
    if name.is_empty() { "file".into() } else { name }
}

/// "a.jpg" -> ("a", ".jpg"); dotfiles and extensionless names have no extension.
fn split_ext(name: &str) -> (&str, &str) {
    match name.rfind('.') {
        Some(i) if i > 0 => (&name[..i], &name[i..]),
        _ => (name, ""),
    }
}

/// First free path: name, then "stem (1).ext", "stem (2).ext", ...
pub fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let first = dir.join(name);
    if !first.exists() {
        return first;
    }
    let (stem, ext) = split_ext(name);
    (1..)
        .map(|n| dir.join(format!("{stem} ({n}){ext}")))
        .find(|p| !p.exists())
        .unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_paths() {
        assert_eq!(sanitize_filename("../../etc/passwd"), "passwd");
        assert_eq!(sanitize_filename("C:\\Windows\\evil.exe"), "evil.exe");
    }
    #[test]
    fn replaces_bad_chars() {
        assert_eq!(sanitize_filename("a:b?.txt"), "a_b_.txt");
    }
    #[test]
    fn reserved_names() {
        assert_eq!(sanitize_filename("CON.txt"), "_CON.txt");
        assert_eq!(sanitize_filename("lpt1"), "_lpt1");
    }
    #[test]
    fn trims_trailing_dots_spaces() {
        assert_eq!(sanitize_filename("photo. "), "photo");
    }
    #[test]
    fn empty_becomes_file() {
        for s in ["", ".", "..", "/", "  "] {
            assert_eq!(sanitize_filename(s), "file", "{s:?}");
        }
    }
    #[test]
    fn keeps_unicode() {
        assert_eq!(sanitize_filename("larawan 📷.jpg"), "larawan 📷.jpg");
    }
    #[test]
    fn truncates_keeping_ext() {
        let n = sanitize_filename(&format!("{}.jpg", "a".repeat(300)));
        assert!(n.len() <= 200 && n.ends_with(".jpg"), "{n}");
    }
    #[test]
    fn unique_paths() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(unique_path(d.path(), "a.jpg"), d.path().join("a.jpg"));
        std::fs::write(d.path().join("a.jpg"), "").unwrap();
        assert_eq!(unique_path(d.path(), "a.jpg"), d.path().join("a (1).jpg"));
        std::fs::write(d.path().join("a (1).jpg"), "").unwrap();
        assert_eq!(unique_path(d.path(), "a.jpg"), d.path().join("a (2).jpg"));
        std::fs::write(d.path().join(".env"), "").unwrap();
        assert_eq!(unique_path(d.path(), ".env"), d.path().join(".env (1)"));
    }
}
