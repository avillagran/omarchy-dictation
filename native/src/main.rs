//! Local voice dictation for Omarchy Dictation (the omarchy-shell plugin).
//!
//!   omarchy-dictate models             installed and available models (JSON)
//!   omarchy-dictate download <model>   fetch a model, printing progress lines
//!   omarchy-dictate remove <model>     delete a downloaded model
//!   omarchy-dictate listen [options]   record until SIGINT, then print the text
//!   omarchy-dictate transcribe <file>  transcribe 16 kHz mono s16le raw or WAV
//!   omarchy-dictate backups [options]  prune saved audio (count 0: open/list only)
//!
//! listen options: --model <id>, --language <code|auto>, --prompt <text>,
//! --max-seconds <n>, --backup-count <0..500>, --backup-days <0..365>.
//! Backups are opt-in; count 0 disables saving, days 0 disables age expiry.
//! It lives only while one dictation runs: PipeWire records
//! from the start, the model loads alongside, and the process exits after
//! printing one result. SIGINT stops and transcribes; SIGTERM cancels.
//! Every stdout line is one JSON object; errors are one short code on stderr.
mod backups;
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::atomic::{AtomicBool, AtomicI32, Ordering},
    thread,
    time::{Duration, Instant},
};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

const RATE: usize = 16_000;

struct Model {
    id: &'static str,
    file: &'static str,
    size: u64,
    sha256: &'static str,
}
// Multilingual whisper.cpp models from ggerganov/whisper.cpp; sizes and hashes
// are the Hugging Face LFS objects. q8_0 runs about three times faster than
// q5_1 on ARM NEON (small: ~1.2 s for a 10 s clip on an M2 Pro) for the same text.
const MODELS: &[Model] = &[
    Model { id: "base", file: "ggml-base-q8_0.bin", size: 81_768_585, sha256: "c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9" },
    Model { id: "small", file: "ggml-small-q8_0.bin", size: 264_464_607, sha256: "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f" },
    // Maximum: large-v3-turbo, for strong accents; about four times slower than small.
    Model { id: "turbo", file: "ggml-large-v3-turbo-q8_0.bin", size: 874_188_075, sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1" },
];
const DEFAULT_MODEL: &str = "small";
// Pinned to one revision of the model repository; each file is also checked by
// size and SHA-256 before it is used.
const SOURCE: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/";

static STOP: AtomicBool = AtomicBool::new(false);
static CANCEL: AtomicBool = AtomicBool::new(false);
static RECORDER: AtomicI32 = AtomicI32::new(0);

extern "C" fn on_signal(sig: libc::c_int) {
    if sig == libc::SIGINT || sig == libc::SIGUSR1 {
        STOP.store(true, Ordering::SeqCst);
    } else {
        CANCEL.store(true, Ordering::SeqCst);
    }
    // Closing the recorder ends the read loop at once.
    let pid = RECORDER.load(Ordering::SeqCst);
    if pid > 0 {
        unsafe { libc::kill(pid, libc::SIGTERM) };
    }
}

fn fail(code: &str) -> ! {
    eprintln!("{code}");
    std::process::exit(1)
}
fn emit(line: String) {
    let mut out = io::stdout().lock();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}
fn quote(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn data_home() -> PathBuf {
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/share"))
}
fn models_dir() -> PathBuf {
    data_home().join("omarchy-dictation/models")
}
/// A model is used from here, or read in place from Omarchy T3 Code's folder
/// when that app already downloaded it (same files, same checksums).
fn model_path(m: &Model) -> Option<PathBuf> {
    [models_dir(), data_home().join("omarchy-t3-code/dictation")]
        .into_iter()
        .map(|dir| dir.join(m.file))
        .find(|path| fs::metadata(path).is_ok_and(|md| md.len() == m.size))
}
fn model(id: &str) -> &'static Model {
    MODELS.iter().find(|m| m.id == id).unwrap_or_else(|| fail("unknown_model"))
}
fn installed(m: &Model) -> bool {
    model_path(m).is_some()
}

fn list() {
    let items: Vec<String> = MODELS
        .iter()
        .map(|m| {
            // Shared: read from Omarchy T3 Code's folder, so remove leaves it alone.
            let shared = model_path(m).is_some_and(|p| !p.starts_with(models_dir()));
            format!("{{\"id\":{},\"sizeBytes\":{},\"installed\":{},\"shared\":{}}}", quote(m.id), m.size, installed(m), shared)
        })
        .collect();
    let recorder = Command::new("pw-record").arg("--version").stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|s| s.success());
    // The version ties this build to the plugin's source (manifest.json).
    emit(format!("{{\"models\":[{}],\"default\":{},\"recorder\":{},\"version\":{}}}", items.join(","), quote(DEFAULT_MODEL), recorder, quote(env!("CARGO_PKG_VERSION"))));
}

fn sha256(path: &Path) -> io::Result<String> {
    let mut file = fs::File::open(path)?;
    let mut hash = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hash.update(&buf[..n]);
    }
    Ok(hash.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

fn download(m: &Model) {
    let dir = models_dir();
    fs::create_dir_all(&dir).unwrap_or_else(|_| fail("local_error"));
    let target = dir.join(m.file);
    if installed(m) {
        emit(format!("{{\"type\":\"done\",\"model\":{}}}", quote(m.id)));
        return;
    }
    let part = dir.join(format!("{}.part", m.file));
    let mut curl = Command::new("curl")
        .args(["--fail", "--silent", "--location", "--proto", "=https", "--proto-redir", "=https", "--retry", "2", "--continue-at", "-", "--max-filesize"])
        .arg(m.size.to_string())
        .arg("--output")
        .arg(&part)
        .arg(format!("{SOURCE}{}", m.file))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap_or_else(|_| fail("download_unavailable"));
    RECORDER.store(curl.id() as i32, Ordering::SeqCst);
    let status = loop {
        if let Some(status) = curl.try_wait().unwrap_or(None) {
            break status;
        }
        let bytes = fs::metadata(&part).map(|md| md.len()).unwrap_or(0);
        // Never more than the model's size, whatever the server says.
        if bytes > m.size {
            let _ = curl.kill();
            let _ = fs::remove_file(&part);
            fail("download_corrupt");
        }
        emit(format!("{{\"type\":\"progress\",\"bytes\":{bytes},\"total\":{}}}", m.size));
        thread::sleep(Duration::from_millis(250));
    };
    if CANCEL.load(Ordering::SeqCst) {
        std::process::exit(130);
    }
    if !status.success() {
        fail("download_failed");
    }
    if fs::metadata(&part).map(|md| md.len()).unwrap_or(0) != m.size || sha256(&part).ok().as_deref() != Some(m.sha256) {
        let _ = fs::remove_file(&part);
        fail("download_corrupt");
    }
    fs::rename(&part, &target).unwrap_or_else(|_| fail("local_error"));
    emit(format!("{{\"type\":\"done\",\"model\":{}}}", quote(m.id)));
}

fn load(m: &Model) -> WhisperContext {
    try_load(m).unwrap_or_else(|code| fail(code))
}
fn try_load(m: &Model) -> Result<WhisperContext, &'static str> {
    // OMARCHY_DICTATE_MODEL_FILE swaps in another ggml file, for benchmarks.
    let path = match std::env::var_os("OMARCHY_DICTATE_MODEL_FILE") {
        Some(file) => PathBuf::from(file),
        None => model_path(m).ok_or("model_missing")?,
    };
    WhisperContext::new_with_params(path.to_str().ok_or("local_error")?, WhisperContextParameters::default())
        .map_err(|_| "model_invalid")
}

fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    (samples.iter().map(|s| s * s).sum::<f32>() / samples.len() as f32).sqrt()
}
fn level(samples: &[f32]) -> f32 {
    let db = 20.0 * rms(samples).max(1e-6).log10();
    ((db + 60.0) / 60.0).clamp(0.0, 1.0)
}

/// Cuts leading and trailing silence and shortens every pause inside to 0.6 s;
/// None when nothing in the clip rises above the room's noise, so Whisper never
/// sees a silent clip (it invents captions). A long pause, often exact zeros
/// from a mic's noise gate, makes Whisper drop what was said after it.
fn speech(samples: &[f32]) -> Option<Vec<f32>> {
    let frame = RATE * 30 / 1000;
    let energies: Vec<f32> = samples.chunks(frame).map(rms).collect();
    if energies.is_empty() {
        return None;
    }
    let mut sorted = energies.clone();
    sorted.sort_by(|a, b| a.total_cmp(b));
    // Measured against this clip's own voice: a quiet microphone still speaks
    // well above its pauses, and a fixed level would count its words as pauses.
    // Percentiles 10 and 98 retain a short phrase after a very long pause.
    let floor = sorted[sorted.len() / 10];
    let voice = sorted[sorted.len() * 49 / 50];
    if voice < 0.002 {
        return None;
    }
    let threshold = (floor * 3.0).max(voice / 8.0).max(0.001);
    let first = energies.iter().position(|e| *e > threshold)?;
    let last = energies.iter().rposition(|e| *e > threshold)?;
    // A lone click is not speech: ask for about 120 ms above the threshold.
    if energies[first..=last].iter().filter(|e| **e > threshold).count() < 4 {
        return None;
    }
    let pad = RATE / 4;
    let start = (first * frame).saturating_sub(pad);
    let end = ((last + 1) * frame + pad).min(samples.len());
    let keep = RATE * 3 / 5 / frame;
    let mut out = Vec::with_capacity(end - start);
    let mut quiet = 0;
    for (i, chunk) in samples[..end].chunks(frame).enumerate().skip(start / frame) {
        quiet = if energies[i] > threshold { 0 } else { quiet + 1 };
        if quiet <= keep {
            out.extend_from_slice(chunk);
        }
    }
    // Whisper hears a quiet microphone better at a normal level.
    let peak = out.iter().fold(0.0f32, |m, s| m.max(s.abs()));
    if peak > 0.0 && peak < 0.5 {
        let gain = (0.5 / peak).min(20.0);
        out.iter_mut().for_each(|s| *s *= gain);
    }
    Some(out)
}

/// Longest piece handed to Whisper at once. Its window is 30 s; a longer
/// clip makes it slide the window itself, and what sits in the second window
/// comes back cut mid-word or not at all. Cutting here keeps every piece
/// inside one window.
const PIECE: usize = RATE * 25;
/// How far before the nominal cut the quietest spot is looked for.
const PIECE_SEARCH: usize = RATE * 3 / 2;
/// A cut sits in the middle of the quietest 120 ms: the closure of a stop
/// consonant is near-silent for 30–80 ms, a pause between words lasts longer.
const QUIET_FRAMES: usize = 6;

/// Splits a clip into consecutive pieces of at most `PIECE` samples, each
/// ending in the quietest stretch of the 1.5 s before the nominal length.
fn pieces(audio: &[f32]) -> Vec<(usize, usize)> {
    let frame = RATE * 20 / 1000;
    let mut out = Vec::new();
    let mut start = 0;
    while audio.len() - start > PIECE {
        let nominal = start + PIECE;
        let energies: Vec<f32> = audio[nominal - PIECE_SEARCH..nominal].chunks_exact(frame).map(rms).collect();
        let mut best = (energies.len() - QUIET_FRAMES, f32::INFINITY);
        for i in 0..=energies.len() - QUIET_FRAMES {
            let sum: f32 = energies[i..i + QUIET_FRAMES].iter().sum();
            if sum <= best.1 {
                best = (i, sum);
            }
        }
        let cut = nominal - PIECE_SEARCH + (best.0 * frame + (best.0 + QUIET_FRAMES) * frame) / 2;
        out.push((start, cut));
        start = cut;
    }
    out.push((start, audio.len()));
    out
}

/// Joins the pieces' texts. A piece cut mid-sentence tends to end in a period
/// the speaker never made; it goes when the next piece carries on in lowercase.
fn join(parts: &[String]) -> String {
    let mut out = String::new();
    for part in parts.iter().filter(|p| !p.is_empty()) {
        if !out.is_empty() {
            let lowercase = part.chars().next().is_some_and(|c| c.is_lowercase());
            if lowercase && out.ends_with('.') && !out.ends_with("..") {
                out.pop();
            }
            out.push(' ');
        }
        out.push_str(part);
    }
    out
}

// Captions Whisper is known to invent from noise or silence.
const INVENTED: &[&str] = &[
    "subtítulos realizados por la comunidad de amara.org",
    "subtítulos por la comunidad de amara.org",
    "gracias por ver el video",
    "gracias por ver",
    "¡suscríbete!",
    "suscríbete al canal",
    "thank you for watching",
    "thanks for watching",
    "please subscribe",
    "you",
];
fn clean(text: &str) -> String {
    let mut out = String::new();
    let mut depth = 0;
    for c in text.chars() {
        match c {
            '[' | '(' => depth += 1,
            ']' | ')' if depth > 0 => depth -= 1,
            c if depth == 0 => out.push(c),
            _ => {}
        }
    }
    let out = out.split_whitespace().collect::<Vec<_>>().join(" ");
    let bare = out.trim_matches(|c: char| c.is_ascii_punctuation() || c == ' ').to_lowercase();
    if INVENTED.iter().any(|p| bare == p.trim_end_matches(['.', '!'])) {
        return String::new();
    }
    out
}

struct Options {
    model: &'static Model,
    language: String,
    prompt: String,
    max_seconds: u64,
    traditional: bool,
    backup_count: usize,
    backup_days: u64,
}
fn options(args: &[String]) -> Options {
    let mut o = Options { model: model(DEFAULT_MODEL), language: "auto".into(), prompt: String::new(), max_seconds: 120, traditional: false, backup_count: 0, backup_days: 7 };
    let mut i = 0;
    while i < args.len() {
        let value = args.get(i + 1).cloned().unwrap_or_default();
        match args[i].as_str() {
            "--backup-count" => o.backup_count = value.parse::<usize>().ok().filter(|n| *n <= 500).unwrap_or_else(|| fail("bad_arguments")),
            "--backup-days" => o.backup_days = value.parse::<u64>().ok().filter(|n| *n <= 365).unwrap_or_else(|| fail("bad_arguments")),
            "--model" => o.model = model(&value),
            "--language" => o.language = value,
            "--prompt" => o.prompt = value.chars().take(600).collect(),
            "--max-seconds" => o.max_seconds = value.parse().unwrap_or(120).clamp(5, 600),
            "--chinese" => o.traditional = match value.as_str() { "traditional" => true, "simplified" => false, _ => fail("bad_arguments") },
            _ => fail("bad_arguments"),
        }
        i += 2;
    }
    if !(o.language == "auto" || (o.language.len() <= 3 && o.language.chars().all(|c| c.is_ascii_lowercase()))) {
        fail("bad_language");
    }
    o
}

fn transcribe(ctx: &WhisperContext, samples: &[f32], o: &Options) -> (String, String) {
    let Some(voice) = speech(samples) else {
        return (String::new(), String::new());
    };
    // The language is detected once, on the first piece, so the later pieces
    // of one dictation cannot each decide on a different one.
    let mut language = o.language.clone();
    let mut parts = Vec::new();
    for (start, end) in pieces(&voice) {
        let piece = &voice[start..end];
        if start > 0 && speech(piece).is_none() {
            continue;
        }
        let (mut text, detected) = decode(ctx, piece, &language, &o.prompt, false);
        // Keep the plugin's script hint after automatic Chinese detection.
        let chinese_prompt = if (language == "zh" || detected == "zh") && !o.prompt.chars().any(is_cjk) {
            let hint = if o.traditional { "以下是普通話的句子。" } else { "以下是普通话的句子。" };
            Some(if o.prompt.is_empty() { hint.to_string() } else { format!("{hint} {}", o.prompt) })
        } else { None };
        let prompt = chinese_prompt.as_deref().unwrap_or(&o.prompt);
        let piece_language = if chinese_prompt.is_some() { "zh" } else { &language };
        if chinese_prompt.is_some() {
            text = decode(ctx, piece, piece_language, prompt, false).0;
        }
        if text.is_empty() && piece.len() >= RATE {
            // Greedy decoding sometimes returns nothing for real speech; a
            // beam search over the full window usually recovers it.
            text = decode(ctx, piece, piece_language, prompt, true).0;
        }
        if language == "auto" && !detected.is_empty() {
            language = detected;
        }
        parts.push(text);
    }
    (join(&parts), if language == "auto" { String::new() } else { language })
}

fn is_cjk(c: char) -> bool {
    matches!(c as u32, 0x4E00..=0x9FFF | 0x3400..=0x4DBF)
}

fn decode(ctx: &WhisperContext, piece: &[f32], language: &str, prompt: &str, beam: bool) -> (String, String) {
    // whisper.cpp ignores clips under a second.
    let mut audio = piece.to_vec();
    if audio.len() < RATE + RATE / 10 {
        audio.resize(RATE + RATE / 10, 0.0);
    }
    let mut state = ctx.create_state().unwrap_or_else(|_| fail("model_invalid"));
    let mut params = FullParams::new(if beam { SamplingStrategy::BeamSearch { beam_size: 5, patience: -1.0 } } else { SamplingStrategy::Greedy { best_of: 1 } });
    let threads = std::env::var("OMARCHY_DICTATE_THREADS").ok().and_then(|v| v.parse().ok()).unwrap_or_else(|| thread::available_parallelism().map(|n| n.get()).unwrap_or(4).clamp(1, 8));
    params.set_n_threads(threads as i32);
    params.set_language(Some(language));
    params.set_translate(false);
    params.set_no_context(true);
    params.set_single_segment(true);
    params.set_no_timestamps(true);
    params.set_suppress_blank(true);
    params.set_suppress_nst(true);
    params.set_temperature(0.0);
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    if !prompt.is_empty() {
        params.set_initial_prompt(prompt);
    }
    // The encoder costs the same for every clip unless told how long it is:
    // one audio context step is 20 ms, and 1500 covers Whisper's 30 s window.
    // A retry gets the full window so a too-small one cannot repeat its output.
    let ctx_steps = match std::env::var("OMARCHY_DICTATE_AUDIO_CTX").ok().as_deref() {
        Some("full") => 0,
        _ if beam => 0,
        _ => (audio.len() / 320 + 64).min(1500) as i32,
    };
    if ctx_steps > 0 && ctx_steps < 1500 {
        params.set_audio_ctx(ctx_steps);
    }
    state.full(params, &audio).unwrap_or_else(|_| fail("transcription_failed"));
    let mut text = String::new();
    for segment in state.as_iter() {
        if let Ok(s) = segment.to_str_lossy() {
            text.push_str(&s);
        }
    }
    let language = whisper_rs::get_lang_str(state.full_lang_id_from_state()).unwrap_or("").to_string();
    (clean(&text), language)
}

fn result(text: &str, language: &str, seconds: f32, started: Instant) {
    emit(format!(
        "{{\"type\":\"text\",\"text\":{},\"language\":{},\"seconds\":{:.1},\"elapsedMs\":{}}}",
        quote(text),
        quote(language),
        seconds,
        started.elapsed().as_millis()
    ));
}

/// A muted source still records, only zeros: say so, so the panel can tell the
/// user instead of showing a flat wave.
fn muted() -> bool {
    Command::new("wpctl")
        .args(["get-volume", "@DEFAULT_AUDIO_SOURCE@"])
        .stderr(Stdio::null())
        .output()
        .is_ok_and(|o| String::from_utf8_lossy(&o.stdout).contains("[MUTED]"))
}

fn record(max_seconds: u64) -> (Child, Vec<f32>) {
    let mut child = Command::new("pw-record")
        .args(["--container", "raw", "--rate", "16000", "--channels", "1", "--format", "s16", "--media-role", "Communication", "-P", "{ node.name = omarchy-dictate, media.name = \"Omarchy dictation\" }", "-"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap_or_else(|_| fail("recorder_unavailable"));
    RECORDER.store(child.id() as i32, Ordering::SeqCst);
    emit(format!("{{\"type\":\"recording\",\"muted\":{}}}", muted()));
    let mut stdout = child.stdout.take().unwrap();
    let mut samples: Vec<f32> = Vec::with_capacity(RATE * 30);
    let mut buf = [0u8; 2560]; // 80 ms
    let mut carry: Option<u8> = None;
    let mut last_level = Instant::now();
    let mut mark = 0;
    let limit = max_seconds as usize * RATE;
    while !STOP.load(Ordering::SeqCst) && !CANCEL.load(Ordering::SeqCst) && samples.len() < limit {
        let n = match stdout.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        let mut bytes = &buf[..n];
        if let Some(lo) = carry.take() {
            samples.push(i16::from_le_bytes([lo, bytes[0]]) as f32 / 32768.0);
            bytes = &bytes[1..];
        }
        let mut pairs = bytes.chunks_exact(2);
        samples.extend(pairs.by_ref().map(|p| i16::from_le_bytes([p[0], p[1]]) as f32 / 32768.0));
        carry = pairs.remainder().first().copied();
        if last_level.elapsed() >= Duration::from_millis(70) {
            emit(format!("{{\"type\":\"level\",\"value\":{:.3}}}", level(&samples[mark..])));
            mark = samples.len();
            last_level = Instant::now();
        }
    }
    RECORDER.store(0, Ordering::SeqCst);
    let _ = child.kill();
    let _ = child.wait();
    (child, samples)
}

fn listen(o: Options) {
    if !installed(o.model) {
        fail("model_missing");
    }
    let file = o.model;
    let loader = thread::spawn(move || try_load(file));
    let (_, samples) = record(o.max_seconds);
    if CANCEL.load(Ordering::SeqCst) {
        std::process::exit(130);
    }
    if o.backup_count > 0 {
        let ok = backups::save(&samples, &backups::Policy { count: o.backup_count, days: o.backup_days }).is_ok();
        emit(format!("{{\"type\":\"backup\",\"ok\":{ok}}}"));
    }
    let started = Instant::now();
    emit("{\"type\":\"transcribing\"}".into());
    let ctx = loader.join().unwrap_or_else(|_| fail("model_invalid")).unwrap_or_else(|code| fail(code));
    if CANCEL.load(Ordering::SeqCst) {
        std::process::exit(130);
    }
    let (text, language) = transcribe(&ctx, &samples, &o);
    result(&text, &language, samples.len() as f32 / RATE as f32, started);
}

fn read_audio(path: &str) -> Vec<f32> {
    let bytes = fs::read(path).unwrap_or_else(|_| fail("local_error"));
    let data = if bytes.starts_with(b"RIFF") && bytes.len() > 44 {
        // Find the "data" chunk of a 16 kHz mono s16 WAV.
        let mut at = 12;
        let mut found = None;
        while at + 8 <= bytes.len() {
            let size = u32::from_le_bytes(bytes[at + 4..at + 8].try_into().unwrap()) as usize;
            if &bytes[at..at + 4] == b"data" {
                found = Some(&bytes[at + 8..(at + 8 + size).min(bytes.len())]);
                break;
            }
            at += 8 + size + (size & 1);
        }
        found.unwrap_or_else(|| fail("bad_audio"))
    } else {
        &bytes[..]
    };
    data.chunks_exact(2).map(|p| i16::from_le_bytes([p[0], p[1]]) as f32 / 32768.0).collect()
}

fn main() {
    whisper_rs::install_logging_hooks();
    unsafe {
        // Never outlive the shell that started us.
        libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
        for sig in [libc::SIGINT, libc::SIGUSR1, libc::SIGTERM, libc::SIGHUP] {
            libc::signal(sig, on_signal as *const () as libc::sighandler_t);
        }
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("models") => list(),
        Some("download") if args.len() == 2 => download(model(&args[1])),
        Some("remove") if args.len() == 2 => {
            let m = model(&args[1]);
            let _ = fs::remove_file(models_dir().join(format!("{}.part", m.file)));
            match fs::remove_file(models_dir().join(m.file)) {
                Ok(()) => emit(format!("{{\"type\":\"removed\",\"model\":{}}}", quote(m.id))),
                Err(e) if e.kind() == io::ErrorKind::NotFound => emit(format!("{{\"type\":\"removed\",\"model\":{}}}", quote(m.id))),
                Err(_) => fail("local_error"),
            }
        }
        Some("backups") => {
            let o = options(&args[1..]);
            let path = backups::prune(&backups::Policy { count: o.backup_count, days: o.backup_days }).unwrap_or_else(|_| fail("backup_failed"));
            emit(format!("{{\"path\":{}}}", quote(&path.to_string_lossy())));
        }
        Some("listen") => listen(options(&args[1..])),
        Some("transcribe") if args.len() >= 2 => {
            let o = options(&args[2..]);
            let samples = read_audio(&args[1]);
            let started = Instant::now();
            let ctx = load(o.model);
            let loaded = started.elapsed().as_millis();
            let (text, language) = transcribe(&ctx, &samples, &o);
            eprintln!("load {loaded} ms");
            result(&text, &language, samples.len() as f32 / RATE as f32, started);
        }
        _ => fail("bad_arguments"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn tone(seconds: f32, amplitude: f32) -> Vec<f32> {
        (0..(seconds * RATE as f32) as usize).map(|i| amplitude * (i as f32 * 0.3).sin()).collect()
    }
    #[test]
    fn silence_and_clicks_are_not_speech() {
        assert!(speech(&vec![0.0; RATE * 2]).is_none());
        let mut click = vec![0.0; RATE * 2];
        click[RATE..RATE + 200].iter_mut().for_each(|s| *s = 0.8);
        assert!(speech(&click).is_none());
    }
    #[test]
    fn speech_is_trimmed_with_padding() {
        let mut clip = vec![0.0; RATE * 2];
        clip.extend(tone(1.0, 0.3));
        clip.extend(vec![0.0; RATE * 2]);
        let voice = speech(&clip).unwrap();
        assert!(voice.len() >= RATE && voice.len() < RATE * 2, "{}", voice.len());
    }
    #[test]
    fn invented_captions_and_annotations_are_dropped() {
        assert_eq!(clean(" Subtítulos realizados por la comunidad de Amara.org"), "");
        assert_eq!(clean("Thank you for watching!"), "");
        assert_eq!(clean("[Música] Abre el   archivo (risas) main.rs"), "Abre el archivo main.rs");
        assert_eq!(clean("Gracias por ver el video que te mandé"), "Gracias por ver el video que te mandé");
    }
    #[test]
    fn pauses_are_shortened_and_no_speech_is_lost() {
        let tone = |n: usize| (0..n).map(|i| if i % 2 == 0 { 0.6 } else { -0.6 }).collect::<Vec<f32>>();
        let mut clip = tone(RATE);
        clip.extend(vec![0.0; RATE * 5]);
        clip.extend(tone(RATE));
        let voice = speech(&clip).unwrap();
        assert!(voice.len() < RATE * 3, "pause kept: {}", voice.len());
        assert!(voice.iter().filter(|s| s.abs() > 0.1).count() >= RATE * 2 - RATE / 50);
    }
    #[test]
    fn quiet_speech_is_not_a_pause() {
        // A quiet microphone: words at 0.005, a drop to 0.003, a real pause.
        let tone = |n: usize, a: f32| (0..n).map(|i| if i % 2 == 0 { a } else { -a }).collect::<Vec<f32>>();
        let mut clip = tone(RATE, 0.005);
        clip.extend(tone(RATE, 0.003));
        clip.extend(vec![0.0; RATE * 3]);
        clip.extend(tone(RATE, 0.005));
        let voice = speech(&clip).unwrap();
        assert!(voice.iter().filter(|s| s.abs() > 0.01).count() >= RATE * 3 - RATE / 50, "speech lost");
        assert!(voice.len() < RATE * 5);
    }
    #[test]
    fn a_short_phrase_after_a_very_long_pause_is_still_speech() {
        // 3 s of words in 100 s of recording: under 5% of the frames.
        let tone = |n: usize| (0..n).map(|i| if i % 2 == 0 { 0.3 } else { -0.3 }).collect::<Vec<f32>>();
        let mut clip = tone(RATE * 2);
        clip.extend(vec![0.0; RATE * 95]);
        clip.extend(tone(RATE));
        let voice = speech(&clip).expect("speech found");
        assert!(voice.iter().filter(|s| s.abs() > 0.1).count() >= RATE * 3 - RATE / 50);
    }
    #[test]
    fn long_clips_are_cut_in_pauses() {
        assert_eq!(pieces(&vec![0.5; RATE * 20]), vec![(0, RATE * 20)]);
        // 60 s of tone with 300 ms gaps at 24.0 s and 48.5 s: the cuts land in them.
        let mut clip: Vec<f32> = (0..RATE * 60).map(|i| if i % 2 == 0 { 0.5 } else { -0.5 }).collect();
        for gap in [RATE * 24, RATE * 485 / 10] {
            clip[gap..gap + RATE * 3 / 10].iter_mut().for_each(|s| *s = 0.0);
        }
        let cuts = pieces(&clip);
        assert_eq!(cuts.len(), 3, "{cuts:?}");
        assert!(cuts[0].1 > RATE * 24 && cuts[0].1 < RATE * 243 / 10, "{cuts:?}");
        assert!(cuts[1].1 > RATE * 485 / 10 && cuts[1].1 < RATE * 488 / 10, "{cuts:?}");
        assert_eq!(cuts[2], (cuts[1].1, RATE * 60));
        for w in cuts.windows(2) {
            assert_eq!(w[0].1, w[1].0);
        }
        assert!(cuts.iter().all(|(s, e)| e - s <= PIECE));
    }
    #[test]
    fn pieces_join_without_a_cut_period() {
        assert_eq!(join(&["Abre el archivo.".into(), "y guárdalo".into()]), "Abre el archivo y guárdalo");
        assert_eq!(join(&["Listo.".into(), "Ahora sigue".into()]), "Listo. Ahora sigue");
        assert_eq!(join(&["Uno...".into(), "dos".into(), String::new(), "tres".into()]), "Uno... dos tres");
    }
    #[test]
    fn output_is_valid_json() {
        assert_eq!(quote("a \"b\"\n\\ \u{1}"), "\"a \\\"b\\\"\\n\\\\ \\u0001\"");
    }
}
