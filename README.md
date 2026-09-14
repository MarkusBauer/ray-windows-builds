# Ray Windows Builds

Windows x86-64 wheels of [Ray](https://github.com/ray-project/ray) for Python
versions that upstream does not publish (e.g. 3.13). Built natively with MSVC
by a manually triggered GitHub Actions workflow; the finished wheel is attached
to a GitHub release.

## Building a wheel

1. **Actions → "Build Ray wheel (Windows x64)" → Run workflow**
2. Fill in
   - `ray_version` – Ray release, e.g. `2.57.0` (must exist as tag `ray-2.57.0` upstream)
   - `python_version` – target CPython, e.g. `3.13`
3. Wait. A cold build compiles Ray's C++ core on a 4-core runner and takes a
   few hours; the workflow has a 6-hour limit. Repeat builds of the same Ray
   version (e.g. another Python version) reuse a best-effort Bazel disk cache
   and are much faster.

On success the workflow

- uploads the wheel as a workflow artifact, and
- creates tag + release **`<ray-version>-py<python-version>`** (e.g.
  `2.57.0-py3.13`) with the wheel and a `SHA256SUMS` attached.

The workflow refuses to run if that release or tag already exists — delete
both to rebuild.

## Installing

```
pip install "ray[serve] @ https://github.com/<owner>/ray-windows-builds/releases/download/2.57.0-py3.13/ray-2.57.0-cp313-cp313-win_amd64.whl"
```

The exact command is in each release's notes.

## What the wheel contains

- Windows x64 only, no dashboard **web UI** (`SKIP_DASHBOARD=1`). Ray Serve
  and the dashboard HTTP API work; only the React frontend is missing.
- MSVC runtime DLLs bundled by `delvewheel`.
- `ray.rllib` included (the tracked symlinks are repaired before building).
- Not tested by Ray upstream in this configuration — smoke-test before use.
