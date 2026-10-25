#!/usr/bin/env python3
"""Run a serial, resumable before/after matrix with GNU time -v."""
import argparse, hashlib, json, os, pathlib, platform, signal, subprocess, wave

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    p = argparse.ArgumentParser()
    p.add_argument('cache', type=pathlib.Path)
    p.add_argument('--manifest', type=pathlib.Path, default=pathlib.Path('docs/accuracy/corpus.json'))
    p.add_argument('--threads', type=int, default=8)
    p.add_argument('--model-dir', type=pathlib.Path)
    a = p.parse_args()
    root = a.cache
    m = json.loads(a.manifest.read_text())
    out = root / 'runs'
    out.mkdir(exist_ok=True)
    env = os.environ.copy()
    env['OMARCHY_DICTATE_THREADS'] = str(a.threads)
    env['LC_ALL'] = 'C'
    env.pop('OMARCHY_DICTATE_AUDIO_CTX', None)
    env.pop('OMARCHY_DICTATE_MODEL_FILE', None)
    modeldir = a.model_dir or pathlib.Path.home() / '.local/share/omarchy-t3-code/dictation'
    if a.model_dir is None and (not modeldir.exists()):
        modeldir = pathlib.Path.home() / '.local/share/omarchy-dictation/models'
    machine = dict(ram_kib=int(pathlib.Path('/proc/meminfo').read_text().splitlines()[0].split()[1]), host=platform.node(), kernel=platform.platform(), cpu=subprocess.check_output(['lscpu'], text=True), rust=subprocess.check_output(['rustc', '-Vv'], text=True), ffmpeg=subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0], threads=a.threads, binaries={v: dict(sha256=sha(root / v), bytes=(root / v).stat().st_size) for v in ('before', 'after')}, models={v: dict(sha256=sha(modeldir / ('ggml-' + v + '-q8_0.bin')), bytes=(modeldir / ('ggml-' + v + '-q8_0.bin')).stat().st_size) for v in ('base', 'small')})
    expected = {'base': 'c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9', 'small': '49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f'}
    for model, digest in expected.items():
        if machine['models'][model]['sha256'] != digest:
            raise RuntimeError('Unexpected model: ' + model)
    (root / 'machine.json').write_text(json.dumps(machine, indent=2) + '\n')
    total = len(m['cases']) * 8
    done = 0
    for case in m['cases']:
        audio = root / 'cases' / (case['id'] + '.wav')
        with wave.open(str(audio)) as w:
            seconds = w.getnframes() / 16000
        for model in ('base', 'small'):
            for language in ('auto', case['language']):
                for version in ('before', 'after'):
                    key = '-'.join((case['id'], model, language, version))
                    target = out / (key + '.json')
                    done += 1
                    fingerprint = dict(audio_sha256=sha(audio), binary_sha256=machine['binaries'][version]['sha256'], model_sha256=machine['models'][model]['sha256'], threads=a.threads)
                    if target.exists():
                        old = json.loads(target.read_text())
                        if old.get('fingerprint') == fingerprint:
                            continue
                        raise RuntimeError('Stale result: ' + key)
                    env['OMARCHY_DICTATE_MODEL_FILE'] = str(modeldir / ('ggml-' + model + '-q8_0.bin'))
                    args = [str(root / version), 'transcribe', str(audio), '--model', model, '--language', language]
                    timer = out / (key + '.time')
                    stdout = out / (key + '.stdout')
                    stderr = out / (key + '.stderr')
                    print(f'{done}/{total} {key} ({seconds:.1f}s)', flush=True)
                    with stdout.open('w') as so, stderr.open('w') as se:
                        process = subprocess.Popen(['/usr/bin/time', '-v', '-o', str(timer), *args], env=env, stdout=so, stderr=se, start_new_session=True)
                        try:
                            process.wait(timeout=1800)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid, signal.SIGTERM)
                            try:
                                process.wait(timeout=10)
                            except subprocess.TimeoutExpired:
                                os.killpg(process.pid, signal.SIGKILL)
                                process.wait()
                            raise RuntimeError('Transcription timed out: ' + key)
                    if process.returncode:
                        raise RuntimeError('Transcription failed: ' + key + ' ' + stderr.read_text()[-500:])
                    metrics = {}
                    for line in timer.read_text().splitlines():
                        if ': ' in line:
                            k, v = line.strip().split(': ', 1)
                            metrics[k] = v
                    elapsed = metrics['Elapsed (wall clock) time (h:mm:ss or m:ss)'].split(':')
                    wall = sum((float(v) * 60 ** i for i, v in enumerate(reversed(elapsed))))
                    result = dict(case=case['id'], model=model, mode='auto' if language == 'auto' else 'fixed', requested_language=language, version=version, seconds=seconds, wall_s=wall, cpu_user_s=float(metrics['User time (seconds)']), cpu_sys_s=float(metrics['System time (seconds)']), rss_kib=int(metrics['Maximum resident set size (kbytes)']), threads=a.threads, command=args, fingerprint=fingerprint, result=json.loads(stdout.read_text()))
                    target.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print('MATRIX_COMPLETE', flush=True)
if __name__ == '__main__':
    main()
