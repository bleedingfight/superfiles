//! NetBIOS 名称服务（NBNS）Node Status 查询：通过 UDP 137 端口拿到局域网
//! SMB 主机的 NetBIOS 主机名（工作站名）。用于扫描列表直接展示主机名，
//! 避免依赖局域网反向 DNS（家庭/办公网络通常未配置 PTR 记录）。

use std::net::UdpSocket;
use std::time::Duration;

/// 查询 `host` 的 NetBIOS 主机名；失败/超时返回 `None`。
/// 同步阻塞（UDP + 800ms 超时），调用方应放到后台线程。
pub fn netbios_name(host: &str) -> Option<String> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    let _ = socket.set_read_timeout(Some(Duration::from_millis(800)));
    let _ = socket.connect((host, 137u16));
    let query = node_status_query();
    socket.send(&query).ok()?;
    let mut buf = [0u8; 1024];
    let n = socket.recv(&mut buf).ok()?;
    parse_node_status_response(&buf[..n])
}

/// 构造 NBNS Node Status 查询包（50 字节）：通配名 `*` 的第一级编码。
fn node_status_query() -> Vec<u8> {
    let mut pkt = Vec::with_capacity(50);
    pkt.extend_from_slice(&rand_tid().to_be_bytes()); // transaction id
    pkt.extend_from_slice(&0x0000u16.to_be_bytes()); // flags (query)
    pkt.extend_from_slice(&1u16.to_be_bytes()); // qdcount = 1
    pkt.extend_from_slice(&0u16.to_be_bytes()); // ancount
    pkt.extend_from_slice(&0u16.to_be_bytes()); // nscount
    pkt.extend_from_slice(&0u16.to_be_bytes()); // arcount
                                                // 通配名 "*" + 15 空格，第一级编码为 32 字节，再加 2 字节 null 凑 34
    let mut name = [b' '; 16];
    name[0] = b'*';
    for &b in &name {
        pkt.push((b >> 4) + 0x41);
        pkt.push((b & 0x0F) + 0x41);
    }
    pkt.push(0x00);
    pkt.push(0x00);
    pkt.extend_from_slice(&0x0021u16.to_be_bytes()); // type = NBSTAT
    pkt.extend_from_slice(&0x0001u16.to_be_bytes()); // class = IN
    pkt
}

/// 解析 NODE STATUS RESPONSE，取第一个 `<00>`（工作站服务）名。
fn parse_node_status_response(data: &[u8]) -> Option<String> {
    if data.len() < 12 {
        return None;
    }
    let flags = u16::from_be_bytes([data[2], data[3]]);
    let is_response = flags & 0x8000 != 0;
    let rcode = flags & 0x000F;
    if !is_response || rcode != 0 {
        return None;
    }
    // header 12 + rr name 34 + type 2 + class 2 + ttl 4 + rdlength 2 = 56
    if data.len() < 57 {
        return None;
    }
    let rdlength = u16::from_be_bytes([data[54], data[55]]) as usize;
    let rdata = data.get(56..56 + rdlength)?;
    let num_names = *rdata.first()? as usize;
    // 每个名字 18 字节：16 字节名 + 2 字节 flags
    for i in 0..num_names {
        let name_bytes = rdata.get(1 + i * 18..1 + i * 18 + 16)?;
        let suffix = name_bytes[15];
        if suffix == 0x00 {
            let name = String::from_utf8_lossy(&name_bytes[..15])
                .trim_end_matches(' ')
                .to_string();
            if !name.is_empty() {
                return Some(name);
            }
        }
    }
    None
}

fn rand_tid() -> u16 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    (nanos & 0xFFFF) as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_node_status_response() {
        // 构造一个最小 NODE STATUS RESPONSE：一个名字 "NAS" (suffix 0x00)
        let mut resp = Vec::new();
        resp.extend_from_slice(&[0x12, 0x34]); // tid
        resp.extend_from_slice(&0x8400u16.to_be_bytes()); // flags: response + authoritative
        resp.extend_from_slice(&0u16.to_be_bytes()); // qdcount
        resp.extend_from_slice(&1u16.to_be_bytes()); // ancount = 1
        resp.extend_from_slice(&0u16.to_be_bytes()); // nscount
        resp.extend_from_slice(&0u16.to_be_bytes()); // arcount
        resp.extend_from_slice(&[0u8; 34]); // rr name
        resp.extend_from_slice(&0x0021u16.to_be_bytes()); // type NBSTAT
        resp.extend_from_slice(&0x0001u16.to_be_bytes()); // class IN
        resp.extend_from_slice(&0u32.to_be_bytes()); // ttl
        let mut rdata = Vec::new();
        rdata.push(1u8); // number_of_names
        let mut name = [b' '; 16];
        name[..3].copy_from_slice(b"NAS");
        name[15] = 0x00; // suffix <00>
        rdata.extend_from_slice(&name);
        rdata.extend_from_slice(&0u16.to_be_bytes()); // flags
        resp.extend_from_slice(&(rdata.len() as u16).to_be_bytes()); // rdlength
        resp.extend_from_slice(&rdata);

        assert_eq!(parse_node_status_response(&resp).as_deref(), Some("NAS"));
    }

    #[test]
    fn rejects_non_response() {
        let mut data = vec![0u8; 12];
        data[2] = 0x00; // flags: not a response
        data[3] = 0x00;
        assert!(parse_node_status_response(&data).is_none());
    }
}
