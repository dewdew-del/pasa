use serde::Serialize;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Serialize, PartialEq, Debug)]
#[serde(rename_all = "snake_case")]
pub enum Direction { ToLaptop, ToPhone }

#[derive(Clone, Copy, Serialize, PartialEq, Debug)]
#[serde(rename_all = "snake_case")]
pub enum Status { Queued, Active, Done, Cancelled, Failed }

#[derive(Clone, Serialize, Debug)]
pub struct TransferView {
    pub id: String,
    pub name: String,
    pub size: u64,
    pub bytes: u64,
    pub direction: Direction,
    pub status: Status,
    pub speed: u64,
    pub path: Option<String>,
}

struct Entry {
    view: TransferView,
    source: Option<PathBuf>,
    cancel: Arc<AtomicBool>,
    started: Option<Instant>,
    finished: Option<Instant>,
}

impl Entry {
    fn live(&self) -> bool {
        matches!(self.view.status, Status::Queued | Status::Active)
    }
}

/// Shared state of every transfer this session, read by the server and the UI ticker.
pub struct Registry {
    entries: Mutex<Vec<Entry>>,
    dirty: AtomicBool,
    last_seen: Mutex<Option<Instant>>,
}

fn new_id() -> String {
    rand::random::<[u8; 8]>().iter().map(|b| format!("{b:02x}")).collect()
}

impl Registry {
    pub fn new() -> Self {
        Self { entries: Mutex::new(Vec::new()), dirty: AtomicBool::new(false), last_seen: Mutex::new(None) }
    }

    fn push(&self, name: String, size: u64, direction: Direction, status: Status, source: Option<PathBuf>) -> (String, Arc<AtomicBool>) {
        let id = new_id();
        let cancel = Arc::new(AtomicBool::new(false));
        let started = (status == Status::Active).then(Instant::now);
        let view = TransferView { id: id.clone(), name, size, bytes: 0, direction, status, speed: 0, path: None };
        self.entries.lock().unwrap().push(Entry { view, source, cancel: cancel.clone(), started, finished: None });
        self.dirty.store(true, Ordering::SeqCst);
        (id, cancel)
    }

    fn with<R>(&self, id: &str, f: impl FnOnce(&mut Entry) -> R) -> Option<R> {
        let mut es = self.entries.lock().unwrap();
        let e = es.iter_mut().find(|e| e.view.id == id)?;
        let r = f(e);
        self.dirty.store(true, Ordering::SeqCst);
        Some(r)
    }

    pub fn add_incoming(&self, name: &str, size: u64) -> (String, Arc<AtomicBool>) {
        self.push(name.to_string(), size, Direction::ToLaptop, Status::Active, None)
    }

    pub fn add_outgoing(&self, path: PathBuf) -> std::io::Result<String> {
        let meta = std::fs::metadata(&path)?;
        if !meta.is_file() {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "not a file"));
        }
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "file".into());
        Ok(self.push(name, meta.len(), Direction::ToPhone, Status::Queued, Some(path)).0)
    }

    pub fn queued_outgoing(&self) -> Vec<TransferView> {
        let es = self.entries.lock().unwrap();
        es.iter().filter(|e| e.view.direction == Direction::ToPhone && e.view.status == Status::Queued).map(|e| e.view.clone()).collect()
    }

    pub fn start_outgoing(&self, id: &str) -> Option<(PathBuf, Arc<AtomicBool>)> {
        self.with(id, |e| {
            if e.view.direction != Direction::ToPhone || e.view.status != Status::Queued {
                return None;
            }
            e.view.status = Status::Active;
            e.started = Some(Instant::now());
            Some((e.source.clone()?, e.cancel.clone()))
        })
        .flatten()
    }

    pub fn progress(&self, id: &str, bytes: u64) {
        self.with(id, |e| {
            e.view.bytes = bytes;
            if let Some(s) = e.started {
                let secs = s.elapsed().as_secs_f64();
                e.view.speed = if secs < 0.2 { 0 } else { (bytes as f64 / secs) as u64 };
            }
        });
    }

    pub fn finish(&self, id: &str, status: Status, path: Option<PathBuf>) {
        self.with(id, |e| {
            if !e.live() {
                return;
            }
            e.view.status = status;
            e.view.path = path.map(|p| p.to_string_lossy().into_owned());
            e.finished = Some(Instant::now());
        });
    }

    pub fn cancel(&self, id: &str) -> bool {
        self.with(id, |e| {
            if !e.live() {
                return false;
            }
            e.cancel.store(true, Ordering::SeqCst);
            if e.view.status == Status::Queued {
                e.view.status = Status::Cancelled;
                e.finished = Some(Instant::now());
            }
            true
        })
        .unwrap_or(false)
    }

    /// Live first in send order, then finished newest first.
    pub fn snapshot(&self) -> Vec<TransferView> {
        let es = self.entries.lock().unwrap();
        let mut fin: Vec<&Entry> = es.iter().filter(|e| !e.live()).collect();
        fin.sort_by(|a, b| b.finished.cmp(&a.finished));
        es.iter().filter(|e| e.live()).chain(fin).map(|e| e.view.clone()).collect()
    }

    pub fn take_dirty(&self) -> bool {
        self.dirty.swap(false, Ordering::SeqCst)
    }

    pub fn touch(&self) {
        *self.last_seen.lock().unwrap() = Some(Instant::now());
    }

    pub fn connected(&self) -> bool {
        self.last_seen.lock().unwrap().is_some_and(|t| t.elapsed() < Duration::from_secs(3))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::Ordering;

    #[test]
    fn outgoing_lifecycle() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("hi.txt");
        std::fs::write(&f, "hi").unwrap();
        let r = Registry::new();
        let id = r.add_outgoing(f.clone()).unwrap();
        let q = r.queued_outgoing();
        assert_eq!(q.len(), 1);
        assert_eq!((q[0].name.as_str(), q[0].size), ("hi.txt", 2));
        assert!(r.start_outgoing(&id).is_some());
        assert!(r.queued_outgoing().is_empty());
        assert!(r.start_outgoing(&id).is_none());
    }
    #[test]
    fn cancel_queued() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("a");
        std::fs::write(&f, "x").unwrap();
        let r = Registry::new();
        let id = r.add_outgoing(f).unwrap();
        assert!(r.cancel(&id));
        assert_eq!(r.snapshot()[0].status, Status::Cancelled);
        assert!(r.start_outgoing(&id).is_none());
    }
    #[test]
    fn cancel_active_sets_flag() {
        let r = Registry::new();
        let (id, flag) = r.add_incoming("a", 10);
        assert!(r.cancel(&id));
        assert!(flag.load(Ordering::SeqCst));
    }
    #[test]
    fn progress_marks_dirty_once() {
        let r = Registry::new();
        let (id, _) = r.add_incoming("a", 10);
        r.take_dirty();
        r.progress(&id, 5);
        assert!(r.take_dirty());
        assert!(!r.take_dirty());
        assert_eq!(r.snapshot()[0].bytes, 5);
    }
    #[test]
    fn snapshot_order_live_first_then_finished_newest() {
        let r = Registry::new();
        let (a, _) = r.add_incoming("a", 1);
        let (b, _) = r.add_incoming("b", 1);
        let (_c, _) = r.add_incoming("c", 1);
        r.finish(&a, Status::Done, None);
        r.finish(&b, Status::Done, None);
        let names: Vec<_> = r.snapshot().into_iter().map(|t| t.name).collect();
        assert_eq!(names, ["c", "b", "a"]);
    }
    #[test]
    fn connection() {
        let r = Registry::new();
        assert!(!r.connected());
        r.touch();
        assert!(r.connected());
    }
}
