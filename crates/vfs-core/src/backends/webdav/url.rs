//! Entry id <-> server URL mapping for the WebDAV backend.
//!
//! An entry id looks like `webdav://<authority>/<dav-path>` where `<dav-path>`
//! is *relative to the mount root* and always starts with `/`. The mount root
//! itself may live below the server root (`https://nas:5006` shares it with
//! `https://nas:5006/webdav` differently), so PROPFIND hrefs must be mapped
//! back through the base path prefix.

use percent_encoding::{percent_decode_str, utf8_percent_encode, AsciiSet, CONTROLS};

use crate::error::{Result, VfsError};
use crate::uri::split_id;

use super::SCHEME;

/// Everything that may appear unescaped in a path segment keeps its bytes;
/// `?`/`#`/`%`/space/controls/non-ASCII get percent-encoded.
const PATH_ENCODE_SET: &AsciiSet = &CONTROLS
    .add(b' ')
    .add(b'"')
    .add(b'#')
    .add(b'%')
    .add(b'<')
    .add(b'>')
    .add(b'?')
    .add(b'`')
    .add(b'{')
    .add(b'}');

/// Percent-encode a dav path (leading `/`, raw segments). `/` is not in the
/// encode set so separators pass through, everything else unsafe is escaped.
pub fn encode_path(dav_path: &str) -> String {
    utf8_percent_encode(dav_path, PATH_ENCODE_SET).to_string()
}

/// Reverse of [`encode_path`]; invalid escapes surface as a hard error instead
/// of a garbled name (a garbled name would break `join`-based addressing).
pub fn decode_path(encoded: &str) -> Result<String> {
    percent_decode_str(encoded)
        .decode_utf8()
        .map(|s| s.into_owned())
        .map_err(|e| VfsError::Io(format!("invalid percent-encoding in href: {e}")))
}

/// Normalize a raw dav path: force a leading `/`, collapse `.` and duplicate
/// separators, resolve `..`. Traversal above the root is rejected like the
/// local jail so a crafted id cannot reach sibling mounts on the server.
pub fn normalize_dav_path(raw: &str) -> Result<String> {
    let raw = raw.trim();
    if raw.contains('\0') {
        return Err(VfsError::InvalidName("NUL byte in path".into()));
    }
    let mut segments: Vec<&str> = Vec::new();
    for part in raw.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if segments.pop().is_none() {
                    return Err(VfsError::PermissionDenied(format!(
                        "path escapes mount root: {raw}"
                    )));
                }
            }
            seg => segments.push(seg),
        }
    }
    if segments.is_empty() {
        Ok("/".to_string())
    } else {
        Ok(format!("/{}", segments.join("/")))
    }
}

/// Parsed mount root: shared by every request the backend sends.
#[derive(Debug, Clone)]
pub struct RootUrl {
    /// `https://nas:5006/dav` (no trailing slash) - request URLs append the
    /// encoded dav path directly.
    prefix: String,
    /// Server-side path of the mount root, `/dav`. PROPFIND hrefs are absolute
    /// server paths, so this prefix gets stripped on the way back to ids.
    base_path: String,
    /// `host[:port]`, the authority used in entry ids.
    authority: String,
}

impl RootUrl {
    pub fn parse(base_url: &str) -> Result<Self> {
        let url = reqwest::Url::parse(base_url.trim())
            .map_err(|e| VfsError::Unsupported(format!("invalid webdav base url: {e}")))?;
        match url.scheme() {
            "http" | "https" => {}
            scheme => {
                return Err(VfsError::Unsupported(format!(
                    "webdav base url must be http(s), got '{scheme}://'"
                )))
            }
        }
        let host = url
            .host_str()
            .ok_or_else(|| VfsError::Unsupported("webdav base url has no host".into()))?;
        let authority = match url.port() {
            Some(port) => format!("{host}:{port}"),
            None => host.to_string(),
        };
        let base_path = url.path().trim_end_matches('/').to_string();
        let prefix = url.as_str().trim_end_matches('/').to_string();
        Ok(Self {
            prefix,
            base_path,
            authority,
        })
    }

    pub fn authority(&self) -> &str {
        &self.authority
    }

    /// Absolute request URL for a normalized dav path.
    pub fn url_for(&self, dav_path: &str) -> String {
        // `encode_path` keeps '/' so joining stays literal.
        format!("{}{}", self.prefix, encode_path(dav_path))
    }

    /// Map a PROPFIND href (absolute server path or full URL, percent-encoded)
    /// back to a dav path. Returns `None` when the href points above the mount
    /// root, which callers treat as "not our entry".
    pub fn dav_path_for_href(&self, href: &str) -> Result<Option<String>> {
        let href = href.trim();
        // IIS style servers return absolute URLs in href; SabreDAV returns
        // path-only. Normalize both down to the raw server path.
        let server_path = if href.starts_with("http://") || href.starts_with("https://") {
            match reqwest::Url::parse(href) {
                Ok(url) => url.path().to_string(),
                Err(e) => {
                    return Err(VfsError::Io(format!(
                        "invalid href in multistatus: {e}: {href}"
                    )))
                }
            }
        } else {
            href.to_string()
        };
        let decoded = decode_path(&server_path)?;
        let relative = if self.base_path.is_empty() {
            decoded.as_str()
        } else if decoded == self.base_path {
            ""
        } else if let Some(rest) = decoded.strip_prefix(&format!("{}/", self.base_path)) {
            rest
        } else {
            return Ok(None);
        };
        // hrefs for collections end with `/`; that belongs to the server,
        // ids stay slashless (except the root itself).
        Ok(Some(normalize_dav_path(&format!("/{relative}"))?))
    }
}

/// `(authority-dav, normalized dav path)` for a backend id.
pub fn resolve_id(root: &RootUrl, id: &str) -> Result<String> {
    let (scheme, rest) = split_id(id);
    if scheme != SCHEME {
        return Err(VfsError::Unsupported(format!(
            "webdav backend cannot handle {id}"
        )));
    }
    let rest = rest.trim();
    let path = if rest == root.authority() {
        // Root can also be spelled `webdav://host` (see `uri::parent_of`).
        ""
    } else if let Some(path) = rest.strip_prefix(&format!("{}/", root.authority())) {
        path
    } else {
        return Err(VfsError::Unsupported(format!(
            "id belongs to another webdav authority: {id}"
        )));
    };
    normalize_dav_path(path)
}

/// Canonical id for a dav path: `webdav://<authority><dav-path>`, slashless
/// for non-root entries.
pub fn make_id(root: &RootUrl, dav_path: &str) -> String {
    crate::uri::make_id(SCHEME, &format!("{}{}", root.authority(), dav_path))
}

/// `/a/b` -> `/a`, `/a` -> `/`, root stays `/`.
pub fn dav_parent(dav_path: &str) -> String {
    match dav_path.rfind('/') {
        Some(0) | None => "/".to_string(),
        Some(idx) => dav_path[..idx].to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root(base: &str) -> RootUrl {
        RootUrl::parse(base).unwrap()
    }

    #[test]
    fn normalizes_traversal() {
        assert_eq!(normalize_dav_path("//a/./b/").unwrap(), "/a/b");
        assert_eq!(normalize_dav_path("").unwrap(), "/");
        assert_eq!(normalize_dav_path("/a/../b").unwrap(), "/b");
        let err = normalize_dav_path("/../../etc").unwrap_err();
        assert!(matches!(err, VfsError::PermissionDenied(_)));
    }

    #[test]
    fn encodes_segments_only() {
        assert_eq!(
            encode_path("/a b/中文.txt"),
            "/a%20b/%E4%B8%AD%E6%96%87.txt"
        );
        assert_eq!(encode_path("/100%/x?y"), "/100%25/x%3Fy");
        assert_eq!(
            decode_path("/a%20b/%E4%B8%AD%E6%96%87.txt").unwrap(),
            "/a b/中文.txt"
        );
    }

    #[test]
    fn root_url_round_trip() {
        let root = root("https://nas:5006/dav/");
        assert_eq!(root.authority(), "nas:5006");
        assert_eq!(root.url_for("/a/b.txt"), "https://nas:5006/dav/a/b.txt");
        assert_eq!(
            root.dav_path_for_href("/dav/a%20b/c.txt").unwrap(),
            Some("/a b/c.txt".to_string())
        );
        assert_eq!(
            root.dav_path_for_href("/dav/").unwrap(),
            Some("/".to_string())
        );
        // Above the mount root: not ours.
        assert_eq!(root.dav_path_for_href("/other/x").unwrap(), None);
        // IIS style absolute href.
        assert_eq!(
            root.dav_path_for_href("https://nas:5006/dav/docs/")
                .unwrap(),
            Some("/docs".to_string())
        );
    }

    #[test]
    fn root_url_without_prefix() {
        let root = root("https://192.168.1.10:5006");
        assert_eq!(root.url_for("/photos"), "https://192.168.1.10:5006/photos");
        assert_eq!(
            root.dav_path_for_href("/photos/a.jpg").unwrap(),
            Some("/photos/a.jpg".to_string())
        );
    }

    #[test]
    fn ids_resolve_against_authority() {
        let root = root("https://nas:5006/dav");
        assert_eq!(resolve_id(&root, "webdav://nas:5006").unwrap(), "/");
        assert_eq!(resolve_id(&root, "webdav://nas:5006/").unwrap(), "/");
        assert_eq!(resolve_id(&root, "webdav://nas:5006/a/b").unwrap(), "/a/b");
        assert!(resolve_id(&root, "smb://nas:5006/a").is_err());
        assert!(resolve_id(&root, "webdav://otherhost/a").is_err());
        assert_eq!(
            make_id(&root, "/docs"),
            "webdav://nas:5006/docs".to_string()
        );
        assert_eq!(make_id(&root, "/"), "webdav://nas:5006/".to_string());
    }
}
