# Building a Ray 2.57.0 wheel for Windows + Python 3.13

## Quickstart

```bash
# ELEVATED Git Bash (right-click → Run as administrator), from the repo root:
FIX_SYMLINKS=1 SKIP_DASHBOARD=1 PY=3.13 bash my_windows_build/build-wheel.sh
# → my_windows_build/out/ray-2.57.0-cp313-cp313-win_amd64.whl
```

That is the exact command that produced the verified wheel. Elevation is not
optional — see [Symlink privilege](#symlink-privilege-read-this). The script
now handles the local archive cache, stale Bazel servers, and download retries
by itself; the sections below explain each in case something still goes wrong.

Upstream publishes no Windows wheel for Python 3.13 — the CI matrix in
`.buildkite/windows.rayci.yml:41` covers only 3.10/3.11/3.12. The source itself
supports 3.13 (`python/setup.py:836`, and Linux builds it at
`.buildkite/_wheel-build.rayci.yml:12`), so it only needs to be built.

`bazel run //ci/ray_ci:build_in_docker_windows` cannot work outside Anyscale:
`ci/ray_ci/builder.py:82` logs into a private ECR registry unconditionally, and
the `windowsbuild` image derives from `rayproject/buildenv:windows`, which is not
published anywhere public. These scripts skip the container and build natively.

**This must run on a real Windows machine or VM.** Docker on Linux cannot run
Windows containers, and the build needs MSVC.

## 1. Prerequisites

| What | Notes |
| --- | --- |
| **MSVC C++ Build Tools** (2019 or 2022) | `winget install Microsoft.VisualStudio.2022.BuildTools`, then add the "Desktop development with C++" workload in the Visual Studio Installer. Install the **English language pack** too, or Bazel cannot parse `/showIncludes` and disables header pruning (slower rebuilds) |
| **Git for Windows** | Provides the Git Bash shell everything below runs in |
| **Bazelisk** | `choco install bazelisk` (or drop the binary on PATH as `bazel`). It reads `.bazelversion` and fetches Bazel 7.5.0 |
| **uv** | `choco install uv`. Downloads the target CPython for you |
| **Node.js 22** | Only needed without `SKIP_DASHBOARD=1` |
| **Symlink privilege** | See below — this is the one that actually bites |

Verify in Git Bash:

```bash
bazel --version && uv --version
```

### Symlink privilege (read this)

Bazel builds the runfiles tree of every host tool out of real NTFS symlinks —
`.bazelrc:59` turns `--enable_runfiles` on for Windows, where Bazel otherwise
defaults it off. Creating a symlink needs `SeCreateSymbolicLinkPrivilege`,
which an ordinary Windows account does not hold. Without it the build dies
about two minutes in:

```
build-runfiles error: CreateSymbolicLinkW failed:
Target //:gen_redis_pkg failed to build
```

…wrapped in a long setuptools traceback that makes it look like a packaging
bug. `build-wheel.sh` now checks for the privilege up front and refuses to
start instead. Three ways to satisfy it:

1. **Run the build from an elevated Git Bash** (right-click → Run as
   administrator). Nothing is installed or permanently changed.
2. **Enable Developer Mode** (Settings → System → For developers), then open a
   new shell. This is the persistent fix and is also what lets git create
   symlinks.
3. **`ALLOW_NO_SYMLINKS=1`** — builds anyway by passing
   `--enable_runfiles=false`. Upstream uses this same flag for conda-forge
   Windows builds (`python/setup.py:649`), so it does produce a wheel. It does
   not repair the broken checkout described next.

### Broken symlinks in the checkout

Git for Windows defaults `core.symlinks` to `false`, so a fresh clone writes
Ray's 32 tracked symlinks as small text files containing their link target.
The one that matters is `python/ray/rllib` — an 11-byte file reading
`../../rllib` instead of a link to the RLlib tree. A wheel built from such a
checkout has a non-importable `ray.rllib`.

Check:

```bash
git ls-files -s | awk '$1=="120000"{print $4}'   # the 32 tracked symlinks
cat python/ray/rllib                             # should not print a path
```

Repair by passing `FIX_SYMLINKS=1` (needs an elevated shell or Developer Mode).
The script sets `core.symlinks`, then **deletes and re-checks-out** each link —
a plain `git checkout --` can decide there is nothing to do, because the blob
content (the target path) already matches what is on disk. Without the flag,
`build-wheel.sh` only warns.

The effect is not subtle: with `python/ray/rllib` repaired, `setup.py` walks the
real tree and the wheel gains **774 RLlib entries** that were silently absent
before.

## 2. Build

From the repository root, in **Git Bash** (elevated, per the section above):

```bash
FIX_SYMLINKS=1 SKIP_DASHBOARD=1 PY=3.13 bash my_windows_build/build-wheel.sh
```

Expect a long run — this compiles Ray's C++ core from scratch. On a warm
Bazel cache the observed end-to-end time was roughly 15 minutes.

The finished wheel lands in `my_windows_build/out/`.

### Verifying the result

Exit code 0 is not proof the wheel is complete — a broken symlink checkout
still exits 0, just without RLlib. Check the artifact itself:

```bash
python -c "
import zipfile; z=zipfile.ZipFile('my_windows_build/out/ray-2.57.0-cp313-cp313-win_amd64.whl')
n=z.namelist(); print(z.read('ray-2.57.0.dist-info/WHEEL').decode())
for p in ['ray/_raylet.pyd','ray/core/src/ray/raylet/raylet.exe']: print(p, p in n)
for pre in ['ray/rllib/','ray/serve/']: print(pre, sum(1 for x in n if x.startswith(pre)))
print([x for x in n if x.lower().endswith('.dll')])"
```

A good build reports `Tag: cp313-cp313-win_amd64`, `Root-Is-Purelib: false`,
both binaries present, ~774 `ray/rllib/` and ~135 `ray/serve/` entries, and
`ray.libs/msvcp140-*.dll` bundled by delvewheel. Read
`ray-2.57.0.dist-info/WHEEL` by name — the wheel contains many vendored
`.dist-info` directories, so grabbing "the first" one yields some third-party
package's metadata instead.

### If Bazel fails to download a dependency

Two symptoms, one cause:

```
Error downloading [...zstd-1.5.2.tar.gz]: GET returned 429 Too Many Requests
Error downloading [...zstd-1.5.2.tar.gz]: Bytes read 1850368 but wanted 1950967
```

Both are GitHub throttling you — the second is the same rate limit arriving as a
truncated response instead of a clean status code. Repeated build attempts make
it worse, so **do not just re-run**. Most of Ray's own dependencies go through
`auto_http_archive` (`bazel/ray_deps_setup.bzl:23`), which fans each URL out to
`mirror.bazel.build` and the Google mirror. Dependencies pulled in by
*rules_boost* do not — `com_github_facebook_zstd` declares a single `url` with
no fallback, which makes it the usual choke point.

**The script already handles this.** It passes `--distdir=$DISTDIR` (default
`C:/tmp/distdir`, a directory Bazel checks by URL basename + sha256 before
reaching for the network). When a build fails, it harvests every URL from
Bazel's `Error downloading [...]` lines, curls them into the distdir with
retries, and tries again — up to `BUILD_ATTEMPTS` times (default 3). A failure
with no download errors in it never retries.

To seed an archive by hand:

```bash
mkdir -p /c/tmp/distdir && cd /c/tmp/distdir
curl -sSL --retry 6 --retry-delay 10 --retry-all-errors \
  -O https://github.com/facebook/zstd/archive/v1.5.2/zstd-1.5.2.tar.gz
sha256sum zstd-1.5.2.tar.gz   # must match boost/boost.bzl
```

The sha256 for each archive is in the declaring `.bzl` file — for the
rules_boost set, `boost/boost.bzl` inside the fetched
`com_github_nelhage_rules_boost` external repo. If the hash does not match,
Bazel silently ignores the distdir copy and goes back to the network.

### Do not leave stale Bazel servers running

Bazel is a client/server system and the **server** does the work, including
spawning `build-runfiles.exe`. If a Bazel daemon is already running for an
output base, a newly elevated client just connects to that existing,
unelevated server and inherits none of its privileges — so the build fails
with `CreateSymbolicLinkW failed` even though you elevated correctly. This is
easy to misread as "elevation didn't work".

`python/setup.py:665` pins `--output_user_root=C:/tmp` on Windows, so there are
two output bases in play. `build-wheel.sh` now shuts both down on every run;
pass `SKIP_BAZEL_SHUTDOWN=1` to keep the in-memory analysis cache when you know
no server is running at a different privilege level. By hand:

```bash
bazel --output_user_root=C:/tmp shutdown
bazel shutdown
```

### About `SKIP_DASHBOARD=1`

It skips the React frontend build and removes the Node.js requirement. Ray Serve
still works: on Windows a missing `client/build` is downgraded to a warning
(`python/ray/dashboard/http_server_head.py:118`). The dashboard HTTP API and the
Serve control plane live in Python modules that ship regardless — you lose only
the dashboard **web UI**.

Drop the variable to build the UI too:

```bash
PY=3.13 bash my_windows_build/build-wheel.sh
```

## 3. Install

`ray[serve]` is not a separate artifact — extras are metadata inside this one
wheel (`python/setup.py:238`). Install the extra against the local file:

```bash
pip install "ray[serve] @ file:///C:/path/to/my_windows_build/out/ray-2.57.0-cp313-cp313-win_amd64.whl"
```

The `build-wheel.sh` output prints this line with the real path filled in.

All binary dependencies of the `serve` and `default` extras publish Windows
CPython 3.13 wheels on PyPI (grpcio, aiohttp, mmh3, watchfiles, httptools,
pydantic-core; py-spy ships a universal `py2.py3-none-win_amd64`). `ray-haproxy`
is gated behind `sys_platform == 'linux'` (`python/setup.py:283`) and is skipped.

## Files here

| File | Purpose |
| --- | --- |
| `build-wheel.sh` | Driver: tool checks → symlink preflight → optional symlink repair → Bazel shutdown → distdir setup → dashboard → version stamp → build (with download-retry) → collect output |
| `_build_inner.sh` | Runs under `uv run --python 3.13`; does the actual pip/delvewheel work |

Environment variables `build-wheel.sh` understands:

| Variable | Default | Purpose |
| --- | --- | --- |
| `PY` | `3.13` | Target Python; uv downloads it |
| `SKIP_DASHBOARD` | `0` | Skip the React frontend build (drops the Node.js prerequisite) |
| `FIX_SYMLINKS` | `0` | Re-checkout the 32 tracked symlinks as real links |
| `DISTDIR` | `C:/tmp/distdir` | Local archive cache passed as `--distdir` |
| `BUILD_ATTEMPTS` | `3` | Retries after a failed dependency download |
| `SKIP_BAZEL_SHUTDOWN` | `0` | Keep running Bazel servers instead of stopping them |
| `ALLOW_NO_SYMLINKS` | `0` | Build unprivileged via `--enable_runfiles=false` |
| `BAZEL_ARGS` | — | Extra Bazel flags (`python/setup.py:630`); the script appends to it |
| `BAZEL_SH` | Git Bash | `bash.exe` Bazel should use |

`build-wheel.sh` deliberately differs from `python/build-wheel-windows.sh`:

- **No `git clean -f -f -x -d` / `git checkout -f -- .`.** The CI script wipes
  untracked files and local edits; this one does not.
- **No remote Bazel cache and no S3 upload.** Both are Buildkite-only.
- **No `RAY_INSTALL_CPP=1` pass.** That second packaging run exists solely for
  the `ray[cpp]` extra (`python/setup.py:307`), which Serve does not use.
- **`delvewheel repair -w wheelhouse`.** The CI script's bare `delvewheel repair`
  writes to the default `wheelhouse/`, but `ci/build/copy_build_artifacts.sh`
  publishes `python/dist` — so the repaired wheel and the published one may not
  be the same file. Here the repaired wheel is copied to `out/` explicitly.
- **`python/ray/_version.py` is restored after the build**, so the working tree
  stays clean.

## Caveats

- **`FIX_SYMLINKS=1` changes your working tree.** It converts 32 tracked files
  into real symlinks and sets `core.symlinks=true` in the repo's git config.
  That is the correct state, but it is a persistent local change, and `git
  status` behaves differently afterwards.
- **The wheel has no dashboard web UI** when built with `SKIP_DASHBOARD=1`
  (verified: zero `ray/dashboard/client/build` entries). The Serve control
  plane and the dashboard HTTP API are unaffected.
- If you previously built a different Python version in this checkout, run
  `bazel clean --expunge` first. The Python headers come from a cached Bazel repo
  rule (`bazel/ray_deps_build_all.bzl:19`) that may not otherwise re-resolve.
- Ray does not test Serve on Windows in CI — `.buildkite/windows.rayci.yml` runs
  only the core C++/Python suites. This is an untested-by-upstream configuration
  no matter how the wheel is produced. Smoke-test a real deployment before
  relying on it.
- If Bazel runs the machine out of memory, add to `~/.bazelrc`:
  `build --local_resources=memory=HOST_RAM*.5 --local_resources=cpu=4`
