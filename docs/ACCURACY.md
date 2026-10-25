# Long dictation accuracy and resource use

This CPU benchmark compares the previous engine with bounded-piece decoding.
The new engine trims leading/trailing silence, compresses internal pauses to
0.6 seconds and splits speech into contiguous pieces no longer than 25 seconds.
Cuts lie in the quietest 120 ms within the preceding 1.5 seconds. It detects the
language once, keeps it for subsequent pieces and retries empty speech pieces
with beam search over the full audio context. It does not discard decoded text
based on the decoder's no-speech probability. Joining removes a cut-induced
period only when the next piece begins in lowercase, preserving ellipses.

## Corpus and scoring

The corpus pins Commons recordings and the historical Wikipedia revisions
identified in their descriptions. See [corpus.json](accuracy/corpus.json) for
source URLs, article revision IDs, authors, recording licenses and audio hashes.
No microphone audio or user recordings are included.

There are 25 cases from nine recordings in six languages. Spanish uses four
distinct recordings, including the three supplied regression examples.
English, Portuguese, French, German and Italian each use one pinned recording:
its first 60 seconds, first 240 seconds and first 600 seconds (or the whole
recording when shorter). These are nested clips, **not independent narrators or
18 independent articles**. This controls content and reference revisions but
limits conclusions about speakers and accents. Each language also has a
synthetic case: its short clip, 30 seconds of digital silence, the same clip
again. The Spanish pause case uses the full Caracas recording twice.

All audio is converted with FFmpeg to 16 kHz, mono, signed 16-bit PCM WAV.
Historical article HTML is fetched by `oldid`; tables, references, navigation,
infoboxes and image captions are excluded. Body paragraphs, lists and headings
are retained in article order. Reference and hypothesis are lowercased,
normalized to Unicode NFC, punctuation replaced by spaces and split on
whitespace. Accents and numeric forms are retained. For example, a spoken
number and an article's digits can count as an error.

The metric is `100 × (1 − (substitutions + deletions + insertions) / N)` using
word-level Levenshtein distance. It can be negative with enough insertions;
it is not the proportion of acoustically verified words. Reference endpoints
are estimated: select the article prefix with the lowest **absolute** edit
distance to the new small model with a fixed language, choosing the shorter
prefix on a tie. Freeze that same reference for all eight variants of the case.
For pause cases, repeat the short case's reference twice. This avoids giving
a truncated old output a shorter/easier reference. Selecting endpoints with
one candidate can favor it; this is an article-alignment benchmark,
not manually annotated ground truth. Headings, spoken introductions,
pronunciation of formulae and narrator deviations remain counted as errors.
[references.json](accuracy/references.json) publishes the exact normalized
references and word counts, and [results.jsonl](accuracy/results.jsonl) includes
all hypotheses, edit counts and per-process measurements.

## Machine and measurement

Host `omarchy`: Apple M2 Pro, 12 CPU cores (4 efficiency + 8 performance),
aarch64 Linux/Asahi. CPU-only whisper.cpp 1.8.3 through whisper-rs 0.16,
release Rust build with thin LTO, symbols stripped. Both binaries link the same
cached native CPU library, compiled with `GGML_NATIVE=ON` and
`-mcpu=apple-m2+crc+aes+sha3+fp16+dotprod+i8mm+nosve+nosme`.
The build invocation exported `GGML_NATIVE=OFF` and
`GGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16+i8mm`, but Cargo reused that native
library; those exports did **not** change the measured C/C++ build.
[machine.json](accuracy/machine.json) records kernel, compiler, CPU details,
model hashes, binary hashes and file sizes.

Each row is one invocation, in serial order, alternating old/new for each
case/model/language combination. `OMARCHY_DICTATE_THREADS=8`; no custom prompt
or audio-context override. Fixed language means the known recording language;
automatic means detection on the first piece. A fresh process loads the model
on every invocation; OS file caches are not flushed. Wall and CPU times include
loading, preprocessing and decoding, but not download, conversion or scoring.
GNU `/usr/bin/time -v` supplies wall time, user + system CPU time and peak RSS
(KiB, converted to MiB). Threads are configured decoder threads, not a sampled
peak OS thread count. This was an active desktop without CPU affinity or
frequency locking; other compilation activity was observed during part of the
run. Memory pressure and swap activity were also observed (about 1.1 GiB
available and 11 GiB swap used at one observation on this 16 GB machine).
Major page faults and involuntary context switches are published with the raw
GNU time reports in the JSONL. These are measurements under contention, not
controlled speed comparisons or stable latency claims.

## Final accuracy table

All 200 invocations completed successfully and reported the recording's
language. Of 100 old/new comparisons, 78 improve, 16 regress and six are
unchanged. Automatic and fixed language produced the same score in every
case/model combination, but were measured as separate invocations. These
comparisons include nested clips and repeated modes, not 100 independent
recordings. Each cell is **old → new**, in percentage points of article-word
agreement. `Reference words` is an estimated prefix length, not a manual count
of everything spoken.

| Case | Seconds | Reference words | Base auto | Base fixed | Small auto | Small fixed |
|---|---:|---:|---:|---:|---:|---:|
| es-caracas | 60.9 | 139 | 89.2 → 88.5 | 89.2 → 88.5 | 94.2 → 94.2 | 94.2 → 94.2 |
| es-betancourt | 237.3 | 505 | 69.3 → 85.3 | 69.3 → 85.3 | 3.2 → 91.7 | 3.2 → 91.7 |
| es-leipzig | 304.5 | 740 | 4.6 → 80.3 | 4.6 → 80.3 | 1.4 → 86.6 | 1.4 → 86.6 |
| es-long | 524.5 | 1223 | 18.5 → 81.9 | 18.5 → 81.9 | 5.7 → 86.8 | 5.7 → 86.8 |
| es-pause | 151.9 | 278 | 87.4 → 88.8 | 87.4 → 88.8 | 55.8 → 92.8 | 55.8 → 92.8 |
| en-short | 60.0 | 54 | 1.9 → 18.5 | 1.9 → 18.5 | 29.6 → 29.6 | 29.6 → 29.6 |
| en-medium | 240.0 | 365 | 44.1 → 56.7 | 44.1 → 56.7 | 19.5 → 64.1 | 19.5 → 64.1 |
| en-long | 599.4 | 1108 | 50.2 → 65.3 | 50.2 → 65.3 | 58.1 → 73.1 | 58.1 → 73.1 |
| en-pause | 150.0 | 108 | 4.6 → 14.8 | 4.6 → 14.8 | 38.0 → 20.4 | 38.0 → 20.4 |
| pt-short | 60.0 | 80 | 57.5 → 58.8 | 57.5 → 58.8 | 66.2 → 68.8 | 66.2 → 68.8 |
| pt-medium | 240.0 | 369 | 76.4 → 82.4 | 76.4 → 82.4 | 83.5 → 89.2 | 83.5 → 89.2 |
| pt-long | 600.0 | 817 | 67.3 → 67.0 | 67.3 → 67.0 | 65.6 → 72.1 | 65.6 → 72.1 |
| pt-pause | 150.0 | 160 | 60.0 → 61.3 | 60.0 → 61.3 | 43.8 → 67.5 | 43.8 → 67.5 |
| fr-short | 60.0 | 106 | 50.9 → 50.9 | 50.9 → 50.9 | 61.3 → 63.2 | 61.3 → 63.2 |
| fr-medium | 240.0 | 574 | 71.8 → 75.8 | 71.8 → 75.8 | 80.5 → 85.9 | 80.5 → 85.9 |
| fr-long | 600.0 | 1459 | 58.3 → 78.5 | 58.3 → 78.5 | 45.8 → 87.5 | 45.8 → 87.5 |
| fr-pause | 150.0 | 212 | 48.1 → 49.5 | 48.1 → 49.5 | 38.2 → 62.3 | 38.2 → 62.3 |
| de-short | 60.0 | 91 | 51.6 → 45.1 | 51.6 → 45.1 | 64.8 → 54.9 | 64.8 → 54.9 |
| de-medium | 240.0 | 374 | 44.4 → 37.4 | 44.4 → 37.4 | 46.5 → 48.4 | 46.5 → 48.4 |
| de-long | 568.1 | 985 | 38.2 → 59.8 | 38.2 → 59.8 | 52.5 → 65.0 | 52.5 → 65.0 |
| de-pause | 150.0 | 182 | 41.2 → 50.0 | 41.2 → 50.0 | 49.5 → 59.3 | 49.5 → 59.3 |
| it-short | 60.0 | 122 | 86.1 → 86.9 | 86.1 → 86.9 | 95.1 → 86.1 | 95.1 → 86.1 |
| it-medium | 240.0 | 535 | 71.6 → 83.4 | 71.6 → 83.4 | 79.1 → 90.1 | 79.1 → 90.1 |
| it-long | 571.0 | 1079 | 65.0 → 70.4 | 65.0 → 70.4 | 68.5 → 79.0 | 68.5 → 79.0 |
| it-pause | 150.0 | 244 | 44.7 → 87.3 | 44.7 → 87.3 | 92.6 → 85.7 | 92.6 → 85.7 |


## Relationship to the supplied regression measurements

For small q8_0 in automatic mode, the three new Spanish hypotheses were
compared byte for byte with the retained output artifacts of the supplied
regression run: Caracas, Betancourt and Leipzig are identical. The percentages
are **not identical** because the extracted/reference prefix endpoints differ:

| Recording | Supplied old → new | This article-prefix score old → new |
|---|---:|---:|
| Caracas | 93.6 → 93.6 | 94.2 → 94.2 |
| Rómulo Betancourt | 3.2 → 91.5 | 3.2 → 91.7 |
| Batalla de Leipzig | 1.3 → 85.4 | 1.4 → 86.6 |

The loss/recovery behavior is reproduced; exact percentage replication is not
claimed. The references and tokenization used here are published, rather than
adjusting endpoints to force agreement with the supplied values.

## Cases that do not improve

- Caracas, base: 89.2% → 88.5% (one additional edit on 139 reference words).
  A short clip need not benefit from the new decoding settings. Different
  segment/punctuation decisions can affect lexical choices; the benchmark does
  not isolate which setting caused this single-word regression.
- Caracas, small: 94.2% → 94.2%; there was no long-window loss to recover.
- English short, small: 29.6% → 29.6% under this article-prefix metric.
  The narrator reads a title, a Wikipedia introduction and a table of contents,
  whereas the extracted body reference does not include that spoken index.
- English pause, small: 38.0% → 20.4%, despite more output (112 → 157
  whitespace-separated words). Recovered spoken index material adds insertions
  against the duplicated body-only reference. Reference mismatch is a plausible
  contributor; this observation alone cannot establish acoustic deterioration
  or that every additional word is correct. A manually annotated transcript
  would be needed to separate those causes.

- German short regresses with both models: base 51.6% → 45.1%, small
  64.8% → 54.9%. The new small output contains "Blindtexts Das Textes" where
  the old output has "Blindtextes", and drops "Der Klassiker Lorem Ipsum".
  Loss of continuity at a piece boundary is a plausible cause, not an isolated
  experimentally established cause. The narrated licensing/date preamble is
  also absent from the article reference and depresses both absolute scores.
  The pinned German revision timestamp, 2006-08-11T07:25:15Z, is consistent
  with the date announced in the narration.
- German medium regresses with base: 44.4% → 37.4%; small improves only
  46.5% → 48.4%. Recovery of length alone is not sufficient evidence of
  correct recognition.
- Portuguese long, base: 67.3% → 67.0%. French short, base: 50.9% → 50.9%.
  The technique does not improve every model/recording combination.

- Italian short, small: 95.1% → 86.1%; Italian pause, small:
  92.6% → 85.7%. The new short output restores an opening "GLISSANDO da
  Wikipedia ..." preamble absent from the old output and from the body-only
  reference. This adds scored insertions; there is also a lexical change
  ("strisciare" → "stricciare"). Reference mismatch is an important plausible
  contributor, alongside actual recognition differences. No claim of uniform
  short-clip improvement is made.

## Resources

There are 50 invocations per model and engine (25 cases × two language modes).
The following totals describe this observed workload under contention; they
are not controlled speedup estimates. CPU is user + system; RSS is the maximum
observed per-process peak, not a sum.

| Model | Wall total s (old → new) | CPU total s (old → new) | Maximum peak RSS MiB (old → new) |
|---|---:|---:|---:|
| base q8_0 | 440.81 → 461.60 | 2709.55 → 2730.23 | 448.6 → 360.5 |
| small q8_0 | 1513.13 → 1078.78 | 9190.45 → 7070.20 | 736.8 → 605.6 |

| Artifact | Bytes | MiB |
|---|---:|---:|
| Old measured binary | 1,578,520 | 1.51 |
| New measured binary | 1,578,520 | 1.51 |
| Installed 0.1.1 binary | 1,578,520 | 1.51 |
| base q8_0 model | 81,768,585 | 77.98 |
| small q8_0 model | 264,464,607 | 252.21 |

Both measured binaries reported package version 0.1.0. The published source and
locally installed engine are version 0.1.1 so existing installations request a
rebuild. This final version changes package metadata only; the transcription
source is identical to the measured new engine. Its Betancourt/small/automatic
text was checked and is byte-identical. Binary and source hashes are recorded
in `machine.json`. The matrix timings refer to the measured binaries.

Selected timestamped [pressure observations](accuracy/observations.jsonl) are
retained alongside every run's original GNU time report in `results.jsonl`.

### Per-audio measurements

Each row is one old/new pair. All rows use eight configured decoder threads.

| Case | Model | Language | Wall s (old → new) | CPU user+sys s (old → new) | Peak RSS MiB (old → new) | Threads |
|---|---|---|---:|---:|---:|---:|
| es-caracas | base q8_0 | auto | 1.84 → 1.68 | 12.56 → 11.50 | 308.0 → 279.0 | 8 |
| es-caracas | base q8_0 | fixed | 1.26 → 1.14 | 8.52 → 7.49 | 314.1 → 253.8 | 8 |
| es-caracas | small q8_0 | auto | 3.87 → 3.55 | 28.57 → 26.18 | 608.6 → 567.1 | 8 |
| es-caracas | small q8_0 | fixed | 3.26 → 2.74 | 23.41 → 19.55 | 607.8 → 528.1 | 8 |
| es-betancourt | base q8_0 | auto | 6.18 → 4.83 | 42.02 → 33.14 | 396.5 → 304.0 | 8 |
| es-betancourt | base q8_0 | fixed | 5.87 → 4.54 | 39.55 → 30.78 | 397.0 → 284.9 | 8 |
| es-betancourt | small q8_0 | auto | 8.74 → 12.47 | 66.65 → 91.44 | 581.0 → 592.1 | 8 |
| es-betancourt | small q8_0 | fixed | 27.50 → 12.99 | 145.21 → 92.00 | 610.2 → 558.7 | 8 |
| es-leipzig | base q8_0 | auto | 4.05 → 7.18 | 30.17 → 48.82 | 368.4 → 311.6 | 8 |
| es-leipzig | base q8_0 | fixed | 3.87 → 6.75 | 28.53 → 45.44 | 363.9 → 294.2 | 8 |
| es-leipzig | small q8_0 | auto | 124.58 → 36.80 | 653.56 → 216.34 | 572.9 → 304.1 | 8 |
| es-leipzig | small q8_0 | fixed | 20.66 → 44.22 | 138.49 → 256.77 | 240.0 → 239.6 | 8 |
| es-long | base q8_0 | auto | 15.32 → 12.22 | 90.61 → 81.95 | 240.0 → 239.0 | 8 |
| es-long | base q8_0 | fixed | 16.28 → 12.46 | 96.32 → 82.85 | 237.2 → 236.4 | 8 |
| es-long | small q8_0 | auto | 39.95 → 40.72 | 264.18 → 278.53 | 239.6 → 241.1 | 8 |
| es-long | small q8_0 | fixed | 39.94 → 38.22 | 263.35 → 262.79 | 238.2 → 526.1 | 8 |
| es-pause | base q8_0 | auto | 7.58 → 2.62 | 48.79 → 17.84 | 380.8 → 290.3 | 8 |
| es-pause | base q8_0 | fixed | 4.75 → 2.40 | 30.55 → 16.09 | 379.1 → 269.3 | 8 |
| es-pause | small q8_0 | auto | 8.85 → 8.50 | 62.22 → 60.11 | 522.6 → 475.3 | 8 |
| es-pause | small q8_0 | fixed | 30.93 → 6.85 | 160.04 → 48.57 | 509.7 → 504.3 | 8 |
| en-short | base q8_0 | auto | 1.35 → 1.36 | 9.73 → 9.39 | 284.4 → 278.8 | 8 |
| en-short | base q8_0 | fixed | 1.20 → 1.52 | 8.06 → 10.00 | 277.8 → 249.8 | 8 |
| en-short | small q8_0 | auto | 4.41 → 4.33 | 31.77 → 31.12 | 598.2 → 567.0 | 8 |
| en-short | small q8_0 | fixed | 2.73 → 2.86 | 19.93 → 20.25 | 596.8 → 527.2 | 8 |
| en-medium | base q8_0 | auto | 5.51 → 4.30 | 38.44 → 29.87 | 395.1 → 302.2 | 8 |
| en-medium | base q8_0 | fixed | 5.48 → 60.43 | 37.35 → 255.93 | 395.6 → 280.4 | 8 |
| en-medium | small q8_0 | auto | 12.76 → 10.64 | 92.96 → 78.62 | 671.8 → 594.2 | 8 |
| en-medium | small q8_0 | fixed | 9.55 → 9.94 | 72.26 → 72.76 | 672.6 → 559.8 | 8 |
| en-long | base q8_0 | auto | 11.45 → 19.41 | 80.64 → 126.71 | 448.6 → 360.5 | 8 |
| en-long | base q8_0 | fixed | 10.07 → 13.17 | 71.89 → 89.43 | 447.5 → 358.7 | 8 |
| en-long | small q8_0 | auto | 70.85 → 35.21 | 401.12 → 247.98 | 736.8 → 566.6 | 8 |
| en-long | small q8_0 | fixed | 34.16 → 31.49 | 248.12 → 222.63 | 716.4 → 588.6 | 8 |
| en-pause | base q8_0 | auto | 1.85 → 2.27 | 13.39 → 15.88 | 297.4 → 292.7 | 8 |
| en-pause | base q8_0 | fixed | 1.84 → 1.85 | 13.16 → 12.70 | 296.8 → 268.9 | 8 |
| en-pause | small q8_0 | auto | 6.23 → 5.47 | 45.53 → 39.66 | 600.1 → 580.7 | 8 |
| en-pause | small q8_0 | fixed | 6.68 → 33.15 | 46.51 → 164.25 | 568.6 → 526.2 | 8 |
| pt-short | base q8_0 | auto | 3.25 → 1.36 | 21.16 → 9.37 | 312.2 → 268.1 | 8 |
| pt-short | base q8_0 | fixed | 3.23 → 1.06 | 20.50 → 7.05 | 319.9 → 258.4 | 8 |
| pt-short | small q8_0 | auto | 4.92 → 4.52 | 34.44 → 32.41 | 460.8 → 462.6 | 8 |
| pt-short | small q8_0 | fixed | 4.03 → 3.40 | 28.32 → 23.67 | 453.6 → 436.9 | 8 |
| pt-medium | base q8_0 | auto | 5.83 → 4.53 | 39.55 → 31.36 | 395.7 → 302.7 | 8 |
| pt-medium | base q8_0 | fixed | 5.88 → 4.25 | 39.79 → 28.92 | 376.1 → 286.5 | 8 |
| pt-medium | small q8_0 | auto | 21.99 → 18.27 | 147.78 → 123.32 | 357.1 → 245.7 | 8 |
| pt-medium | small q8_0 | fixed | 21.52 → 31.94 | 143.55 → 186.97 | 238.2 → 237.6 | 8 |
| pt-long | base q8_0 | auto | 33.03 → 12.70 | 182.18 → 85.17 | 237.9 → 237.8 | 8 |
| pt-long | base q8_0 | fixed | 21.83 → 13.86 | 130.56 → 92.13 | 237.8 → 235.3 | 8 |
| pt-long | small q8_0 | auto | 73.47 → 63.64 | 494.85 → 396.12 | 238.8 → 236.2 | 8 |
| pt-long | small q8_0 | fixed | 53.63 → 28.24 | 358.10 → 206.15 | 625.2 → 605.6 | 8 |
| pt-pause | base q8_0 | auto | 4.58 → 4.38 | 30.00 → 29.42 | 380.0 → 292.2 | 8 |
| pt-pause | base q8_0 | fixed | 5.90 → 3.26 | 38.37 → 21.35 | 381.5 → 272.3 | 8 |
| pt-pause | small q8_0 | auto | 6.94 → 7.40 | 50.65 → 53.47 | 649.0 → 577.4 | 8 |
| pt-pause | small q8_0 | fixed | 6.85 → 5.58 | 48.90 → 40.25 | 645.4 → 546.0 | 8 |
| fr-short | base q8_0 | auto | 1.75 → 1.57 | 11.87 → 10.77 | 320.6 → 280.9 | 8 |
| fr-short | base q8_0 | fixed | 1.54 → 1.30 | 10.34 → 8.51 | 326.0 → 261.0 | 8 |
| fr-short | small q8_0 | auto | 4.12 → 3.87 | 29.95 → 28.01 | 613.3 → 568.6 | 8 |
| fr-short | small q8_0 | fixed | 3.75 → 4.77 | 26.59 → 31.60 | 562.4 → 531.7 | 8 |
| fr-medium | base q8_0 | auto | 8.65 → 6.13 | 58.10 → 41.13 | 398.5 → 302.7 | 8 |
| fr-medium | base q8_0 | fixed | 9.35 → 6.94 | 60.79 → 45.76 | 396.1 → 285.1 | 8 |
| fr-medium | small q8_0 | auto | 22.19 → 20.89 | 151.29 → 144.70 | 520.8 → 384.2 | 8 |
| fr-medium | small q8_0 | fixed | 50.70 → 35.03 | 292.89 → 203.87 | 285.7 → 271.6 | 8 |
| fr-long | base q8_0 | auto | 21.83 → 16.44 | 129.52 → 107.72 | 246.3 → 230.4 | 8 |
| fr-long | base q8_0 | fixed | 23.24 → 14.94 | 137.54 → 98.10 | 236.1 → 235.3 | 8 |
| fr-long | small q8_0 | auto | 84.70 → 70.93 | 508.85 → 456.87 | 238.1 → 237.2 | 8 |
| fr-long | small q8_0 | fixed | 61.31 → 50.20 | 402.91 → 340.39 | 239.7 → 239.3 | 8 |
| fr-pause | base q8_0 | auto | 5.04 → 3.87 | 31.66 → 24.96 | 231.9 → 230.7 | 8 |
| fr-pause | base q8_0 | fixed | 4.85 → 3.88 | 29.99 → 25.45 | 235.9 → 233.7 | 8 |
| fr-pause | small q8_0 | auto | 12.62 → 14.06 | 83.62 → 92.42 | 237.3 → 237.2 | 8 |
| fr-pause | small q8_0 | fixed | 11.51 → 10.10 | 75.20 → 66.71 | 237.3 → 235.8 | 8 |
| de-short | base q8_0 | auto | 2.75 → 2.22 | 17.75 → 14.65 | 237.3 → 235.7 | 8 |
| de-short | base q8_0 | fixed | 1.81 → 1.38 | 11.43 → 8.97 | 235.2 → 237.2 | 8 |
| de-short | small q8_0 | auto | 7.00 → 7.02 | 46.69 → 46.11 | 238.7 → 236.8 | 8 |
| de-short | small q8_0 | fixed | 5.79 → 5.70 | 37.55 → 37.16 | 237.3 → 237.9 | 8 |
| de-medium | base q8_0 | auto | 9.43 → 7.81 | 56.94 → 51.35 | 237.1 → 235.7 | 8 |
| de-medium | base q8_0 | fixed | 10.84 → 6.41 | 63.76 → 41.93 | 238.1 → 234.1 | 8 |
| de-medium | small q8_0 | auto | 26.26 → 21.34 | 174.20 → 144.77 | 238.9 → 239.3 | 8 |
| de-medium | small q8_0 | fixed | 24.79 → 20.39 | 164.77 → 136.18 | 239.5 → 237.0 | 8 |
| de-long | base q8_0 | auto | 22.11 → 19.91 | 130.96 → 131.58 | 238.3 → 235.2 | 8 |
| de-long | base q8_0 | fixed | 21.17 → 50.01 | 124.23 → 249.89 | 236.9 → 236.1 | 8 |
| de-long | small q8_0 | auto | 65.30 → 48.43 | 409.12 → 327.03 | 241.1 → 239.1 | 8 |
| de-long | small q8_0 | fixed | 122.46 → 50.88 | 610.24 → 344.86 | 238.7 → 238.4 | 8 |
| de-pause | base q8_0 | auto | 7.73 → 4.59 | 46.87 → 30.63 | 231.1 → 234.4 | 8 |
| de-pause | base q8_0 | fixed | 5.15 → 2.45 | 31.71 → 16.22 | 235.5 → 236.5 | 8 |
| de-pause | small q8_0 | auto | 11.70 → 10.57 | 77.67 → 71.12 | 239.6 → 238.2 | 8 |
| de-pause | small q8_0 | fixed | 12.63 → 8.10 | 79.93 → 56.09 | 305.0 → 401.2 | 8 |
| it-short | base q8_0 | auto | 1.76 → 1.86 | 11.63 → 12.44 | 331.2 → 277.2 | 8 |
| it-short | base q8_0 | fixed | 1.69 → 1.32 | 10.59 → 8.63 | 268.5 → 260.3 | 8 |
| it-short | small q8_0 | auto | 6.66 → 7.02 | 44.61 → 47.47 | 325.5 → 292.5 | 8 |
| it-short | small q8_0 | fixed | 9.00 → 8.39 | 54.27 → 52.04 | 247.7 → 237.2 | 8 |
| it-medium | base q8_0 | auto | 19.68 → 57.70 | 119.11 → 270.24 | 235.6 → 249.1 | 8 |
| it-medium | base q8_0 | fixed | 20.74 → 6.40 | 112.88 → 42.37 | 238.6 → 235.6 | 8 |
| it-medium | small q8_0 | auto | 31.56 → 23.19 | 209.54 → 157.20 | 238.2 → 238.3 | 8 |
| it-medium | small q8_0 | fixed | 28.94 → 21.37 | 191.69 → 145.07 | 239.9 → 237.9 | 8 |
| it-long | base q8_0 | auto | 22.13 → 14.03 | 131.06 → 93.71 | 237.8 → 237.3 | 8 |
| it-long | base q8_0 | fixed | 21.33 → 19.19 | 125.06 → 126.50 | 239.5 → 236.6 | 8 |
| it-long | small q8_0 | auto | 157.49 → 42.76 | 821.18 → 294.80 | 239.3 → 239.2 | 8 |
| it-long | small q8_0 | fixed | 54.27 → 40.99 | 362.68 → 281.76 | 239.4 → 237.7 | 8 |
| it-pause | base q8_0 | auto | 3.57 → 3.05 | 22.44 → 20.52 | 237.1 → 235.9 | 8 |
| it-pause | base q8_0 | fixed | 3.39 → 2.67 | 20.93 → 17.62 | 236.2 → 236.3 | 8 |
| it-pause | small q8_0 | auto | 38.56 → 39.85 | 192.39 → 206.63 | 238.6 → 238.1 | 8 |
| it-pause | small q8_0 | fixed | 10.82 → 9.79 | 72.15 → 65.43 | 240.0 → 237.4 | 8 |


## Reproduce

Required tools: Rust/Cargo, CMake, a C/C++ compiler, Python 3 standard library,
FFmpeg, curl and GNU time. Models are multilingual `base q8_0` and `small q8_0`.
Run from the repository root; all downloaded/generated files stay under the
chosen cache folder. The comparison baseline is commit
`5968c9fb6fc17e24e128803caeb7741eed0a6ee6`.

```bash
cache="$HOME/.cache/omarchy-dictation-accuracy-reproduction"
mkdir -p "$cache/baseline"
git archive 5968c9fb6fc17e24e128803caeb7741eed0a6ee6 native | tar -x -C "$cache/baseline"
# Native CPU tuning, matching the measured C/C++ library on this M2 Pro.
export GGML_NATIVE=ON
export CARGO_TARGET_DIR="$cache/build"
cargo build --release --locked --manifest-path "$cache/baseline/native/Cargo.toml"
cp "$CARGO_TARGET_DIR/release/omarchy-dictate" "$cache/before"
cargo build --release --locked --manifest-path native/Cargo.toml
cp "$CARGO_TARGET_DIR/release/omarchy-dictate" "$cache/after"
"$cache/after" download base
"$cache/after" download small
python3 tools/accuracy/prepare.py "$cache"
python3 tools/accuracy/run.py "$cache" --threads 8
python3 tools/accuracy/report.py "$cache"
python3 tools/accuracy/html_report.py
python3 tools/accuracy/test_report.py
cargo test --release --locked --manifest-path native/Cargo.toml
```

`run.py` expects the two pinned model files in
`~/.local/share/omarchy-t3-code/dictation` on the measured machine. For a fresh
machine, the download command stores them under
`~/.local/share/omarchy-dictation/models`; use the runner's model-directory
option for that location. Both files are checked by SHA-256 before measuring.

The runner is resumable and refuses to reuse a result when audio, binary,
model or thread-count fingerprints differ. Delete or move an old run directory
to measure a different binary. Every raw stdout, stderr and complete GNU time
report is retained in `$cache/runs`. The committed JSONL publishes their
transcripts and resource fields; audio files and binaries are not committed.

The conversion performed for each original recording is exactly:

```bash
ffmpeg -nostdin -v error -y -i source.original -ar 16000 -ac 1 -c:a pcm_s16le source.wav
```

Each measurement is equivalent to:

```bash
LC_ALL=C OMARCHY_DICTATE_THREADS=8 /usr/bin/time -v -o run.time \
  "$cache/after" transcribe "$cache/cases/es-betancourt.wav" \
  --model small --language es > run.stdout 2> run.stderr
```

## Text attribution

The source articles and spoken derivatives retain their respective licenses;
see the source links in the manifest for authorship/history and licensing.
Normalized references and hypotheses here are derivatives of those article
texts; the repository's software license does not replace their licenses.
