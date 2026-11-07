//! Mock-server tests for the WebDAV backend.
//!
//! An in-memory RFC 4918 toy server (tiny_http, one thread per test case)
//! backs full roundtrips: stat / list / read_range / write_range / rename /
//! remove plus the negotiation and error paths. Real-NAS compatibility runs
//! are part of the M2 device matrix, not unit tests.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Cursor;
use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};
use std::sync::{Arc, Mutex};
use std::thread;

use tiny_http::{Header, Request, Response, Server, StatusCode};

use super::url::{decode_path, encode_path};
use super::{PartialMode, WebdavAuth, WebdavBackend};
use crate::backend::Backend;
use crate::entry::EntryKind;
use crate::error::VfsError;

const MTIME: &str = "Wed, 21 Oct 2015 07:28:00 GMT"; // 1445412480000 ms
const MTIME_MS: i64 = 1445412480000;

#[derive(Default)]
struct Fs {
    files: BTreeMap<String, Vec<u8>>,
    dirs: BTreeSet<String>,
}

struct State {
    fs: Mutex<Fs>,
    reject_patch: bool,
    reject_content_range: bool,
    /// Nextcloud-style: PATCH explodes with a rendered DAV exception body.
    patch_dav_error: bool,
    auth: Option<(String, String)>,
    flaky_hits: AtomicUsize,
}

impl State {
    fn new() -> Self {
        let mut fs = Fs::default();
        fs.dirs.insert("/".to_string());
        fs.dirs.insert("/docs".to_string());
        fs.dirs.insert("/docs/sub".to_string());
        fs.files
            .insert("/docs/hello.txt".to_string(), b"hello world".to_vec());
        fs.files
            .insert("/docs/sub/data.bin".to_string(), vec![7u8; 300]);
        Self {
            fs: Mutex::new(fs),
            reject_patch: false,
            reject_content_range: false,
            patch_dav_error: false,
            auth: None,
            flaky_hits: AtomicUsize::new(0),
        }
    }
}

fn multistatus(items: Vec<(&str, bool, Option<usize>, Option<&str>)>) -> String {
    let mut s = String::from(r#"<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">"#);
    for (path, is_dir, size, ctype) in items {
        let href = encode_path(path);
        s.push_str("<D:response><D:href>");
        s.push_str(&href);
        s.push_str(if is_dir { "/</D:href>" } else { "</D:href>" });
        s.push_str("<D:propstat><D:prop>");
        s.push_str(&format!(
            "<D:getlastmodified>{MTIME}</D:getlastmodified><D:resourcetype>{collection}</D:resourcetype>",
            collection = if is_dir { "<D:collection/>" } else { "" }
        ));
        if let Some(size) = size {
            s.push_str(&format!("<D:getcontentlength>{size}</D:getcontentlength>"));
        }
        if let Some(ctype) = ctype {
            s.push_str(&format!("<D:getcontenttype>{ctype}</D:getcontenttype>"));
        }
        s.push_str("</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>");
    }
    s.push_str("</D:multistatus>");
    s
}

fn propfind(state: &State, path: &str, depth: u8) -> String {
    let fs = state.fs.lock().unwrap();
    let mut items = Vec::new();
    if fs.dirs.contains(path) || path == "/" {
        items.push((path.to_string(), true, None, Some("httpd/unix-directory")));
        if depth == 1 {
            let prefix = if path == "/" {
                "/".to_string()
            } else {
                format!("{path}/")
            };
            for dir in &fs.dirs {
                if let Some(rest) = dir.strip_prefix(&prefix) {
                    if !rest.is_empty() && !rest.contains('/') {
                        items.push((dir.clone(), true, None, Some("httpd/unix-directory")));
                    }
                }
            }
            for (file, data) in &fs.files {
                if let Some(rest) = file.strip_prefix(&prefix) {
                    if !rest.is_empty() && !rest.contains('/') {
                        items.push((file.clone(), false, Some(data.len()), None));
                    }
                }
            }
        }
    } else if let Some(data) = fs.files.get(path) {
        items.push((path.to_string(), false, Some(data.len()), None));
    }
    multistatus(
        items
            .iter()
            .map(|(p, d, s, c)| (p.as_str(), *d, *s, *c))
            .collect(),
    )
}

fn header_value(request: &Request, name: &str) -> Option<String> {
    request
        .headers()
        .iter()
        .find(|h| h.field.as_str().to_ascii_lowercase() == name)
        .map(|h| h.value.as_str().to_string())
}

fn close(response: Response<Cursor<Vec<u8>>>) -> Response<Cursor<Vec<u8>>> {
    response.with_header(Header::from_bytes(&b"Connection"[..], &b"close"[..]).unwrap())
}

fn plain(status: u16, body: &str) -> Response<Cursor<Vec<u8>>> {
    close(Response::from_string(body).with_status_code(StatusCode(status)))
}

fn handle(state: &State, request: &mut Request) -> Response<Cursor<Vec<u8>>> {
    if let Some((user, pass)) = &state.auth {
        let expected = format!("Basic {}", base64_encode(&format!("{user}:{pass}")));
        if header_value(request, "authorization").as_deref() != Some(expected.as_str()) {
            return plain(401, "unauthorized");
        }
    }
    let method = request.method().to_string().to_ascii_uppercase();
    let raw_url = request.url().to_string();
    let path_only = raw_url.split('?').next().unwrap_or("/").to_string();
    let path = match decode_path(path_only.trim_end_matches('/')) {
        Ok(p) if p.is_empty() => "/".to_string(),
        Ok(p) => p,
        Err(_) => return plain(400, "bad encoding"),
    };

    match method.as_str() {
        "PROPFIND" => {
            let depth = header_value(request, "depth")
                .and_then(|d| d.parse().ok())
                .unwrap_or(1);
            let fs = state.fs.lock().unwrap();
            if !fs.dirs.contains(&path) && path != "/" && !fs.files.contains_key(&path) {
                drop(fs);
                return plain(404, "not found");
            }
            drop(fs);
            let body = propfind(state, &path, depth);
            close(
                Response::from_data(body.into_bytes())
                    .with_status_code(StatusCode(207))
                    .with_header(
                        Header::from_bytes(&b"Content-Type"[..], &b"application/xml"[..]).unwrap(),
                    ),
            )
        }
        "GET" => {
            // Always-failing route to drive the retry logic to exhaustion.
            if path == "/boom.txt" {
                state.flaky_hits.fetch_add(1, AtomicOrdering::SeqCst);
                return plain(500, "boom");
            }
            let fs = state.fs.lock().unwrap();
            let Some(data) = fs.files.get(&path) else {
                drop(fs);
                return plain(404, "not found");
            };
            let data = data.clone();
            drop(fs);
            match header_value(request, "range").and_then(|r| parse_range(&r)) {
                Some((from, to)) => {
                    if from as usize >= data.len() {
                        return plain(416, "range not satisfiable");
                    }
                    let to = (to as usize).min(data.len() - 1);
                    close(
                        Response::from_data(data[from as usize..=to].to_vec())
                            .with_status_code(StatusCode(206))
                            .with_header(
                                Header::from_bytes(
                                    &b"Content-Range"[..],
                                    format!("bytes {from}-{to}/{}", data.len()).as_bytes(),
                                )
                                .unwrap(),
                            ),
                    )
                }
                None => close(Response::from_data(data)),
            }
        }
        "PUT" => {
            if header_value(request, "if-none-match").as_deref() == Some("*") {
                let fs = state.fs.lock().unwrap();
                if fs.files.contains_key(&path) || fs.dirs.contains(&path) {
                    drop(fs);
                    return plain(412, "exists");
                }
            }
            let mut body = Vec::new();
            request.as_reader().read_to_end(&mut body).unwrap();
            let cr = header_value(request, "content-range").and_then(|c| parse_content_range(&c));
            let mut fs = state.fs.lock().unwrap();
            let existed = fs.files.contains_key(&path);
            match cr {
                Some(_) if state.reject_content_range => {
                    drop(fs);
                    plain(501, "content-range rejected")
                }
                Some((from, _)) => {
                    let entry = fs.files.entry(path).or_default();
                    let from = from as usize;
                    if entry.len() < from {
                        entry.resize(from, 0);
                    }
                    if entry.len() < from + body.len() {
                        entry.resize(from + body.len(), 0);
                    }
                    entry[from..from + body.len()].copy_from_slice(&body);
                    plain(if existed { 204 } else { 201 }, "")
                }
                None => {
                    fs.files.insert(path, body);
                    plain(if existed { 204 } else { 201 }, "")
                }
            }
        }
        "PATCH" => {
            if state.patch_dav_error {
                return close(
                    Response::from_data(
                        br#"<?xml version="1.0"?>
<d:error xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns">
  <s:exception>ValueError</s:exception>
  <s:message>hash_file(): Argument #1 must be a valid hashing algorithm</s:message>
</d:error>"#
                            .to_vec(),
                    )
                    .with_status_code(StatusCode(500)),
                );
            }
            if state.reject_patch {
                return plain(405, "PATCH not allowed");
            }
            let Some(range) = header_value(request, "x-update-range") else {
                return plain(400, "missing X-Update-Range");
            };
            let Some((from, _)) = parse_x_update_range(&range) else {
                return plain(400, "bad X-Update-Range");
            };
            let mut body = Vec::new();
            request.as_reader().read_to_end(&mut body).unwrap();
            let mut fs = state.fs.lock().unwrap();
            let Some(entry) = fs.files.get_mut(&path) else {
                drop(fs);
                return plain(404, "not found");
            };
            let from = from as usize;
            if entry.len() < from + body.len() {
                entry.resize(from + body.len(), 0);
            }
            entry[from..from + body.len()].copy_from_slice(&body);
            plain(200, "")
        }
        "MKCOL" => {
            let mut fs = state.fs.lock().unwrap();
            if fs.dirs.contains(&path) || fs.files.contains_key(&path) {
                drop(fs);
                return plain(405, "exists");
            }
            let parent = super::url::dav_parent(&path);
            if !fs.dirs.contains(&parent) {
                drop(fs);
                return plain(409, "no parent");
            }
            fs.dirs.insert(path);
            plain(201, "")
        }
        "MOVE" => {
            let Some(dest) = header_value(request, "destination") else {
                return plain(400, "missing Destination");
            };
            let dest_path = match reqwest::Url::parse(&dest) {
                Ok(u) => u.path().to_string(),
                Err(_) => dest,
            };
            let dest_path = decode_path(&dest_path).unwrap_or(dest_path);
            let mut fs = state.fs.lock().unwrap();
            if let Some(data) = fs.files.remove(&path) {
                fs.files.insert(dest_path, data);
                plain(204, "")
            } else if fs.dirs.contains(&path) {
                fs.dirs.remove(&path);
                fs.dirs.insert(dest_path.clone());
                let prefix = format!("{path}/");
                let old: Vec<String> = fs
                    .files
                    .keys()
                    .filter(|k| k.starts_with(&prefix))
                    .cloned()
                    .collect();
                for k in old {
                    if let Some(v) = fs.files.remove(&k) {
                        fs.files
                            .insert(k.replacen(&prefix, &format!("{dest_path}/"), 1), v);
                    }
                }
                plain(201, "")
            } else {
                drop(fs);
                plain(404, "not found")
            }
        }
        "DELETE" => {
            let mut fs = state.fs.lock().unwrap();
            if fs.files.remove(&path).is_some() {
                return plain(204, "");
            }
            if fs.dirs.remove(&path) {
                let prefix = format!("{path}/");
                let gone_files: Vec<String> = fs
                    .files
                    .keys()
                    .filter(|k| k.starts_with(&prefix))
                    .cloned()
                    .collect();
                for k in gone_files {
                    fs.files.remove(&k);
                }
                let gone_dirs: Vec<String> = fs
                    .dirs
                    .iter()
                    .filter(|d| d.starts_with(&prefix))
                    .cloned()
                    .collect();
                for d in gone_dirs {
                    fs.dirs.remove(&d);
                }
                return plain(204, "");
            }
            drop(fs);
            plain(404, "not found")
        }
        _ => plain(405, "unhandled"),
    }
}

/// `bytes=a-b`
fn parse_range(h: &str) -> Option<(u64, u64)> {
    let (from, to) = h.strip_prefix("bytes=")?.split_once('-')?;
    Some((from.parse().ok()?, to.parse().ok()?))
}

/// `bytes a-b/*` or `bytes a-b/n`
fn parse_content_range(h: &str) -> Option<(u64, u64)> {
    let unit = h.strip_prefix("bytes ")?;
    let (from, to) = unit.split('/').next()?.split_once('-')?;
    Some((from.parse().ok()?, to.parse().ok()?))
}

/// `bytes=a-b`
fn parse_x_update_range(h: &str) -> Option<(u64, u64)> {
    parse_range(h)
}

fn base64_encode(input: &str) -> String {
    // Tiny local encoder so the mock can assert on the exact Authorization
    // header without pulling a base64 dev-dependency.
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in input.as_bytes().chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(TABLE[(n >> 18) as usize & 63] as char);
        out.push(TABLE[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            TABLE[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            TABLE[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

/// Boot a mock server on a random port; returns `(base_url, state)`.
fn mock(state: State) -> (String, Arc<State>) {
    let state = Arc::new(state);
    let server = Server::http("127.0.0.1:0").unwrap();
    let addr = server.server_addr().to_ip().unwrap();
    let cloned = state.clone();
    thread::spawn(move || loop {
        let Ok(mut request) = server.recv() else {
            break;
        };
        let response = handle(&cloned, &mut request);
        if request.respond(response).is_err() {
            break;
        }
    });
    (format!("http://{addr}"), state)
}

fn backend(base_url: &str) -> WebdavBackend {
    WebdavBackend::new(base_url, WebdavAuth::None).unwrap()
}

#[tokio::test]
async fn stat_list_and_read_roundtrip() {
    let (base, _state) = mock(State::new());
    let b = backend(&base);

    let root = b.root_id();
    let root_stat = b.stat(&root).await.unwrap();
    assert_eq!(root_stat.kind, EntryKind::Directory);
    assert!(root_stat.parent.is_none());

    let listed = b.list(&root).await.unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].name, "docs");
    assert_eq!(listed[0].modified_ms, Some(MTIME_MS));
    assert_eq!(
        listed[0].parent.as_deref(),
        Some(root.as_str()),
        "parent must be the canonical root id"
    );

    let docs_id = listed[0].id.clone();
    let children = b.list(&docs_id).await.unwrap();
    assert_eq!(children.len(), 2);
    assert_eq!(children[0].name, "sub"); // directories sort first
    assert_eq!(children[1].name, "hello.txt");
    assert_eq!(children[1].size, 11);

    let hello = &children[1].id;
    assert_eq!(b.read_range(hello, 0, 5).await.unwrap(), b"hello");
    assert_eq!(b.read_range(hello, 6, 5).await.unwrap(), b"world");
    assert_eq!(b.read_range(hello, 6, 100).await.unwrap(), b"world");
    assert_eq!(b.read_range(hello, 11, 5).await.unwrap(), b"");
    assert_eq!(b.read_range(hello, 4096, 5).await.unwrap(), b"");

    // Deep file with an over-long range to force a short tail read.
    let data_id = format!("{docs_id}/sub/data.bin");
    assert_eq!(
        b.read_range(&data_id, 250, 60).await.unwrap(),
        vec![7u8; 50]
    );
}

#[tokio::test]
async fn create_write_rename_remove_flow() {
    let (base, state) = mock(State::new());
    let b = backend(&base);
    let root = b.root_id();

    let dir = b.create_dir(&root, "uploads").await.unwrap();
    assert_eq!(dir.kind, EntryKind::Directory);
    let err = b.create_dir(&root, "uploads").await.unwrap_err();
    assert!(matches!(err, VfsError::AlreadyExists(_)));

    let file = b.create_file(&dir.id, "a.txt").await.unwrap();
    let err = b.create_file(&dir.id, "a.txt").await.unwrap_err();
    assert!(matches!(err, VfsError::AlreadyExists(_)));

    // Engine-style sequential chunked upload: first chunk replaces, the rest
    // negotiate PATCH on a SabreDAV server.
    b.write_range(&file.id, 0, b"hello ").await.unwrap();
    b.write_range(&file.id, 6, b"brave ").await.unwrap();
    b.write_range(&file.id, 12, b"new world").await.unwrap();
    assert_eq!(b.mode(), PartialMode::Patch);
    b.truncate(&file.id, 21).await.unwrap(); // no-op: sizes already match

    let stat = b.stat(&file.id).await.unwrap();
    assert_eq!(stat.size, 21);
    assert_eq!(
        b.read_range(&file.id, 0, 64).await.unwrap(),
        b"hello brave new world"
    );

    // POSIX middle write keeps the tail.
    b.write_range(&file.id, 6, b"cruel ").await.unwrap();
    assert_eq!(
        b.read_range(&file.id, 0, 64).await.unwrap(),
        b"hello cruel new world"
    );

    let renamed = b.rename(&file.id, "b.txt").await.unwrap();
    assert_eq!(renamed.name, "b.txt");
    assert!(b.stat(&file.id).await.is_err());

    // Non-recursive remove must refuse a non-empty directory.
    let err = b.remove(&dir.id, false).await.unwrap_err();
    assert!(matches!(err, VfsError::Io(_)));
    b.remove(&renamed.id, false).await.unwrap();
    b.remove(&dir.id, false).await.unwrap();
    assert_eq!(state.fs.lock().unwrap().files.len(), 2);
}

#[tokio::test]
async fn overwrite_smaller_file_engine_flow() {
    let (base, _state) = mock(State::new());
    let b = backend(&base);
    let root = b.root_id();

    b.write_range(&format!("{root}big.bin"), 0, &vec![1u8; 400])
        .await
        .unwrap();
    // New content lands in three chunks, then the engine shrinks leftovers.
    b.write_range(&format!("{root}big.bin"), 0, &[2u8; 100])
        .await
        .unwrap();
    b.write_range(&format!("{root}big.bin"), 100, &[3u8; 100])
        .await
        .unwrap();
    b.write_range(&format!("{root}big.bin"), 200, &[4u8; 50])
        .await
        .unwrap();
    b.truncate(&format!("{root}big.bin"), 250).await.unwrap();

    let stat = b.stat(&format!("{root}big.bin")).await.unwrap();
    assert_eq!(stat.size, 250);
    let got = b
        .read_range(&format!("{root}big.bin"), 0, 512)
        .await
        .unwrap();
    assert_eq!(&got[..100], vec![2u8; 100]);
    assert_eq!(&got[100..200], vec![3u8; 100]);
    assert_eq!(&got[200..], vec![4u8; 50]);
}

#[tokio::test]
async fn content_range_fallback_when_patch_rejected() {
    let (base, _state) = mock(State {
        reject_patch: true,
        ..State::new()
    });
    let b = backend(&base);
    let root = b.root_id();
    let file = format!("{root}docs/hello.txt");

    b.write_range(&file, 6, b"webdav").await.unwrap();
    assert_eq!(b.mode(), PartialMode::ContentRangePut);
    assert_eq!(b.read_range(&file, 0, 16).await.unwrap(), b"hello webdav");
}

#[tokio::test]
async fn dav_error_body_on_patch_is_a_dialect_signal() {
    // Nextcloud answers PATCH with a rendered 500 DAV exception; that must be
    // read as "dialect unavailable", not as a retryable network fault.
    let (base, _state) = mock(State {
        patch_dav_error: true,
        ..State::new()
    });
    let b = backend(&base);
    let file = format!("{}docs/hello.txt", b.root_id());

    b.write_range(&file, 6, b"webdav").await.unwrap();
    assert_eq!(b.mode(), PartialMode::ContentRangePut);
    assert_eq!(b.read_range(&file, 0, 16).await.unwrap(), b"hello webdav");
}

#[tokio::test]
async fn unsupported_partial_writes_fail_loudly() {
    let (base, _state) = mock(State {
        reject_patch: true,
        reject_content_range: true,
        ..State::new()
    });
    let b = backend(&base);
    let root = b.root_id();
    let file = format!("{root}docs/hello.txt");

    let err = b.write_range(&file, 6, b"nope").await.unwrap_err();
    assert!(matches!(err, VfsError::Unsupported(_)), "{err}");
    // The file must be untouched.
    assert_eq!(b.read_range(&file, 0, 16).await.unwrap(), b"hello world");
}

#[tokio::test]
async fn error_paths_map_correctly() {
    let (base, _state) = mock(State::new());
    let b = backend(&base);
    let root = b.root_id();

    let err = b.stat(&format!("{root}missing.txt")).await.unwrap_err();
    assert!(matches!(err, VfsError::NotFound(_)));
    let err = b
        .read_range(&format!("{root}missing.txt"), 0, 1)
        .await
        .unwrap_err();
    assert!(matches!(err, VfsError::NotFound(_)));
    // MKCOL under a missing parent: RFC 409 -> NotFound(parent).
    let err = b
        .create_dir(&format!("{root}nope/deep"), "x")
        .await
        .unwrap_err();
    assert!(matches!(err, VfsError::NotFound(_)));
    let err = b.create_dir(&root, "a/b").await.unwrap_err();
    assert!(matches!(err, VfsError::InvalidName(_)));
}

#[tokio::test]
async fn auth_failure_is_permission_denied() {
    let (base, _state) = mock(State {
        auth: Some(("alice".into(), "secret".into())),
        ..State::new()
    });

    let unauthorized = WebdavBackend::new(&base, WebdavAuth::None).unwrap();
    let err = unauthorized
        .list(&unauthorized.root_id())
        .await
        .unwrap_err();
    assert!(matches!(err, VfsError::PermissionDenied(_)), "{err}");

    let ok = WebdavBackend::new(
        &base,
        WebdavAuth::Basic {
            username: "alice".into(),
            password: "secret".into(),
        },
    )
    .unwrap();
    assert_eq!(ok.list(&ok.root_id()).await.unwrap().len(), 1);
}

#[tokio::test]
async fn retries_exhaust_into_network_error() {
    let (base, state) = mock(State::new());
    let b = backend(&base);
    let err = b
        .read_range(&format!("{}boom.txt", b.root_id()), 0, 8)
        .await
        .unwrap_err();
    assert!(matches!(err, VfsError::Network(_)), "{err}");
    assert_eq!(state.flaky_hits.load(AtomicOrdering::SeqCst), 3);
}

#[tokio::test]
async fn percent_encoded_names_roundtrip() {
    let (base, _state) = mock(State::new());
    let b = backend(&base);
    let root = b.root_id();

    let dir = b.create_dir(&root, "我的 相册").await.unwrap();
    let file = b.create_file(&dir.id, "cat (1).jpg").await.unwrap();
    b.write_range(&file.id, 0, &[1, 2, 3]).await.unwrap();

    let listed = b.list(&dir.id).await.unwrap();
    assert_eq!(listed[0].name, "cat (1).jpg");
    assert_eq!(
        b.read_range(&listed[0].id, 0, 3).await.unwrap(),
        vec![1, 2, 3]
    );

    let renamed = b.rename(&file.id, "100%.jpg").await.unwrap();
    assert_eq!(renamed.name, "100%.jpg");
    assert_eq!(b.stat(&renamed.id).await.unwrap().size, 3);
}
