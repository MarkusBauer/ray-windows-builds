#!/usr/bin/env bash
# Build a Ray wheel natively on Windows, without the internal CI docker image.
#
# Run from an *elevated* Git Bash on the Windows machine:
#     FIX_SYMLINKS=1 SKIP_DASHBOARD=1 PY=3.13 bash my_windows_build/build-wheel.sh
#
# Mirrors python/build-wheel-windows.sh minus the Buildkite-only bits (remote
# bazel cache, destructive `git clean`, S3 upload) and minus the ray-cpp pass,
# which only feeds the ray[cpp] extra and is irrelevant for ray[serve].
#
# Environment:
#   PY=3.13            target Python version (uv downloads it)
#   SKIP_DASHBOARD=1   skip the React frontend build; drops the Node.js
#                      prerequisite. Serve still works -- on Windows a missing
#                      client/build is downgraded to a warning, see
#                      python/ray/dashboard/http_server_head.py:118. You lose
#                      only the dashboard web UI.
#   FIX_SYMLINKS=1     re-checkout Ray's 32 tracked symlinks as real links.
#                      Needed once per clone on Windows, see README.
#   BAZEL_SH=...       path to bash.exe for bazel (default: Git Bash)
#   BAZEL_ARGS=...     extra flags forwarded to bazel by python/setup.py:630
#   DISTDIR=...        local archive cache handed to bazel as --distdir
#                      (default C:/tmp/distdir). Archives that fail to download
#                      are fetched into it and the build is retried.
#   BUILD_ATTEMPTS=n   how many times to retry after a failed dependency
#                      download (default 3). Non-download failures never retry.
#   SKIP_BAZEL_SHUTDOWN=1
#                      do not stop running bazel servers first. Only safe if
#                      you know no server is running at a different privilege
#                      level -- see README.
#   ALLOW_NO_SYMLINKS=1
#                      build without the privilege to create symlinks, by
#                      passing --enable_runfiles=false to bazel. See the
#                      symlink preflight below for what this costs you.

set -euo pipefail

PY="${PY:-3.13}"
SKIP_DASHBOARD="${SKIP_DASHBOARD:-0}"
FIX_SYMLINKS="${FIX_SYMLINKS:-0}"
DISTDIR="${DISTDIR:-C:/tmp/distdir}"
BUILD_ATTEMPTS="${BUILD_ATTEMPTS:-3}"
SKIP_BAZEL_SHUTDOWN="${SKIP_BAZEL_SHUTDOWN:-0}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HERE/.." && pwd)"
OUT_DIR="$HERE/out"

log() { echo "==> $*"; }

# --- sanity checks ------------------------------------------------------
missing=0
for tool in git bazel uv curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: '$tool' not found on PATH" >&2
    missing=1
  fi
done
if [[ "$SKIP_DASHBOARD" != "1" ]] && ! command -v npm >/dev/null 2>&1; then
  echo "ERROR: 'npm' not found on PATH (or re-run with SKIP_DASHBOARD=1)" >&2
  missing=1
fi
if [[ "$missing" != "0" ]]; then
  echo "See my_windows_build/README.md for prerequisites." >&2
  exit 1
fi

# bazel needs a real bash on Windows
export BAZEL_SH="${BAZEL_SH:-C:/Program Files/Git/usr/bin/bash.exe}"
if [[ ! -f "$BAZEL_SH" ]]; then
  echo "ERROR: BAZEL_SH does not point at an existing bash.exe: $BAZEL_SH" >&2
  exit 1
fi
log "BAZEL_SH=$BAZEL_SH"
log "target Python: $PY"

# --- symlink preflight --------------------------------------------------
# Bazel builds the runfiles tree for every host tool out of real symlinks
# (.bazelrc:59 turns `--enable_runfiles` on for Windows, where bazel otherwise
# defaults it off). Creating one needs SeCreateSymbolicLinkPrivilege, which a
# normal Windows account does not hold. Without it the build dies ~2 minutes in
# on //:gen_redis_pkg with "build-runfiles error: CreateSymbolicLinkW failed",
# buried under a setuptools traceback -- check up front instead.
can_symlink() {
  local d link
  d="$(mktemp -d)" || return 1
  link="$d/link"
  # Git Bash fakes symlinks by copying unless told to use the real API.
  MSYS=winsymlinks:nativestrict ln -s "$d" "$link" 2>/dev/null
  local rc=$?
  rm -rf "$d"
  return "$rc"
}

if can_symlink; then
  log "symlink privilege: ok"
elif [[ "${ALLOW_NO_SYMLINKS:-0}" == "1" ]]; then
  log "WARNING: no symlink privilege; adding --enable_runfiles=false"
  echo "    The build will succeed, but any of Ray's 32 tracked symlinks that" >&2
  echo "    git checked out as plain text files stay broken in the wheel --" >&2
  echo "    notably python/ray/rllib, so 'import ray.rllib' will fail." >&2
  BAZEL_ARGS="${BAZEL_ARGS:-} --enable_runfiles=false"
else
  cat >&2 <<'EOF'
ERROR: this account cannot create Windows symlinks, which bazel requires to
build runfiles trees. Pick one:

  1. Re-run this script from an *elevated* Git Bash (Run as administrator).
     Nothing is installed or changed permanently.
  2. Turn on Developer Mode (Settings > System > For developers), open a new
     shell, and re-run. This is the persistent fix and is also what lets git
     materialize Ray's tracked symlinks.
  3. Re-run with ALLOW_NO_SYMLINKS=1 to build anyway via
     --enable_runfiles=false. Upstream uses this same flag for conda-forge
     Windows builds (python/setup.py:649), so the wheel does build -- but see
     the caveat printed by that path.

Separately: `git config core.symlinks` is off in fresh Windows clones, so
python/ray/rllib and python/requirements_compiled_py3.13.txt are plain text
files holding their link targets. Options 1 and 2 let this script repair them
for you -- re-run with FIX_SYMLINKS=1.
EOF
  exit 1
fi

# --- repair the tracked symlinks ---------------------------------------
# Git for Windows defaults core.symlinks to false, so a fresh clone writes all
# 32 tracked symlinks as small text files containing their target path. Delete
# then re-checkout: git considers the blob content unchanged, so a plain
# `git checkout --` on its own may decide there is nothing to do.
if [[ "$FIX_SYMLINKS" == "1" ]]; then
  log "repairing tracked symlinks"
  (
    cd "$ROOT_DIR"
    git config core.symlinks true
    mapfile -t symfiles < <(git ls-files -s | awk '$1=="120000"{print $4}')
    log "  tracked symlinks: ${#symfiles[@]}"
    if (( ${#symfiles[@]} > 0 )); then
      rm -f "${symfiles[@]}"
      git checkout -- "${symfiles[@]}"
    fi
    for f in "${symfiles[@]}"; do
      [[ -L "$f" ]] || echo "  WARNING: still not a link: $f" >&2
    done
  )
fi

if [[ -f "$ROOT_DIR/python/ray/rllib" ]]; then
  echo "WARNING: python/ray/rllib is a regular file, not a symlink -- this" >&2
  echo "         checkout has broken symlinks and the wheel will ship a" >&2
  echo "         non-importable ray.rllib. Re-run with FIX_SYMLINKS=1." >&2
fi

# --- stop stale bazel servers ------------------------------------------
# Bazel is client/server and the *server* does the work, including spawning
# build-runfiles.exe. An elevated client that connects to an already-running
# unelevated server inherits none of its privileges, so the build still fails
# with CreateSymbolicLinkW. python/setup.py:665 pins --output_user_root=C:/tmp
# on Windows, so there are two output bases in play.
if [[ "$SKIP_BAZEL_SHUTDOWN" != "1" ]]; then
  log "stopping any running bazel servers (privileges are per-server)"
  (cd "$ROOT_DIR" && bazel --output_user_root=C:/tmp shutdown >/dev/null 2>&1) || true
  (cd "$ROOT_DIR" && bazel shutdown >/dev/null 2>&1) || true
fi

# --- local archive cache ------------------------------------------------
# GitHub rate-limits (HTTP 429, sometimes surfacing as a truncated body) when a
# dependency is re-fetched across repeated builds. Ray's own deps mirror
# through auto_http_archive (bazel/ray_deps_setup.bzl:23), but rules_boost's do
# not -- com_github_facebook_zstd has a single url and no fallback. --distdir
# lets bazel satisfy an archive from disk, matched on basename + sha256.
mkdir -p "$DISTDIR"
BAZEL_ARGS="${BAZEL_ARGS:-} --distdir=$DISTDIR"
export BAZEL_ARGS
log "DISTDIR=$DISTDIR"
log "BAZEL_ARGS=$BAZEL_ARGS"

# Pull every archive bazel failed to download into DISTDIR. Returns non-zero
# when there was nothing download-related to fix, so the caller stops retrying.
seed_failed_downloads() {
  local logfile="$1" urls u fn seeded=0
  urls="$(grep -oE 'Error downloading \[[^]]+\]' "$logfile" \
           | sed 's/Error downloading \[//; s/\]$//' \
           | tr ',' '\n' \
           | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
           | grep -E '^https?://' | sort -u || true)"
  [[ -z "$urls" ]] && return 1
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    fn="$(basename "${u%%\?*}")"
    log "  seeding $fn"
    if curl -sSL --retry 8 --retry-delay 15 --retry-all-errors --max-time 600 \
         -o "$DISTDIR/$fn" "$u"; then
      log "    ok  sha256=$(sha256sum "$DISTDIR/$fn" | cut -d' ' -f1)"
      seeded=1
    else
      log "    FAILED: $u"
      rm -f "$DISTDIR/$fn"
    fi
  done <<< "$urls"
  [[ "$seeded" == "1" ]]
}

# --- 1. dashboard frontend ---------------------------------------------
if [[ "$SKIP_DASHBOARD" == "1" ]]; then
  log "skipping dashboard frontend build (SKIP_DASHBOARD=1)"
else
  log "building dashboard frontend"
  (
    cd "$ROOT_DIR/python/ray/dashboard/client"
    # react-scripts predates OpenSSL 3's default provider set
    export NODE_OPTIONS=--openssl-legacy-provider
    npm ci || npm install
    npm run build
  )
fi

# --- 2. stamp the commit sha into ray/_version.py ----------------------
# _version.py is a tracked file; restore it afterwards so the tree stays clean.
VERSION_PY="$ROOT_DIR/python/ray/_version.py"
BUILD_LOG="$(mktemp)"
cleanup() {
  git -C "$ROOT_DIR" checkout -- python/ray/_version.py 2>/dev/null || true
  rm -f "$BUILD_LOG"
}
trap cleanup EXIT

COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
log "stamping commit $COMMIT into ray/_version.py"
sed -i.bak "s/{{RAY_COMMIT_SHA}}/${COMMIT}/g" "$VERSION_PY"
rm -f "$VERSION_PY.bak"

# --- 3. build the wheel with the requested interpreter ------------------
# uv downloads CPython $PY and puts it first on PATH. The inner script runs
# under that interpreter; see _build_inner.sh for why that matters to bazel.
log "building wheel (this takes a while -- it compiles the C++ core)"
rc=1
for attempt in $(seq 1 "$BUILD_ATTEMPTS"); do
  log "build attempt $attempt of $BUILD_ATTEMPTS"
  set +e
  (
    cd "$ROOT_DIR/python"
    uv run --no-project --no-config \
      --with wheel==0.45.1 \
      --with delvewheel==1.11.2 \
      --with setuptools==80.9.0 \
      --with pip==25.2 \
      --python "$PY" \
      bash "$HERE/_build_inner.sh"
  ) 2>&1 | tee "$BUILD_LOG"
  rc=${PIPESTATUS[0]}
  set -e

  [[ "$rc" -eq 0 ]] && break
  log "attempt $attempt failed (exit $rc)"
  if seed_failed_downloads "$BUILD_LOG"; then
    log "seeded missing archives; backing off before retry"
    sleep 30
  else
    log "not a dependency-download failure -- not retrying"
    break
  fi
done

if [[ "$rc" -ne 0 ]]; then
  echo "ERROR: build failed after $attempt attempt(s)" >&2
  exit "$rc"
fi

# --- 4. collect the repaired wheel -------------------------------------
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/ray-*.whl
cp "$ROOT_DIR"/python/wheelhouse/ray-*.whl "$OUT_DIR"/

log "done. Wheel(s):"
ls -l "$OUT_DIR"
echo
echo "Install with:"
for whl in "$OUT_DIR"/ray-*.whl; do
  echo "  pip install \"ray[serve] @ file://$(cygpath -m "$whl" 2>/dev/null || echo "$whl")\""
done
