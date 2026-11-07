//! PROPFIND multistatus parsing (RFC 4918).
//!
//! Namespace prefixes vary across servers (`D:`, `d:`, `lp0:`...), so only
//! local names are matched. Each `<response>` may carry several `<propstat>`
//! blocks (typically one 200 plus one 404 listing missing props) — only props
//! from a 2xx `propstat` are merged into the resource.

use quick_xml::events::Event;
use quick_xml::{Reader, XmlVersion};

/// One parsed `<D:response>` element.
#[derive(Debug, Default, Clone)]
pub struct DavResponse {
    /// Percent-encoded href exactly as the server sent it.
    pub href: String,
    pub is_collection: bool,
    pub content_length: Option<u64>,
    /// Epoch milliseconds parsed from `getlastmodified` (RFC 1123).
    pub last_modified_ms: Option<i64>,
    pub content_type: Option<String>,
}

#[derive(Default)]
struct PropBuf {
    is_collection: bool,
    content_length: Option<u64>,
    last_modified: Option<String>,
    content_type: Option<String>,
    status_ok: Option<bool>,
}

impl PropBuf {
    fn merge_into(self, res: &mut DavResponse) {
        if self.status_ok.unwrap_or(true) {
            res.is_collection |= self.is_collection;
            if self.content_length.is_some() {
                res.content_length = self.content_length;
            }
            if self.last_modified.is_some() {
                res.last_modified_ms = self.last_modified.as_deref().and_then(parse_http_date);
            }
            if self.content_type.is_some() {
                res.content_type = self.content_type;
            }
        }
    }
}

/// Parse a `207 Multi-Status` body into raw responses.
pub fn parse_multistatus(body: &str) -> std::result::Result<Vec<DavResponse>, String> {
    let mut reader = Reader::from_str(body);
    reader.config_mut().trim_text(true);

    // DAV responses are XML 1.0 in practice; the declaration version changes
    // only entity decoding edge cases, never our element structure.
    const XML: XmlVersion = XmlVersion::Implicit1_0;

    let mut stack: Vec<String> = Vec::new();
    let mut out = Vec::new();
    let mut current: Option<DavResponse> = None;
    let mut props: Option<PropBuf> = None;

    loop {
        match reader.read_event().map_err(|e| e.to_string())? {
            Event::Start(e) => {
                let name = e.local_name().as_ref().to_string();
                match name.as_str() {
                    "response" => current = Some(DavResponse::default()),
                    "propstat" => props = Some(PropBuf::default()),
                    // Some servers emit `<collection/>` as a start/end pair.
                    "collection" => {
                        if let Some(p) = props.as_mut() {
                            p.is_collection = true;
                        }
                    }
                    _ => {}
                }
                stack.push(name);
            }
            Event::Empty(e) => {
                if e.local_name().as_ref() == "collection" {
                    if let Some(p) = props.as_mut() {
                        p.is_collection = true;
                    }
                }
            }
            Event::Text(e) => {
                let text = e.xml_content(XML).into_owned();
                if text.is_empty() {
                    continue;
                }
                let path: Vec<&str> = stack.iter().map(|s| s.as_str()).collect();
                match path.as_slice() {
                    [.., "response", "href"] => {
                        if let Some(r) = current.as_mut() {
                            r.href.push_str(&text);
                        }
                    }
                    [.., "propstat", "prop", "getcontentlength"] => {
                        if let Some(p) = props.as_mut() {
                            p.content_length = text.trim().parse::<u64>().ok();
                        }
                    }
                    [.., "propstat", "prop", "getlastmodified"] => {
                        if let Some(p) = props.as_mut() {
                            p.last_modified = Some(text);
                        }
                    }
                    [.., "propstat", "prop", "getcontenttype"] => {
                        if let Some(p) = props.as_mut() {
                            p.content_type = Some(text);
                        }
                    }
                    [.., "propstat", "status"] => {
                        if let Some(p) = props.as_mut() {
                            // "HTTP/1.1 200 OK" - any 2xx counts.
                            p.status_ok = Some(
                                text.split_whitespace()
                                    .nth(1)
                                    .and_then(|code| code.parse::<u16>().ok())
                                    .map(|code| (200..300).contains(&code))
                                    .unwrap_or(false),
                            );
                        }
                    }
                    _ => {}
                }
            }
            Event::End(e) => {
                let name = e.local_name();
                match name.as_ref() {
                    "propstat" => {
                        if let (Some(p), Some(r)) = (props.take(), current.as_mut()) {
                            p.merge_into(r);
                        }
                    }
                    "response" => {
                        if let Some(r) = current.take() {
                            out.push(r);
                        }
                    }
                    _ => {}
                }
                stack.pop();
            }
            Event::Eof => break,
            _ => {}
        }
    }

    if out.is_empty() && !body.trim().is_empty() {
        // A non-empty 207 body that yielded nothing is almost certainly a
        // parse mismatch rather than an empty response set.
        return Err("body contained no parsable responses".into());
    }
    Ok(out)
}

/// Parse an HTTP-date (`Wed, 21 Oct 2015 07:28:00 GMT`) into epoch ms.
///
/// RFC 1123 form is what every DAV server emits. Anything unparseable becomes
/// `None` (mtime is optional in [`crate::Entry`]).
pub fn parse_http_date(raw: &str) -> Option<i64> {
    let raw = raw.trim();
    let after_weekday = raw.find(", ").map(|i| &raw[i + 2..]).unwrap_or(raw);
    let mut it = after_weekday.split_whitespace();
    let day: i64 = it.next()?.parse().ok()?;
    let month = match it.next()? {
        "Jan" => 1,
        "Feb" => 2,
        "Mar" => 3,
        "Apr" => 4,
        "May" => 5,
        "Jun" => 6,
        "Jul" => 7,
        "Aug" => 8,
        "Sep" => 9,
        "Oct" => 10,
        "Nov" => 11,
        "Dec" => 12,
        _ => return None,
    };
    let year: i64 = it.next()?.parse().ok()?;
    let year = if year < 100 { year + 1900 } else { year };
    let time = it.next()?;
    let mut hms = time.split(':');
    let hour: i64 = hms.next()?.parse().ok()?;
    let min: i64 = hms.next()?.parse().ok()?;
    let sec: i64 = hms.next()?.parse().ok()?;

    let days = days_from_civil(year, month, day);
    Some((days * 86_400 + hour * 3600 + min * 60 + sec) * 1000)
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Hinnant's algorithm).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_nextcloud_style_multistatus() {
        let body = r#"<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/alice/Photos/</d:href>
    <d:propstat>
      <d:prop>
        <d:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</d:getlastmodified>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:getcontenttype>httpd/unix-directory</d:getcontenttype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
    <d:propstat>
      <d:prop><d:getcontentlength/><d:favorite/></d:prop>
      <d:status>HTTP/1.1 404 Not Found</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/alice/Photos/cat%20(1).jpg</d:href>
    <d:propstat>
      <d:prop>
        <d:getcontentlength>12345</d:getcontentlength>
        <d:getcontenttype>image/jpeg</d:getcontenttype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>"#;
        let res = parse_multistatus(body).unwrap();
        assert_eq!(res.len(), 2);

        let dir = &res[0];
        assert_eq!(dir.href, "/remote.php/dav/files/alice/Photos/");
        assert!(dir.is_collection);
        // getcontentlength only existed in the 404 propstat: must be ignored.
        assert_eq!(dir.content_length, None);
        assert_eq!(
            dir.last_modified_ms,
            Some(1445412480000) // 2015-10-21 07:28:00 UTC
        );

        let file = &res[1];
        assert!(!file.is_collection);
        assert_eq!(file.content_length, Some(12345));
        assert_eq!(file.content_type.as_deref(), Some("image/jpeg"));
    }

    #[test]
    fn tolerates_other_prefixes_and_missing_props() {
        let body = r#"<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/dav/a.txt</D:href><D:propstat>
    <D:prop><D:getcontentlength>0</D:getcontentlength><D:resourcetype/></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status>
  </D:propstat></D:response>
</D:multistatus>"#;
        let res = parse_multistatus(body).unwrap();
        assert_eq!(res.len(), 1);
        assert!(!res[0].is_collection);
        assert_eq!(res[0].content_length, Some(0));
        assert_eq!(res[0].last_modified_ms, None);
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse_multistatus("not xml").is_err());
        assert!(parse_multistatus("").is_ok());
    }

    #[test]
    fn http_dates() {
        assert_eq!(parse_http_date("Thu, 01 Jan 1970 00:00:00 GMT"), Some(0));
        assert_eq!(
            parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT"),
            Some(784111777000)
        );
        assert_eq!(parse_http_date("garbage"), None);
        // Roundtrip sanity for the current era (epoch from `date -u`).
        assert_eq!(
            parse_http_date("Mon, 02 Nov 2026 12:00:00 GMT"),
            Some(1793620800000)
        );
    }
}
