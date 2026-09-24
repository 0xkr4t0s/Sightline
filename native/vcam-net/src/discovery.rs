//! Pure-Rust DNS-SD for a listening host (NET-001; vcp.md §3).
//! The control server owns this daemon, not an individual paired device connection.

use std::io;
use std::net::SocketAddr;
use std::time::Duration;

use mdns_sd::{DaemonEvent, DaemonStatus, IfKind, Receiver, ServiceDaemon, ServiceInfo};
use vcam_protocol::PROTOCOL_VERSION;

pub(crate) struct Discovery {
    daemon: ServiceDaemon,
    events: Option<Receiver<DaemonEvent>>,
    shutdown: Option<Receiver<DaemonStatus>>,
    stopped: bool,
}

impl Discovery {
    pub(crate) fn start(services: [ServiceInfo; 2]) -> io::Result<Self> {
        let mut discovery = Self {
            daemon: ServiceDaemon::new().map_err(io::Error::other)?,
            events: None,
            shutdown: None,
            stopped: false,
        };
        discovery.events = Some(discovery.daemon.monitor().map_err(io::Error::other)?);
        discovery.publish(services)?;
        Ok(discovery)
    }

    pub(crate) fn publish(&self, services: [ServiceInfo; 2]) -> io::Result<()> {
        for service in services {
            self.daemon.register(service).map_err(io::Error::other)?;
        }
        Ok(())
    }

    /// Registration queues work; later socket/interface errors are delivered by the daemon.
    pub(crate) fn error(&self) -> Option<String> {
        let events = self.events.as_ref()?;
        while let Ok(event) = events.try_recv() {
            if let DaemonEvent::Error(error) = event {
                return Some(error.to_string());
            }
        }
        None
    }

    pub(crate) fn stop(&mut self) -> io::Result<()> {
        if self.stopped {
            return Ok(());
        }
        let reply = match &self.shutdown {
            Some(reply) => reply,
            None => self
                .shutdown
                .insert(self.daemon.shutdown().map_err(io::Error::other)?),
        };
        // mdns-sd sends goodbye packets and clears registrations before this acknowledgement.
        match reply.recv_timeout(Duration::from_millis(500)) {
            Ok(DaemonStatus::Shutdown) => {
                self.stopped = true;
                Ok(())
            }
            Ok(_) => Err(io::Error::other("mDNS daemon did not shut down")),
            Err(error) => Err(io::Error::new(io::ErrorKind::TimedOut, error)),
        }
    }
}

impl Drop for Discovery {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

/// Build both records before publishing either, so invalid metadata preserves the old pair.
pub(crate) fn services(
    host_id: [u8; 16],
    tcp: SocketAddr,
    udp: SocketAddr,
    host: &str,
    blend: &str,
) -> io::Result<[ServiceInfo; 2]> {
    let instance = format!("vcam-{:032x}-{}", u128::from_be_bytes(host_id), tcp.port());
    let hostname = format!("{instance}.local.");
    let version = PROTOCOL_VERSION.to_string();
    let tcp_port = tcp.port().to_string();
    let udp_port = udp.port().to_string();
    let properties = [
        ("vcp", version.as_str()),
        ("blend", blend),
        ("host", host),
        ("tcp", tcp_port.as_str()),
        ("udp", udp_port.as_str()),
    ];
    let make = |kind, addr: SocketAddr| -> io::Result<ServiceInfo> {
        let ips = if addr.ip().is_unspecified() {
            String::new()
        } else {
            addr.ip().to_string()
        };
        let mut info = ServiceInfo::new(
            kind,
            &instance,
            &hostname,
            ips.as_str(),
            addr.port(),
            &properties[..],
        )
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
        if addr.ip().is_unspecified() {
            info = info.enable_addr_auto();
            info.set_interfaces(vec![if addr.is_ipv4() {
                IfKind::IPv4
            } else {
                IfKind::IPv6
            }]);
        } else {
            info.set_interfaces(vec![IfKind::Addr(addr.ip())]);
        }
        Ok(info)
    };
    Ok([
        make("_vcam-ctl._tcp.local.", tcp)?,
        make("_vcam._udp.local.", udp)?,
    ])
}
