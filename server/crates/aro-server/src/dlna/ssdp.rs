//! SSDP discovery for the DLNA listener — the UPnP counterpart of the mDNS task in
//! `main.rs`. No crate exists for the *server* side of SSDP (the ecosystem's
//! `ssdp-client`/`rupnp` are control points), and the responder half of the protocol
//! is small: answer M-SEARCH datagrams on 239.255.255.250:1900 and send periodic
//! NOTIFY announcements.
//!
//! Sockets are built with `socket2` because both `SO_REUSEADDR` and `SO_REUSEPORT`
//! are needed on macOS to share port 1900 with any other UPnP daemon on the host.

use rand::Rng;
use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4},
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::net::UdpSocket;
use uuid::Uuid;

const SSDP_MULTICAST: Ipv4Addr = Ipv4Addr::new(239, 255, 255, 250);
const SSDP_PORT: u16 = 1900;
/// Renderers cache the device for this long; NOTIFY re-announces run at a third of it.
const MAX_AGE_SECONDS: u64 = 1800;
const NOTIFY_INTERVAL: std::time::Duration = std::time::Duration::from_secs(MAX_AGE_SECONDS / 3);
/// M-SEARCH MX values above this are clamped — the spec caps useful spread at a few
/// seconds and renderers give up waiting long before larger values.
const MAX_MX_SECONDS: u64 = 3;

/// Search targets this device answers for, in `ssdp:all` fan-out order.
const TARGETS: [&str; 4] = [
    "upnp:rootdevice",
    "urn:schemas-upnp-org:device:MediaServer:1",
    "urn:schemas-upnp-org:service:ContentDirectory:1",
    "urn:schemas-upnp-org:service:ConnectionManager:1",
];

pub struct Advertiser {
    hub_id: Uuid,
    http_port: u16,
    /// Concrete IP to advertise when `dlna.bind` names one; otherwise the
    /// interface is chosen per-request to suit the searcher's subnet.
    fixed_ip: Option<Ipv4Addr>,
    boot_id: u64,
}

impl Advertiser {
    pub fn new(hub_id: Uuid, bind: SocketAddr, http_port: u16) -> Self {
        let fixed_ip = match bind.ip() {
            IpAddr::V4(ip) if !ip.is_unspecified() => Some(ip),
            _ => None,
        };
        Self {
            hub_id,
            http_port,
            fixed_ip,
            boot_id: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|elapsed| elapsed.as_secs())
                .unwrap_or(0),
        }
    }

    fn location(&self, ip: Ipv4Addr) -> String {
        format!("http://{ip}:{}/rootDesc.xml", self.http_port)
    }

    fn usn(&self, target: &str) -> String {
        format!("uuid:{}::{target}", self.hub_id)
    }

    /// The IP to advertise to `searcher`: the fixed bind IP when configured,
    /// otherwise the private interface whose subnet contains the searcher, falling
    /// back to the first private IPv4 on the host.
    fn advertised_ip(&self, searcher: Option<Ipv4Addr>) -> Option<Ipv4Addr> {
        if let Some(ip) = self.fixed_ip {
            return Some(ip);
        }
        let interfaces = private_interfaces();
        if let Some(searcher) = searcher {
            for (ip, netmask) in &interfaces {
                if same_subnet(*ip, *netmask, searcher) {
                    return Some(*ip);
                }
            }
        }
        interfaces.first().map(|(ip, _)| *ip)
    }

    fn search_response(&self, target: &str, ip: Ipv4Addr) -> String {
        format!(
            "HTTP/1.1 200 OK\r\n\
             CACHE-CONTROL: max-age={MAX_AGE_SECONDS}\r\n\
             EXT:\r\n\
             LOCATION: {}\r\n\
             SERVER: {}\r\n\
             ST: {target}\r\n\
             USN: {}\r\n\
             BOOTID.UPNP.ORG: {}\r\n\
             CONFIGID.UPNP.ORG: 1\r\n\r\n",
            self.location(ip),
            server_header(),
            self.usn(target),
            self.boot_id,
        )
    }

    fn notify(&self, target: &str, ip: Ipv4Addr, alive: bool) -> String {
        format!(
            "NOTIFY * HTTP/1.1\r\n\
             HOST: {SSDP_MULTICAST}:{SSDP_PORT}\r\n\
             CACHE-CONTROL: max-age={MAX_AGE_SECONDS}\r\n\
             LOCATION: {}\r\n\
             NT: {target}\r\n\
             NTS: ssdp:{}\r\n\
             SERVER: {}\r\n\
             USN: {}\r\n\
             BOOTID.UPNP.ORG: {}\r\n\
             CONFIGID.UPNP.ORG: 1\r\n\r\n",
            self.location(ip),
            if alive { "alive" } else { "byebye" },
            server_header(),
            self.usn(target),
            self.boot_id,
        )
    }

    /// Targets an M-SEARCH `ST` requests from this device. `ssdp:all` fans out to
    /// every identity (uuid included); a specific match answers once; anything
    /// else — someone searching for a different device type — answers nothing.
    fn matched_targets(&self, st: &str) -> Vec<String> {
        let device_uuid = format!("uuid:{}", self.hub_id);
        if st.eq_ignore_ascii_case("ssdp:all") {
            let mut targets = vec![device_uuid];
            targets.extend(TARGETS.iter().map(|target| target.to_string()));
            return targets;
        }
        if st.eq_ignore_ascii_case(&device_uuid) {
            return vec![device_uuid];
        }
        TARGETS
            .iter()
            .find(|target| st.eq_ignore_ascii_case(target))
            .map(|target| vec![target.to_string()])
            .unwrap_or_default()
    }
}

fn server_header() -> String {
    format!(
        "{}/UPnP/1.0 Aro/{}",
        std::env::consts::OS,
        env!("CARGO_PKG_VERSION")
    )
}

fn private_interfaces() -> Vec<(Ipv4Addr, Ipv4Addr)> {
    let Ok(interfaces) = if_addrs::get_if_addrs() else {
        return Vec::new();
    };
    interfaces
        .into_iter()
        .filter(|interface| !interface.is_loopback())
        .filter_map(|interface| match interface.addr {
            if_addrs::IfAddr::V4(addr) if addr.ip.is_private() => Some((addr.ip, addr.netmask)),
            _ => None,
        })
        .collect()
}

fn same_subnet(ip: Ipv4Addr, netmask: Ipv4Addr, other: Ipv4Addr) -> bool {
    let mask = u32::from(netmask);
    (u32::from(ip) & mask) == (u32::from(other) & mask)
}

/// Parses the header block of an SSDP datagram into lowercase-keyed values.
fn parse_headers(datagram: &str) -> HashMap<String, String> {
    datagram
        .lines()
        .skip(1)
        .filter_map(|line| {
            let (name, value) = line.split_once(':')?;
            Some((name.trim().to_ascii_lowercase(), value.trim().to_string()))
        })
        .collect()
}

fn is_msearch(datagram: &str) -> bool {
    datagram
        .lines()
        .next()
        .is_some_and(|line| line.trim().eq_ignore_ascii_case("M-SEARCH * HTTP/1.1"))
}

fn mx_delay(headers: &HashMap<String, String>) -> std::time::Duration {
    let mx = headers
        .get("mx")
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(1)
        .clamp(1, MAX_MX_SECONDS);
    std::time::Duration::from_millis(rand::rng().random_range(0..mx * 1000))
}

/// Builds the port-1900 multicast listener. Separate from the sender so replies and
/// NOTIFYs originate from an ephemeral port, as renderers expect.
fn multicast_listener() -> std::io::Result<std::net::UdpSocket> {
    use socket2::{Domain, Protocol, Socket, Type};
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    socket.set_reuse_address(true)?;
    #[cfg(unix)]
    socket.set_reuse_port(true)?;
    socket.bind(&SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, SSDP_PORT).into())?;
    // Joining on INADDR_ANY covers only the default multicast interface, so the
    // group is joined explicitly on every private interface too — a multi-homed
    // host (or macOS with several active adapters) misses searches otherwise.
    socket.join_multicast_v4(&SSDP_MULTICAST, &Ipv4Addr::UNSPECIFIED)?;
    for (interface_ip, _) in private_interfaces() {
        if let Err(error) = socket.join_multicast_v4(&SSDP_MULTICAST, &interface_ip) {
            tracing::debug!(%interface_ip, %error, "SSDP multicast join skipped");
        }
    }
    socket.set_nonblocking(true)?;
    Ok(socket.into())
}

/// Runs SSDP advertisement until the task is dropped. Bind failures are returned so
/// the caller can log-and-continue — losing discovery should not take down `serve()`.
pub async fn run(advertiser: Advertiser) -> std::io::Result<()> {
    let listener = UdpSocket::from_std(multicast_listener()?)?;
    let sender = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).await?;
    let multicast: SocketAddr = SocketAddrV4::new(SSDP_MULTICAST, SSDP_PORT).into();

    // A byebye burst first: renderers that cached an identity from an unclean
    // shutdown drop it and treat the following alive as a fresh device.
    broadcast(&advertiser, &sender, multicast, false).await;
    broadcast(&advertiser, &sender, multicast, true).await;

    let mut announce = tokio::time::interval(NOTIFY_INTERVAL);
    announce.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    announce.tick().await; // immediate first tick already covered by the burst above

    let mut buffer = [0u8; 2048];
    loop {
        tokio::select! {
            _ = announce.tick() => {
                broadcast(&advertiser, &sender, multicast, true).await;
            }
            received = listener.recv_from(&mut buffer) => {
                let Ok((length, source)) = received else { continue };
                let SocketAddr::V4(source) = source else { continue };
                // LAN-only posture: ignore searches that did not originate on a
                // private or loopback network, mirroring config's bind validation.
                if !(source.ip().is_private() || source.ip().is_loopback()) {
                    continue;
                }
                let Ok(datagram) = std::str::from_utf8(&buffer[..length]) else { continue };
                if !is_msearch(datagram) {
                    continue;
                }
                let headers = parse_headers(datagram);
                let Some(st) = headers.get("st") else { continue };
                let targets = advertiser.matched_targets(st);
                if targets.is_empty() {
                    continue;
                }
                let Some(ip) = advertiser.advertised_ip(Some(*source.ip())) else { continue };
                tokio::time::sleep(mx_delay(&headers)).await;
                for target in targets {
                    let response = advertiser.search_response(&target, ip);
                    let _ = sender.send_to(response.as_bytes(), SocketAddr::V4(source)).await;
                }
            }
        }
    }
}

/// Multicasts one NOTIFY per advertised identity (alive or byebye), repeated twice
/// as the spec recommends for UDP loss.
async fn broadcast(
    advertiser: &Advertiser,
    sender: &UdpSocket,
    multicast: SocketAddr,
    alive: bool,
) {
    let Some(ip) = advertiser.advertised_ip(None) else {
        return;
    };
    let device_uuid = format!("uuid:{}", advertiser.hub_id);
    for _ in 0..2 {
        for target in std::iter::once(device_uuid.as_str()).chain(TARGETS) {
            let message = advertiser.notify(target, ip, alive);
            let _ = sender.send_to(message.as_bytes(), multicast).await;
        }
        tokio::time::sleep(std::time::Duration::from_millis(150)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn advertiser() -> Advertiser {
        Advertiser::new(Uuid::nil(), "0.0.0.0:4850".parse().unwrap(), 4850)
    }

    #[test]
    fn msearch_detection_is_case_insensitive_and_strict() {
        assert!(is_msearch("M-SEARCH * HTTP/1.1\r\nHOST: x\r\n\r\n"));
        assert!(is_msearch("m-search * http/1.1\r\n\r\n"));
        assert!(!is_msearch("NOTIFY * HTTP/1.1\r\n\r\n"));
        assert!(!is_msearch("GET / HTTP/1.1\r\n\r\n"));
    }

    #[test]
    fn headers_parse_case_insensitively() {
        let headers = parse_headers("M-SEARCH * HTTP/1.1\r\nSt: ssdp:all\r\nMX: 2\r\n\r\n");
        assert_eq!(headers.get("st").unwrap(), "ssdp:all");
        assert_eq!(headers.get("mx").unwrap(), "2");
    }

    #[test]
    fn ssdp_all_fans_out_to_every_identity() {
        let targets = advertiser().matched_targets("ssdp:all");
        assert_eq!(targets.len(), 5);
        assert_eq!(targets[0], format!("uuid:{}", Uuid::nil()));
        assert!(targets.contains(&"upnp:rootdevice".to_string()));
        assert!(targets.contains(&"urn:schemas-upnp-org:service:ContentDirectory:1".to_string()));
    }

    #[test]
    fn specific_and_unknown_targets() {
        let advertiser = advertiser();
        assert_eq!(
            advertiser.matched_targets("upnp:rootdevice"),
            vec!["upnp:rootdevice".to_string()]
        );
        assert_eq!(
            advertiser.matched_targets("URN:SCHEMAS-UPNP-ORG:DEVICE:MEDIASERVER:1"),
            vec!["urn:schemas-upnp-org:device:MediaServer:1".to_string()]
        );
        assert!(
            advertiser
                .matched_targets("urn:schemas-upnp-org:device:MediaRenderer:1")
                .is_empty()
        );
    }

    #[test]
    fn search_response_and_notify_are_well_formed() {
        let advertiser = advertiser();
        let ip = Ipv4Addr::new(192, 168, 1, 10);
        let response = advertiser.search_response("upnp:rootdevice", ip);
        assert!(response.starts_with("HTTP/1.1 200 OK\r\n"));
        assert!(response.contains("LOCATION: http://192.168.1.10:4850/rootDesc.xml\r\n"));
        assert!(response.contains("ST: upnp:rootdevice\r\n"));
        assert!(response.contains(&format!("USN: uuid:{}::upnp:rootdevice\r\n", Uuid::nil())));
        assert!(response.ends_with("\r\n\r\n"));

        let alive = advertiser.notify("upnp:rootdevice", ip, true);
        assert!(alive.starts_with("NOTIFY * HTTP/1.1\r\n"));
        assert!(alive.contains("NTS: ssdp:alive\r\n"));
        assert!(alive.contains("HOST: 239.255.255.250:1900\r\n"));
        let byebye = advertiser.notify("upnp:rootdevice", ip, false);
        assert!(byebye.contains("NTS: ssdp:byebye\r\n"));
    }

    #[test]
    fn fixed_bind_ip_wins_interface_selection() {
        let advertiser = Advertiser::new(Uuid::nil(), "192.168.7.7:4850".parse().unwrap(), 4850);
        assert_eq!(
            advertiser.advertised_ip(Some(Ipv4Addr::new(10, 0, 0, 9))),
            Some(Ipv4Addr::new(192, 168, 7, 7))
        );
    }

    #[test]
    fn mx_clamps_to_the_spec_ceiling() {
        let mut headers = HashMap::new();
        headers.insert("mx".to_string(), "600".to_string());
        for _ in 0..50 {
            assert!(mx_delay(&headers) < std::time::Duration::from_secs(MAX_MX_SECONDS));
        }
    }

    #[test]
    fn subnet_matching() {
        let mask = Ipv4Addr::new(255, 255, 255, 0);
        assert!(same_subnet(
            Ipv4Addr::new(192, 168, 1, 10),
            mask,
            Ipv4Addr::new(192, 168, 1, 200)
        ));
        assert!(!same_subnet(
            Ipv4Addr::new(192, 168, 1, 10),
            mask,
            Ipv4Addr::new(192, 168, 2, 200)
        ));
    }
}
