use crate::files::{sanitize_filename, unique_path};
use crate::pairing::keys_match;
use crate::transfers::{Registry, Status};
use axum::body::Body;
use axum::extract::{DefaultBodyLimit, Path as UrlPath, Query, Request, State};
use axum::http::{header, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use tokio::io::AsyncWriteExt;

#[derive(Clone)]
pub struct AppState {
    pub key: Arc<RwLock<String>>,
    pub registry: Arc<Registry>,
    pub receive_dir: PathBuf,
    pub name: String,
}

/// Serializes "pick a free name + rename" so two uploads of the same name can't collide.
static FINALIZE: Mutex<()> = Mutex::new(());

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/api/ping", get(ping))
        .route("/api/upload", post(upload).layer(DefaultBodyLimit::disable()))
        .route("/api/outbox", get(outbox))
        .route("/api/files/{id}", get(download))
        .layer(middleware::from_fn_with_state(state.clone(), auth))
        .with_state(state)
}

/// Binds 0.0.0.0 on the preferred port (or any free port if taken), serves in the background, returns the real port.
pub async fn serve(state: AppState, preferred_port: u16) -> std::io::Result<u16> {
    let listener = match tokio::net::TcpListener::bind(("0.0.0.0", preferred_port)).await {
        Ok(l) => l,
        Err(e) if e.kind() == std::io::ErrorKind::AddrInUse => tokio::net::TcpListener::bind(("0.0.0.0", 0)).await?,
        Err(e) => return Err(e),
    };
    let port = listener.local_addr()?.port();
    tokio::spawn(async move {
        let _ = axum::serve(listener, router(state)).await;
    });
    Ok(port)
}

async fn auth(State(s): State<AppState>, req: Request, next: Next) -> Response {
    let given = req.headers().get(header::AUTHORIZATION).and_then(|v| v.to_str().ok()).and_then(|v| v.strip_prefix("Bearer "));
    let ok = given.is_some_and(|g| keys_match(g, &s.key.read().unwrap()));
    if !ok {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    s.registry.touch();
    next.run(req).await
}

async fn ping(State(s): State<AppState>) -> Json<serde_json::Value> {
    Json(json!({ "name": s.name, "v": 1 }))
}

#[derive(Deserialize)]
struct UploadQuery {
    name: String,
    size: u64,
}

enum Fail {
    Cancelled,
    Io,
}

async fn write_body(reg: &Registry, id: &str, cancel: &AtomicBool, tmp: &Path, body: Body, size: u64) -> Result<(), Fail> {
    let mut f = tokio::fs::File::create(tmp).await.map_err(|_| Fail::Io)?;
    let mut stream = body.into_data_stream();
    let mut n = 0u64;
    while let Some(chunk) = stream.next().await {
        if cancel.load(Ordering::SeqCst) {
            return Err(Fail::Cancelled);
        }
        let chunk = chunk.map_err(|_| Fail::Io)?;
        n += chunk.len() as u64;
        if n > size {
            return Err(Fail::Io);
        }
        f.write_all(&chunk).await.map_err(|_| Fail::Io)?;
        reg.progress(id, n);
    }
    f.flush().await.map_err(|_| Fail::Io)?;
    if n == size { Ok(()) } else { Err(Fail::Io) }
}

async fn upload(State(s): State<AppState>, Query(q): Query<UploadQuery>, body: Body) -> Response {
    let name = sanitize_filename(&q.name);
    if tokio::fs::create_dir_all(&s.receive_dir).await.is_err() {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    let (id, cancel) = s.registry.add_incoming(&name, q.size);
    let tmp = s.receive_dir.join(format!(".{id}.pasa-part"));
    let result = write_body(&s.registry, &id, &cancel, &tmp, body, q.size).await; // file is closed when this returns
    let fail = match result {
        Ok(()) => {
            let dest = {
                let _g = FINALIZE.lock().unwrap();
                let dest = unique_path(&s.receive_dir, &name);
                std::fs::rename(&tmp, &dest).map(|_| dest)
            };
            match dest {
                Ok(dest) => {
                    let saved_as = dest.file_name().unwrap().to_string_lossy().into_owned();
                    s.registry.finish(&id, Status::Done, Some(dest));
                    return (StatusCode::CREATED, Json(json!({ "saved_as": saved_as }))).into_response();
                }
                Err(_) => Fail::Io,
            }
        }
        Err(f) => f,
    };
    let _ = tokio::fs::remove_file(&tmp).await;
    match fail {
        Fail::Cancelled => {
            s.registry.finish(&id, Status::Cancelled, None);
            StatusCode::GONE.into_response()
        }
        Fail::Io => {
            s.registry.finish(&id, Status::Failed, None);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn outbox(State(s): State<AppState>) -> Json<Vec<serde_json::Value>> {
    Json(s.registry.queued_outgoing().into_iter().map(|t| json!({ "id": t.id, "name": t.name, "size": t.size })).collect())
}

/// Marks the transfer failed/cancelled if the response stream is dropped before the last byte.
struct SendGuard {
    reg: Arc<Registry>,
    id: String,
    cancel: Arc<AtomicBool>,
    done: bool,
}

impl Drop for SendGuard {
    fn drop(&mut self) {
        if !self.done {
            let st = if self.cancel.load(Ordering::SeqCst) { Status::Cancelled } else { Status::Failed };
            self.reg.finish(&self.id, st, None);
        }
    }
}

async fn download(State(s): State<AppState>, UrlPath(id): UrlPath<String>) -> Response {
    if !s.registry.snapshot().iter().any(|t| t.id == id) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let Some((path, cancel)) = s.registry.start_outgoing(&id) else {
        return StatusCode::CONFLICT.into_response();
    };
    let guard = SendGuard { reg: s.registry.clone(), id, cancel, done: false };
    let (file, size) = match tokio::fs::File::open(&path).await {
        Ok(f) => match f.metadata().await {
            Ok(m) => (f, m.len()),
            Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        },
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(), // guard drop marks it failed
    };
    let reader = tokio_util::io::ReaderStream::new(file);
    let stream = futures_util::stream::unfold((reader, guard, 0u64), move |(mut r, mut g, mut sent)| async move {
        if g.cancel.load(Ordering::SeqCst) {
            return None; // ends the body short; guard marks Cancelled
        }
        match r.next().await {
            Some(Ok(bytes)) => {
                sent += bytes.len() as u64;
                g.reg.progress(&g.id, sent);
                if sent >= size {
                    g.done = true;
                    g.reg.finish(&g.id, Status::Done, None);
                }
                Some((Ok::<_, std::io::Error>(bytes), (r, g, sent)))
            }
            Some(Err(e)) => Some((Err(e), (r, g, sent))),
            None => {
                if size == 0 {
                    g.done = true;
                    g.reg.finish(&g.id, Status::Done, None);
                }
                None
            }
        }
    });
    ([(header::CONTENT_LENGTH, size.to_string())], Body::from_stream(stream)).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transfers::Status;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    fn app(dir: &std::path::Path) -> (Router, Arc<Registry>) {
        let registry = Arc::new(Registry::new());
        let state = AppState {
            key: Arc::new(RwLock::new("k".into())),
            registry: registry.clone(),
            receive_dir: dir.to_path_buf(),
            name: "TEST-PC".into(),
        };
        (router(state), registry)
    }

    fn req(method: &str, uri: &str, body: Body) -> Request<Body> {
        Request::builder().method(method).uri(uri).header("Authorization", "Bearer k").body(body).unwrap()
    }

    async fn text(res: axum::response::Response) -> String {
        String::from_utf8(res.into_body().collect().await.unwrap().to_bytes().to_vec()).unwrap()
    }

    fn files_in(dir: &std::path::Path) -> Vec<String> {
        std::fs::read_dir(dir).map(|r| r.map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect()).unwrap_or_default()
    }

    #[tokio::test]
    async fn ping_requires_key() {
        let d = tempfile::tempdir().unwrap();
        let (r, _) = app(d.path());
        let none = Request::builder().uri("/api/ping").body(Body::empty()).unwrap();
        assert_eq!(r.clone().oneshot(none).await.unwrap().status(), StatusCode::UNAUTHORIZED);
        let bad = Request::builder().uri("/api/ping").header("Authorization", "Bearer x").body(Body::empty()).unwrap();
        assert_eq!(r.clone().oneshot(bad).await.unwrap().status(), StatusCode::UNAUTHORIZED);
        let ok = r.oneshot(req("GET", "/api/ping", Body::empty())).await.unwrap();
        assert_eq!(ok.status(), StatusCode::OK);
        assert!(text(ok).await.contains("TEST-PC"));
    }

    #[tokio::test]
    async fn upload_saves_file() {
        let d = tempfile::tempdir().unwrap();
        let (r, reg) = app(d.path());
        let res = r.oneshot(req("POST", "/api/upload?name=a.txt&size=5", Body::from("hello"))).await.unwrap();
        assert_eq!(res.status(), StatusCode::CREATED);
        assert!(text(res).await.contains("\"saved_as\":\"a.txt\""));
        assert_eq!(std::fs::read_to_string(d.path().join("a.txt")).unwrap(), "hello");
        assert_eq!(reg.snapshot()[0].status, Status::Done);
    }

    #[tokio::test]
    async fn upload_larger_than_2mb() {
        let d = tempfile::tempdir().unwrap();
        let (r, _) = app(d.path());
        let size = 5 * 1024 * 1024;
        let res = r.oneshot(req("POST", &format!("/api/upload?name=big.bin&size={size}"), Body::from(vec![7u8; size]))).await.unwrap();
        assert_eq!(res.status(), StatusCode::CREATED);
        assert_eq!(std::fs::metadata(d.path().join("big.bin")).unwrap().len(), size as u64);
    }

    #[tokio::test]
    async fn upload_sanitizes_name() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("recv");
        let (r, _) = app(&dir);
        let res = r.oneshot(req("POST", "/api/upload?name=..%2F..%2Fx.txt&size=1", Body::from("x"))).await.unwrap();
        assert_eq!(res.status(), StatusCode::CREATED);
        assert!(dir.join("x.txt").exists());
        assert!(!root.path().join("x.txt").exists());
    }

    #[tokio::test]
    async fn upload_duplicate_name() {
        let d = tempfile::tempdir().unwrap();
        let (r, _) = app(d.path());
        let a = r.clone().oneshot(req("POST", "/api/upload?name=a.txt&size=1", Body::from("1"))).await.unwrap();
        let b = r.oneshot(req("POST", "/api/upload?name=a.txt&size=1", Body::from("2"))).await.unwrap();
        assert!(text(a).await.contains("\"a.txt\""));
        assert!(text(b).await.contains("\"a (1).txt\""));
    }

    #[tokio::test]
    async fn upload_short_body_fails() {
        let d = tempfile::tempdir().unwrap();
        let (r, reg) = app(d.path());
        let res = r.oneshot(req("POST", "/api/upload?name=a.txt&size=10", Body::from("hello"))).await.unwrap();
        assert_eq!(res.status(), StatusCode::INTERNAL_SERVER_ERROR);
        assert!(files_in(d.path()).is_empty(), "{:?}", files_in(d.path()));
        assert_eq!(reg.snapshot()[0].status, Status::Failed);
    }

    #[tokio::test]
    async fn upload_interrupted_leaves_no_file() {
        let d = tempfile::tempdir().unwrap();
        let (r, reg) = app(d.path());
        let chunks: Vec<Result<Vec<u8>, std::io::Error>> = vec![Ok(vec![1u8; 1024]), Err(std::io::Error::other("wifi dropped"))];
        let body = Body::from_stream(futures_util::stream::iter(chunks));
        let res = r.oneshot(req("POST", "/api/upload?name=a.txt&size=4096", body)).await.unwrap();
        assert!(!res.status().is_success());
        assert!(files_in(d.path()).is_empty(), "{:?}", files_in(d.path()));
        assert_eq!(reg.snapshot()[0].status, Status::Failed);
    }

    #[tokio::test]
    async fn outbox_and_download() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("hi.txt");
        std::fs::write(&src, "hi").unwrap();
        let (r, reg) = app(&d.path().join("recv"));
        let id = reg.add_outgoing(src).unwrap();
        let ob = text(r.clone().oneshot(req("GET", "/api/outbox", Body::empty())).await.unwrap()).await;
        assert!(ob.contains(&id) && ob.contains("hi.txt"), "{ob}");
        let res = r.clone().oneshot(req("GET", &format!("/api/files/{id}"), Body::empty())).await.unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        assert_eq!(text(res).await, "hi");
        assert_eq!(text(r.clone().oneshot(req("GET", "/api/outbox", Body::empty())).await.unwrap()).await, "[]");
        let again = r.clone().oneshot(req("GET", &format!("/api/files/{id}"), Body::empty())).await.unwrap();
        assert_eq!(again.status(), StatusCode::CONFLICT);
        let missing = r.oneshot(req("GET", "/api/files/nope", Body::empty())).await.unwrap();
        assert_eq!(missing.status(), StatusCode::NOT_FOUND);
        assert_eq!(reg.snapshot()[0].status, Status::Done);
    }

    #[tokio::test]
    async fn cancelled_outgoing_not_listed() {
        let d = tempfile::tempdir().unwrap();
        let src = d.path().join("a");
        std::fs::write(&src, "x").unwrap();
        let (r, reg) = app(&d.path().join("recv"));
        let id = reg.add_outgoing(src).unwrap();
        reg.cancel(&id);
        assert_eq!(text(r.clone().oneshot(req("GET", "/api/outbox", Body::empty())).await.unwrap()).await, "[]");
        let res = r.oneshot(req("GET", &format!("/api/files/{id}"), Body::empty())).await.unwrap();
        assert_eq!(res.status(), StatusCode::CONFLICT);
    }
}
