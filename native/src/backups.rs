//! Private, bounded copies of the original 16 kHz mono recording.
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Write},
    os::{
        fd::AsRawFd,
        unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    },
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

pub struct Policy {
    pub count: usize,
    pub days: u64,
}

// Keep an open directory descriptor: subsequent operations cannot follow a
// replacement symlink. Only our strictly named regular files are ever pruned.
fn directory() -> io::Result<File> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or(io::ErrorKind::NotFound)?;
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home.join(".local/share"));
    fs::create_dir_all(&base)?;
    let mut parent = File::open(&base)?;
    for name in ["omarchy-dictation", "recordings"] {
        let path = PathBuf::from(format!("/proc/self/fd/{}", parent.as_raw_fd())).join(name);
        match fs::DirBuilder::new().mode(0o700).create(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
        parent = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
            .open(&path)?;
        let meta = parent.metadata()?;
        if meta.uid() != unsafe { libc::geteuid() }
            || meta.mode() & (if name == "recordings" { 0o077 } else { 0o022 }) != 0
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "recording directory must be private",
            ));
        }
    }
    if unsafe { libc::flock(parent.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(parent)
}
fn managed(name: &str) -> bool {
    name.strip_prefix("dictation-")
        .and_then(|s| s.strip_suffix(".wav"))
        .is_some_and(|s| {
            let parts: Vec<_> = s.split('-').collect();
            parts.len() == 2
                && parts
                    .iter()
                    .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
        })
}
fn root(dir: &File) -> PathBuf {
    PathBuf::from(format!("/proc/self/fd/{}", dir.as_raw_fd()))
}
fn prune_in(dir: &File, policy: &Policy, now: SystemTime) -> io::Result<()> {
    let root = root(dir);
    let mut files = Vec::new();
    for entry in fs::read_dir(&root)? {
        let entry = entry?;
        if !managed(&entry.file_name().to_string_lossy()) {
            continue;
        }
        let meta = fs::symlink_metadata(entry.path())?;
        if meta.is_file() && meta.uid() == unsafe { libc::geteuid() } {
            files.push((meta.modified()?, entry.file_name()));
        }
    }
    files.sort_by(|a, b| b.cmp(a));
    for (index, (time, name)) in files.iter().enumerate() {
        let expired = policy.days > 0
            && now.duration_since(*time).unwrap_or_default().as_secs() >= policy.days * 86400;
        if index >= policy.count || expired {
            fs::remove_file(root.join(name))?;
        }
    }
    Ok(())
}
pub fn prune(policy: &Policy) -> io::Result<PathBuf> {
    let dir = directory()?;
    if policy.count > 0 {
        prune_in(&dir, policy, SystemTime::now())?;
    }
    fs::read_link(root(&dir))
}
pub fn save(samples: &[f32], policy: &Policy) -> io::Result<()> {
    if samples.is_empty() {
        return Ok(());
    }
    let dir = directory()?;
    let now = SystemTime::now();
    let stamp = now
        .duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_nanos();
    let path = root(&dir).join(format!("dictation-{stamp}-{}.wav", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&path)?;
    let result = (|| {
        let bytes = (samples.len() * 2) as u32;
        file.write_all(b"RIFF")?;
        file.write_all(&(36 + bytes).to_le_bytes())?;
        file.write_all(b"WAVEfmt ")?;
        file.write_all(&16u32.to_le_bytes())?;
        file.write_all(&1u16.to_le_bytes())?;
        file.write_all(&1u16.to_le_bytes())?;
        file.write_all(&16000u32.to_le_bytes())?;
        file.write_all(&32000u32.to_le_bytes())?;
        file.write_all(&2u16.to_le_bytes())?;
        file.write_all(&16u16.to_le_bytes())?;
        file.write_all(b"data")?;
        file.write_all(&bytes.to_le_bytes())?;
        let pcm: Vec<u8> = samples
            .iter()
            .flat_map(|s| ((*s * 32768.0).clamp(-32768.0, 32767.0) as i16).to_le_bytes())
            .collect();
        file.write_all(&pcm)?;
        file.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(&path);
    }
    result?;
    prune_in(&dir, policy, now)
}

#[cfg(test)]
mod tests {
    use super::*;
    // All environment mutation is contained in this single test.
    #[test]
    fn original_wav_retention_and_safe_paths() {
        let tmp = std::env::temp_dir().join(format!("dictation-backups-{}", std::process::id()));
        fs::create_dir(&tmp).unwrap();
        std::env::set_var("XDG_DATA_HOME", &tmp);
        fs::create_dir(tmp.join("omarchy-dictation")).unwrap();
        let p = Policy { count: 2, days: 7 };
        save(&[-1.0, 0.0, 32767.0 / 32768.0], &p).unwrap();
        let dir = directory().unwrap();
        let folder = fs::read_link(root(&dir)).unwrap();
        drop(dir);
        let path = fs::read_dir(&folder)
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        let wav = fs::read(&path).unwrap();
        assert_eq!(&wav[..4], b"RIFF");
        assert_eq!(wav.len(), 50);
        assert_eq!(&wav[44..], &[0, 128, 0, 0, 255, 127]);
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
        fs::write(folder.join("keep.wav"), b"unrelated").unwrap();
        let outside = tmp.join("outside.wav");
        fs::write(&outside, b"safe").unwrap();
        std::os::unix::fs::symlink(&outside, folder.join("dictation-0-0.wav")).unwrap();
        for _ in 0..3 {
            save(&[0.25; 320], &p).unwrap();
        }
        let managed_files = || {
            fs::read_dir(&folder)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|e| {
                    e.file_type().unwrap().is_file() && managed(&e.file_name().to_string_lossy())
                })
                .count()
        };
        assert_eq!(managed_files(), 2);
        let dir = directory().unwrap();
        prune_in(
            &dir,
            &p,
            SystemTime::now() + std::time::Duration::from_secs(8 * 86400),
        )
        .unwrap();
        assert_eq!(managed_files(), 0);
        assert_eq!(fs::read(&outside).unwrap(), b"safe");
        assert!(folder.join("keep.wav").exists());
        drop(dir);
        fs::remove_dir_all(tmp.join("omarchy-dictation/recordings")).unwrap();
        std::os::unix::fs::symlink(&tmp, tmp.join("omarchy-dictation/recordings")).unwrap();
        assert!(save(&[0.2], &p).is_err());
        fs::remove_dir_all(&tmp).unwrap();
    }
}
