//! Identifier conventions.
//!
//! A single `String` identifies every entry, no matter which backend it lives
//! on. Two forms exist:
//!
//! * local paths: `/home/me/file.txt`, `C:\Users\me\file.txt`
//! * backend URIs: `smb://nas/share/movie.mkv`, `sftp://host/srv/data`
//!
//! `file://` and `local://` are accepted as explicit local aliases so that
//! deep links coming from other apps do not need special casing.

pub const LOCAL_SCHEME: &str = "local";

fn is_valid_scheme(scheme: &str) -> bool {
    !scheme.is_empty()
        && scheme
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.')
}

/// Split an entry id into `(scheme, path)`.
///
/// Unknown or malformed prefixes fall back to `local`, which keeps the API
/// forgiving for user typed paths.
pub fn split_id(id: &str) -> (&str, &str) {
    if let Some(rest) = id.strip_prefix("file://") {
        return (LOCAL_SCHEME, rest);
    }
    if let Some(rest) = id.strip_prefix("local://") {
        return (LOCAL_SCHEME, rest);
    }
    if let Some((scheme, rest)) = id.split_once("://") {
        if is_valid_scheme(scheme) {
            return (scheme, rest);
        }
    }
    (LOCAL_SCHEME, id)
}

/// Build a backend qualified id.
pub fn make_id(scheme: &str, path: &str) -> String {
    if scheme == LOCAL_SCHEME {
        path.to_string()
    } else {
        format!("{scheme}://{path}")
    }
}

/// Join a child name onto a parent id, preserving the scheme.
pub fn join(parent: &str, name: &str) -> String {
    if parent.is_empty() {
        return name.to_string();
    }
    let trimmed = parent.trim_end_matches('/');
    format!("{trimmed}/{name}")
}

/// Best effort parent id. Returns `None` for a backend root.
pub fn parent_of(id: &str) -> Option<String> {
    let (scheme, path) = split_id(id);
    let trimmed = path.trim_end_matches('/');
    match trimmed.rsplit_once('/') {
        Some((parent, _)) if !parent.is_empty() => Some(make_id(scheme, parent)),
        // "smb://host" -> no parent
        Some(_) => None,
        None => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_paths_stay_local() {
        assert_eq!(split_id("/home/me/a.txt"), (LOCAL_SCHEME, "/home/me/a.txt"));
        assert_eq!(split_id("C:\\tmp\\a.txt").0, LOCAL_SCHEME);
    }

    #[test]
    fn backend_uris_keep_scheme() {
        assert_eq!(split_id("smb://nas/pub"), ("smb", "nas/pub"));
        assert_eq!(make_id("smb", "nas/pub"), "smb://nas/pub");
    }

    #[test]
    fn join_and_parent() {
        assert_eq!(join("/a/b", "c"), "/a/b/c");
        assert_eq!(join("/a/b/", "c"), "/a/b/c");
        assert_eq!(join("smb://nas/pub", "c"), "smb://nas/pub/c");
        assert_eq!(
            parent_of("smb://nas/pub/c").as_deref(),
            Some("smb://nas/pub")
        );
        assert_eq!(parent_of("/a/b").as_deref(), Some("/a"));
    }
}
