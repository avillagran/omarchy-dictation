#!/usr/bin/env python3
"""Download the pinned Commons corpus and historical article references."""
import argparse, concurrent.futures, hashlib, html.parser, json, pathlib, subprocess, urllib.parse, urllib.request, wave
UA = 'OmarchyDictationAccuracy/1.0 (https://github.com/avillagran/omarchy-dictation)'

def fetch(url):
    request = urllib.request.Request(url, headers={'User-Agent': UA})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()

def api(host, **params):
    return json.loads(fetch('https://' + host + '/w/api.php?' + urllib.parse.urlencode(dict(action='query', format='json', **params))))

class Article(html.parser.HTMLParser):

    def __init__(self):
        super().__init__()
        self.stack = []
        self.out = []
        self.block = 0
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        skip = tag in ('table', 'sup', 'script', 'style') or any((c in attrs.get('class', '').split() for c in ('mw-editsection', 'reference', 'reflist', 'navbox', 'metadata', 'hatnote', 'infobox', 'noprint', 'toc', 'thumb')))
        block = tag in ('p', 'li', 'h2', 'h3', 'h4', 'dd')
        if tag in ('br', 'hr', 'img', 'meta', 'link', 'input', 'wbr', 'source'):
            return
        self.stack.append((tag, skip, block))
        self.skip += skip
        self.block += block
        if block and (not self.skip):
            self.out.append('\n')

    def handle_endtag(self, tag):
        if not any((x[0] == tag for x in self.stack)):
            return
        while self.stack:
            t, s, b = self.stack.pop()
            self.skip -= s
            self.block -= b
            if b and (not self.skip):
                self.out.append('\n')
            if t == tag:
                break

    def handle_data(self, data):
        if self.block and (not self.skip):
            self.out.append(data)

def prepare_source(args):
    source, root = args
    key = source['id']
    directory = root / 'sources'
    directory.mkdir(exist_ok=True)
    original = directory / (key + '.original')
    wav = directory / (key + '.wav')
    ref = directory / (key + '.txt')
    if not original.exists():
        original.write_bytes(fetch(source['audio_url']))
    if source.get('audio_sha256') and hashlib.sha256(original.read_bytes()).hexdigest() != source['audio_sha256']:
        raise RuntimeError('Source audio hash mismatch: ' + key)
    if not wav.exists():
        subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', str(original), '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', str(wav)], check=True)
    if not ref.exists():
        url = 'https://' + source['language'] + '.wikipedia.org/w/api.php?' + urllib.parse.urlencode({'action': 'parse', 'format': 'json', 'oldid': source['oldid'], 'prop': 'text|revid|displaytitle'})
        raw = fetch(url)
        (directory / (key + '.article.json')).write_bytes(raw)
        parsed = json.loads(raw)['parse']
        assert parsed['revid'] == source['oldid']
        parser = Article()
        parser.feed(parsed['text']['*'])
        ref.write_text('\n'.join((line.strip() for line in ''.join(parser.out).splitlines() if line.strip())) + '\n')
    return key

def main():
    p = argparse.ArgumentParser()
    p.add_argument('cache', type=pathlib.Path)
    p.add_argument('--manifest', type=pathlib.Path, default=pathlib.Path('docs/accuracy/corpus.json'))
    a = p.parse_args()
    a.cache.mkdir(parents=True, exist_ok=True)
    m = json.loads(a.manifest.read_text())
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for key in pool.map(prepare_source, [(s, a.cache) for s in m['sources']]):
            print('source', key, flush=True)
    cases = a.cache / 'cases'
    cases.mkdir(exist_ok=True)
    hashes = {}
    for case in m['cases']:
        target = cases / (case['id'] + '.wav')
        if not target.exists():
            with wave.open(str(a.cache / 'sources' / (case['source'] + '.wav')), 'rb') as w:
                params = w.getparams()
                audio = w.readframes(int(case.get('seconds', w.getnframes() / 16000) * 16000))
            if case.get('pause'):
                audio = audio + b'\x00' * (16000 * 2 * 30) + audio
            with wave.open(str(target), 'wb') as w:
                w.setparams(params)
                w.writeframes(audio)
        hashes[case['id']] = hashlib.sha256(target.read_bytes()).hexdigest()
    (a.cache / 'audio-sha256.json').write_text(json.dumps(hashes, indent=2) + '\n')
if __name__ == '__main__':
    main()
