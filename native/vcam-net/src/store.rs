//! Desktop pairing persistence (FR-UX-002, NFR-SEC-001).
//!
//! `pairings.v1`: magic `VCPKEY1\n`, u32 LE record count, then records containing
//! device_id[16], PK[32], u8 name length, UTF-8 name (at most 64 bytes, like HELLO).
//! No trailing bytes or duplicate IDs. This is a local format, not a VCP wire message.

use std::collections::HashMap;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};

#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};

use crate::{PairedDevice, PairingStore};

const MAGIC: &[u8; 8] = b"VCPKEY1\n";
const SNAPSHOT: &str = "pairings.v1";
const MAX_NAME: usize = 64;

/// Pairings in `<config_dir>/vcam-pairings/pairings.v1`.
///
/// Open once per active host: concurrent writers are not supported. The caller supplies an
/// existing user config directory and persists its host ID separately. Keys are not encrypted;
/// Unix permissions are 0700 for our subdirectory and 0600 for files, while Windows inherits
/// the user's config ACL. I/O errors are returned, never replaced by an ephemeral store.
///
/// Writes sync file contents before an atomic same-directory rename. This protects against
/// partial snapshots on process interruption; it does not promise directory durability on
/// power loss. An interrupted write may leave a private temporary file, ignored on open.
pub struct FileStore {
    directory: PathBuf,
    devices: HashMap<[u8; 16], PairedDevice>,
}

impl FileStore {
    pub fn open(config_dir: impl AsRef<Path>) -> io::Result<Self> {
        let directory = config_dir.as_ref().join("vcam-pairings");
        let mut builder = DirBuilder::new();
        #[cfg(unix)]
        builder.mode(0o700);
        match builder.create(&directory) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
        // Do not redirect key storage through a symlink or alter the caller's config directory.
        if !fs::symlink_metadata(&directory)?.is_dir() {
            return Err(invalid("pairing directory is not a directory"));
        }
        #[cfg(unix)]
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;

        let path = directory.join(SNAPSHOT);
        let devices = match fs::symlink_metadata(&path) {
            Ok(metadata) => {
                if !metadata.is_file() {
                    return Err(invalid("pairing snapshot is not a regular file"));
                }
                let file = File::open(&path)?;
                #[cfg(unix)]
                file.set_permissions(fs::Permissions::from_mode(0o600))?;
                load(file)?
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => HashMap::new(),
            Err(e) => return Err(e),
        };
        Ok(Self { directory, devices })
    }

    fn persist(&self, device: &PairedDevice) -> io::Result<()> {
        if device.device_name.len() > MAX_NAME {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "device name exceeds 64 bytes",
            ));
        }
        let count = self.devices.len() + usize::from(!self.devices.contains_key(&device.device_id));
        let count = u32::try_from(count)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "too many pairings"))?;
        let mut nonce = [0u8; 16];
        getrandom::fill(&mut nonce).map_err(io::Error::other)?;
        let temporary = self
            .directory
            .join(format!(".pairings-{:032x}.tmp", u128::from_le_bytes(nonce)));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o600);
        let file = options.open(&temporary)?;
        let result = (|| {
            let mut writer = BufWriter::new(file);
            writer.write_all(MAGIC)?;
            writer.write_all(&count.to_le_bytes())?;
            for stored in self
                .devices
                .values()
                .filter(|d| d.device_id != device.device_id)
                .chain(std::iter::once(device))
            {
                writer.write_all(&stored.device_id)?;
                writer.write_all(&stored.pk)?;
                writer.write_all(&[stored.device_name.len() as u8])?;
                writer.write_all(stored.device_name.as_bytes())?;
            }
            writer.flush()?;
            writer.get_ref().sync_all()?;
            drop(writer); // close before rename, including on Windows
            fs::rename(&temporary, self.directory.join(SNAPSHOT))
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }
}

impl PairingStore for FileStore {
    fn get(&self, device_id: &[u8; 16]) -> Option<PairedDevice> {
        self.devices.get(device_id).cloned()
    }

    fn put(&mut self, device: PairedDevice) -> io::Result<()> {
        self.persist(&device)?;
        self.devices.insert(device.device_id, device);
        Ok(())
    }
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn array<const N: usize>(reader: &mut impl Read) -> io::Result<[u8; N]> {
    let mut bytes = [0; N];
    reader.read_exact(&mut bytes)?;
    Ok(bytes)
}

fn load(file: File) -> io::Result<HashMap<[u8; 16], PairedDevice>> {
    let mut reader = BufReader::new(file);
    if &array::<8>(&mut reader)? != MAGIC {
        return Err(invalid("unknown pairing snapshot format"));
    }
    let count = u32::from_le_bytes(array(&mut reader)?);
    let mut devices = HashMap::new();
    for _ in 0..count {
        let device_id = array(&mut reader)?;
        let pk = array(&mut reader)?;
        let len = usize::from(array::<1>(&mut reader)?[0]);
        if len > MAX_NAME {
            return Err(invalid("device name exceeds 64 bytes"));
        }
        let mut name = [0; MAX_NAME];
        reader.read_exact(&mut name[..len])?;
        let device_name = std::str::from_utf8(&name[..len])
            .map_err(|_| invalid("invalid UTF-8 device name"))?
            .to_owned();
        if devices
            .insert(
                device_id,
                PairedDevice {
                    device_id,
                    device_name,
                    pk,
                },
            )
            .is_some()
        {
            return Err(invalid("duplicate paired device ID"));
        }
    }
    if reader.read(&mut [0])? != 0 {
        return Err(invalid("trailing pairing snapshot data"));
    }
    Ok(devices)
}
