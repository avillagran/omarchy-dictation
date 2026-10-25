#!/usr/bin/env python3
"""Score both engines against one shared historical article prefix per case."""
import argparse, json, pathlib, re, unicodedata

def words(text):
    text = unicodedata.normalize('NFC', text.lower()).replace('\u200b', ' ')
    return re.sub('[^\\w\\s]|_', ' ', text).split()

def prefix_distances(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    costs = [previous[-1]]
    for i, token in enumerate(reference, 1):
        current = [i]
        for j, other in enumerate(hypothesis, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (token != other)))
        costs.append(current[-1])
        previous = current
    return costs

def main():
    p = argparse.ArgumentParser()
    p.add_argument('cache', type=pathlib.Path)
    p.add_argument('--manifest', type=pathlib.Path, default=pathlib.Path('docs/accuracy/corpus.json'))
    p.add_argument('--partial', action='store_true')
    a = p.parse_args()
    m = json.loads(a.manifest.read_text())
    out = pathlib.Path('docs/accuracy')
    rows = []
    references = {}
    lookup = {}
    for f in (a.cache / 'runs').glob('*.json'):
        r = json.loads(f.read_text())
        raw = (a.cache / 'runs' / (f.stem + '.time')).read_text()
        extra = {}
        for line in raw.splitlines():
            if ': ' in line:
                field, value = line.strip().split(': ', 1)
                extra[field] = value
        r['major_page_faults'] = int(extra.get('Major (requiring I/O) page faults', 0))
        r['involuntary_context_switches'] = int(extra.get('Involuntary context switches', 0))
        r['time_report'] = raw
        lookup[r['case'], r['model'], r['mode'], r['version']] = r
    for c in m['cases']:
        key = c['id']
        anchor_key = (key, 'small', 'fixed', 'after')
        if anchor_key not in lookup:
            if a.partial:
                continue
            raise RuntimeError('Missing anchor ' + key)
        reference = words((a.cache / 'sources' / (c['source'] + '.txt')).read_text())
        if c.get('pause'):
            short = next((v for v in m['cases'] if v['source'] == c['source'] and (not v.get('pause')) and (v.get('seconds', 0) <= 60)))
            short_anchor = lookup[short['id'], 'small', 'fixed', 'after']
            costs = prefix_distances(reference, words(short_anchor['result']['text']))
            length = min(range(1, len(costs)), key=lambda n: costs[n])
            reference = reference[:length] * 2
            length = len(reference)
        else:
            costs = prefix_distances(reference, words(lookup[anchor_key]['result']['text']))
            length = min(range(1, len(costs)), key=lambda n: costs[n])
            reference = reference[:length]
        references[key] = dict(source=c['source'], words=length, reference=' '.join(reference), endpoint_method='minimum absolute Levenshtein distance to new small fixed; shared across all eight runs', repetitions=2 if c.get('pause') else 1)
        for model in ('base', 'small'):
            for mode in ('auto', 'fixed'):
                for version in ('before', 'after'):
                    k = (key, model, mode, version)
                    if k not in lookup:
                        if a.partial:
                            continue
                        raise RuntimeError('Missing run ' + str(k))
                    r = lookup[k]
                    hyp = words(r['result']['text'])
                    errors = prefix_distances(reference, hyp)[-1]
                    r.update(language=c['language'], reference_words=length, hypothesis_words=len(hyp), errors=errors, accuracy=100 * (1 - errors / length), wer=100 * errors / length)
                    rows.append(r)
    (out / 'results.jsonl').write_text(''.join((json.dumps(r, ensure_ascii=False) + '\n' for r in rows)))
    (out / 'references.json').write_text(json.dumps(references, ensure_ascii=False, indent=2) + '\n')
    scored = {(r['case'], r['model'], r['mode'], r['version']): r for r in rows}
    lines = ['| Case | Seconds | Reference words | Base auto | Base fixed | Small auto | Small fixed |', '|---|---:|---:|---:|---:|---:|---:|']
    for c in m['cases']:
        key = c['id']
        if key not in references:
            continue
        r = scored[key, 'small', 'fixed', 'after']
        cells = []
        for model in ('base', 'small'):
            for mode in ('auto', 'fixed'):
                b = scored.get((key, model, mode, 'before'))
                n = scored.get((key, model, mode, 'after'))
                cells.append(f"{b['accuracy']:.1f} → {n['accuracy']:.1f}" if b and n else 'pending')
        lines.append(f"| {key} | {r['seconds']:.1f} | {r['reference_words']} | " + ' | '.join(cells) + ' |')
    (out / 'accuracy-table.md').write_text('\n'.join(lines) + '\n')
    resources = ['| Case | Model | Language | Wall s (old → new) | CPU user+sys s (old → new) | Peak RSS MiB (old → new) | Threads |', '|---|---|---|---:|---:|---:|---:|']
    for c in m['cases']:
        for model in ('base', 'small'):
            for mode in ('auto', 'fixed'):
                b = scored.get((c['id'], model, mode, 'before'))
                n = scored.get((c['id'], model, mode, 'after'))
                if not b or not n:
                    continue
                resources.append(f"| {c['id']} | {model} q8_0 | {mode} | {b['wall_s']:.2f} → {n['wall_s']:.2f} | {b['cpu_user_s'] + b['cpu_sys_s']:.2f} → {n['cpu_user_s'] + n['cpu_sys_s']:.2f} | {b['rss_kib'] / 1024:.1f} → {n['rss_kib'] / 1024:.1f} | {n['threads']} |")
    (out / 'resources-table.md').write_text('\n'.join(resources) + '\n')
    (out / 'machine.json').write_text((a.cache / 'machine.json').read_text())
    (out / 'audio-sha256.json').write_text((a.cache / 'audio-sha256.json').read_text())
    summary = []
    for language in sorted({r['language'] for r in rows}):
        for model in ('base', 'small'):
            for mode in ('auto', 'fixed'):
                item = dict(language=language, model=model, mode=mode)
                for version in ('before', 'after'):
                    group = [r for r in rows if (r['language'], r['model'], r['mode'], r['version']) == (language, model, mode, version)]
                    if group:
                        item[version] = dict(accuracy=100 * (1 - sum((r['errors'] for r in group)) / sum((r['reference_words'] for r in group))), wall_s=sum((r['wall_s'] for r in group)), cpu_s=sum((r['cpu_user_s'] + r['cpu_sys_s'] for r in group)), rss_peak_mib=max((r['rss_kib'] for r in group)) / 1024)
                summary.append(item)
    (out / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    print(f'{len(rows)} scored runs, {len(references)} cases')
if __name__ == '__main__':
    main()
