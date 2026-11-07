//! `Range` header parsing (single ranges only; players never send
//! multipart ranges, so those fall back to a full response).

/// A satisfiable byte range, inclusive on both ends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ByteRange {
    pub start: u64,
    pub end: u64,
}

/// Parse `bytes=a-b`, `bytes=a-`, `bytes=-b` against a known file size.
///
/// Returns `None` when the header is absent, malformed, or multipart
/// (callers then stream the whole file), and `Some(None)` when the range
/// is syntactically fine but unsatisfiable against `size` (-> 416).
pub fn parse(header: Option<&str>, size: u64) -> Option<Option<ByteRange>> {
    let spec = header?.strip_prefix("bytes=")?.trim();
    if spec.contains(',') {
        return None; // multipart: treat as unparseable, serve full body
    }
    let (a, b) = spec.split_once('-')?;
    if a.is_empty() {
        // Suffix range: last b bytes.
        let suffix: u64 = b.parse().ok()?;
        if suffix == 0 {
            return Some(None);
        }
        let len = suffix.min(size);
        return Some(Some(ByteRange {
            start: size - len,
            end: size - 1,
        }));
    }
    let start: u64 = a.parse().ok()?;
    if start >= size {
        return Some(None);
    }
    let end = if b.is_empty() {
        size - 1
    } else {
        b.parse::<u64>().ok()?.min(size - 1)
    };
    if end < start {
        return Some(None);
    }
    Some(Some(ByteRange { start, end }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_all_forms() {
        assert_eq!(
            parse(Some("bytes=10-19"), 100),
            Some(Some(ByteRange { start: 10, end: 19 }))
        );
        assert_eq!(
            parse(Some("bytes=10-"), 100),
            Some(Some(ByteRange { start: 10, end: 99 }))
        );
        assert_eq!(
            parse(Some("bytes=-200"), 100),
            Some(Some(ByteRange { start: 0, end: 99 }))
        );
        assert_eq!(
            parse(Some("bytes=-20"), 100),
            Some(Some(ByteRange { start: 80, end: 99 }))
        );
        // End past EOF clamps to EOF.
        assert_eq!(
            parse(Some("bytes=90-9999"), 100),
            Some(Some(ByteRange { start: 90, end: 99 }))
        );
    }

    #[test]
    fn unsatisfiable_and_malformed() {
        assert_eq!(parse(Some("bytes=100-"), 100), Some(None));
        assert_eq!(parse(Some("bytes=50-40"), 100), Some(None));
        assert_eq!(parse(Some("bytes=-0"), 100), Some(None));
        // Malformed -> None (full response, lenient like nginx).
        assert_eq!(parse(Some("items=1-2"), 100), None);
        assert_eq!(parse(Some("bytes=1-2,5-9"), 100), None);
        assert_eq!(parse(None, 100), None);
    }
}
