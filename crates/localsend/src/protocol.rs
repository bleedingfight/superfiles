use std::collections::HashMap;

use serde::{Deserialize, Deserializer, Serialize};

fn default_version() -> String {
    "2.2".into()
}

fn string_or_default<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    Ok(Option::<String>::deserialize(deserializer)?.unwrap_or_default())
}

fn u16_or_zero<'de, D>(deserializer: D) -> Result<u16, D::Error>
where
    D: Deserializer<'de>,
{
    Ok(Option::<u16>::deserialize(deserializer)?.unwrap_or(0))
}

fn u64_or_zero<'de, D>(deserializer: D) -> Result<u64, D::Error>
where
    D: Deserializer<'de>,
{
    Ok(Option::<u64>::deserialize(deserializer)?.unwrap_or(0))
}

fn bool_or_false<'de, D>(deserializer: D) -> Result<bool, D::Error>
where
    D: Deserializer<'de>,
{
    Ok(Option::<bool>::deserialize(deserializer)?.unwrap_or(false))
}

/// Device description exchanged over discovery and `/register`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    #[serde(default, deserialize_with = "string_or_default")]
    pub alias: String,
    #[serde(default = "default_version", deserialize_with = "string_or_default")]
    pub version: String,
    #[serde(default)]
    pub device_model: Option<String>,
    #[serde(default)]
    pub device_type: Option<String>,
    #[serde(default, deserialize_with = "string_or_default")]
    pub fingerprint: String,
    #[serde(default, deserialize_with = "u16_or_zero")]
    pub port: u16,
    #[serde(default, deserialize_with = "string_or_default")]
    pub protocol: String,
    #[serde(default, deserialize_with = "bool_or_false")]
    pub download: bool,
    /// `Some(true)` for multicast announcements; responses set `Some(false)`
    /// or omit it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub announce: Option<bool>,
}

impl DeviceInfo {
    pub fn fingerprint_bytes(&self) -> Option<[u8; 32]> {
        let mut out = [0u8; 32];
        if self.fingerprint.len() != 64 {
            return None;
        }
        for (i, chunk) in self.fingerprint.as_bytes().chunks(2).enumerate() {
            let hi = (chunk[0] as char).to_digit(16)?;
            let lo = (chunk[1] as char).to_digit(16)?;
            out[i] = (hi * 16 + lo) as u8;
        }
        Some(out)
    }
}

/// Metadata body of `POST /prepare-upload`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepareUpload {
    #[serde(default)]
    pub info: Option<DeviceInfo>,
    #[serde(default)]
    pub files: Files,
}

/// LocalSend specifies a map keyed by file id; some clients serialize a list
/// instead. Accept both so a third-party sender doesn't get a 400.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Files {
    Map(HashMap<String, PreparedFile>),
    List(Vec<PreparedFile>),
}

impl Default for Files {
    fn default() -> Self {
        Self::Map(HashMap::new())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedFile {
    #[serde(default, deserialize_with = "string_or_default")]
    pub id: String,
    #[serde(default, deserialize_with = "string_or_default")]
    pub file_name: String,
    #[serde(default, deserialize_with = "u64_or_zero")]
    pub size: u64,
    #[serde(default, deserialize_with = "string_or_default")]
    pub file_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepareUploadResponse {
    pub session_id: String,
    pub files: HashMap<String, String>,
}

/// LocalSend device types; we pass the string through for unknown values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeviceType {
    Mobile,
    Desktop,
}

impl DeviceType {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Mobile => "mobile",
            Self::Desktop => "desktop",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_list_and_nullable_fields() {
        let json = r#"{
            "info": {},
            "files": [
                { "fileName": "DCIM/Camera/a.jpg", "size": null, "fileType": null },
                { "id": "b", "fileName": "b.pdf", "size": 12, "fileType": "application/pdf" }
            ]
        }"#;
        let req: PrepareUpload = serde_json::from_str(json).unwrap();
        match req.files {
            Files::List(files) => {
                assert_eq!(files.len(), 2);
                assert_eq!(files[0].file_name, "DCIM/Camera/a.jpg");
                assert_eq!(files[0].size, 0);
                assert_eq!(files[1].id, "b");
            }
            Files::Map(_) => panic!("expected list"),
        }
    }

    #[test]
    fn accepts_map_form() {
        let json = r#"{
            "files": { "x": { "id": "x", "fileName": "a.txt", "size": 1 } }
        }"#;
        let req: PrepareUpload = serde_json::from_str(json).unwrap();
        assert!(matches!(req.files, Files::Map(m) if m.len() == 1));
    }
}
