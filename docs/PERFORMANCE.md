# Performance harnesses

These tools create and measure synthetic data only. The Dart tests run under the
JIT test VM and use deliberately generous ceilings; their times are regression
signals, not release benchmarks. No performance numbers are recorded here until
the coordinator runs the harnesses on a named machine.

## Create deterministic datasets

From the repository root:

```sh
data_dir="$(mktemp -d)"
dart tool/perf/seed_library.dart --dir "$data_dir"
```

This writes four independent SQLite databases under `empty/`, `50/`, `500/`,
and `large/`. The large database contains one rich-text Delta document around
200 KiB with mixed inline formats and checklist lines. The seed and note text
are deterministic. Each dataset includes a deterministic synthetic `dev.key`,
so the app can open the encrypted database when `NOTES_DATA_DIR` points to that
dataset. Keep the returned temporary directory for Linux runs, then remove it
when finished.

The output directory must be empty. Existing generated datasets may be replaced
only by passing `--force-empty-temp`, and only when the directory is inside the
system temporary directory. The tool refuses unexpected files and refuses to
seed beneath the configured `NOTES_DATA_DIR`.

## Linux launch and idle sampling

Build the release bundle separately, seed data as above, and run:

```sh
tool/perf/linux_startup.sh \
  build/linux/x64/release/bundle/notes "$data_dir" 8
```

The script runs the binary with `NOTES_DATA_DIR="$data_dir/500"`, records
startup-to-visible-window time when `xdotool` can find the `Notes` window, then
samples process CPU time and resident memory for the requested idle seconds. It
stops only the process it launched. Startup observation is capped at 60 seconds
and idle sampling at 300 seconds. Without `xdotool`, it reports time to the
first nonzero `/proc` RSS sample as a startup proxy; this is **not** time to
first frame. The CPU and memory figures are averaged over the idle sample.

Use a temporary seeded directory. The script requires `500/notes.db` and
refuses to run when the data directory equals the configured `NOTES_DATA_DIR`.

## Android launch and diagnostics

Install a test build containing synthetic data on an emulator, then supply its
explicit adb serial and package id:

```sh
tool/perf/android_startup.sh emulator-5554 com.example.notes.test
```

The target must be detected as an emulator. `--allow-physical` explicitly opts
out of that check. The script uses `adb -s`, launches the package's main
launcher activity with `am start -W`, and reports launch timing, total PSS from
`dumpsys meminfo`, and rendered/janky frame counts from `dumpsys gfxinfo` when
available. It does not clear or modify app data. It refuses the legacy package
`com.saadhjawwadh.notebook`.

Emulator frame rates are software-rendered and are not representative of phone
performance. Treat these diagnostics as functional smoke measurements only.

## JIT regression tests

```sh
flutter test test/perf/perf_harness_test.dart
flutter test test/tool/perf_seed_test.dart
```

The performance test times listing and searching a synthetic 500-note in-memory
database and parsing/loading a roughly 200 KiB Delta into a Quill `Document`.
The bounds are intentionally loose and include JIT VM overhead. Existing larger
experiments remain available separately:

```sh
flutter test test/perf/data_bench_test.dart
```

Those existing cases cover 5,000-note write/list/search/edit and a 1 MiB note;
they can take longer and are not part of the new focused harness.

## Limits and interpretation

- Run on a quiet machine and record OS, device/CPU, Flutter version, build mode,
  display scale, and whether `xdotool` was used when comparing runs.
- JIT test timings, emulator graphics, debug builds, and first-run filesystem
  caches do not predict release phone performance.
- The Linux `/proc` startup fallback measures process RSS availability, not a
  rendered frame. `xdotool` window appearance is an OS-level approximation and
  may depend on the window title and desktop session.
- Search/list tests use one in-memory SQLite database; they do not measure disk
  latency, encryption, app startup, sync, or background behavior.
- The tools do not produce benchmark claims automatically. Report measured
  values with the environment and leave unavailable measurements marked
  unmeasured.
