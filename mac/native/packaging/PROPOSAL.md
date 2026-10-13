# Proposal: `mac-native-tools` workflow (self-contained converter bundle, macOS arm64)

For the lead. Nothing here has been committed, pushed or run. Static checks on the PC all pass
(`bash -n`, shellcheck 0.11.0 `-S warning -x` and `-S info`, actionlint 1.7.12 with shellcheck,
yamllint 1.35.1 with the repo config, `py_compile`); `--check-pins` passes and rejects FILL values,
range specifiers, missing hashes and mismatched URLs (tested).

## Files for the repo (jmproulx/peakpack)

| PC path (`C:\Users\joshu\PeakMods\MacPort\`) | Repo path | Mode |
|---|---|---|
| `native\ci\mac-native-tools.yml` | `.github/workflows/mac-native-tools.yml` (copy; optionally also keep at `mac/native/ci/`) | 644 |
| `native\packaging\build_bundle.sh` | `mac/native/packaging/build_bundle.sh` | 755 |
| `native\packaging\verify_bundle.sh` | `mac/native/packaging/verify_bundle.sh` | 755 |
| `native\packaging\smoke.py` | `mac/native/packaging/smoke.py` | 644 |
| `native\packaging\pins.env` | `mac/native/packaging/pins.env` | 644 |
| `native\packaging\requirements.lock` | `mac/native/packaging/requirements.lock` | 644 |
| `native\packaging\requirements-build.lock` | `mac/native/packaging/requirements-build.lock` | 644 |
| `native\packaging\README.md` | `mac/native/packaging/README.md` | 644 |
| `native\packaging\PROPOSAL.md` | `mac/native/packaging/PROPOSAL.md` (or leave out) | 644 |

The workflow calls the scripts with `bash ...`, so the exec bit is not required, but set it
(`git update-index --chmod=+x`). All files are LF. `mac/.gitattributes` has no rule for `*.lock`; pip reads
CRLF fine, but adding `*.lock text eol=lf` keeps them byte-stable (optional).

The build also needs, already in the repo or coming from the converter team: `mac/LICENSE` (MIT; cone-mode
sparse checkout of `mac/native` includes it), `mac/native/pm.py`, `mac/native/peakmetal/**` (`.py` only), and
the `doctor` command in peakmetal (`native/NOTES-bundle.md`). The converter's `tests/` are not used.

Not touched: `mac/runtime/**`, `mac-runtime.yml`, `mac-runtime-lint.yml`, their caches (this workflow uses
**no cache at all**: the downloads are ~85 MB and hash-checked, so a cache would save seconds and add a
poisoning surface).

## What runs

Trigger: `workflow_dispatch` only; input `publish` (boolean, default `false`). `permissions: contents: read`
at the top; only the release job gets `contents: write`. No secrets (the release job uses `github.token`).
`concurrency: mac-native-tools`, no cancel. Actions pinned by commit SHA: checkout v7.0.1
`3d3c42e5…`, upload-artifact v7.0.2 `cf430e03…`, download-artifact v8.0.2 `9000827c…` (resolved with gh
12 Oct 2026; tags are lightweight, i.e. the SHAs are commits).

1. **guard** (ubuntu-24.04, ~20 s): sparse checkout `mac/native`; `build_bundle.sh --check-pins`; outputs the
   version; if `publish=true`, fails unless `pins.env` has `NT_PUBLISH_ALLOWED=1` (it is `0`, so **only
   publish=false runs are possible now**; enabling publishing needs a reviewed commit).
2. **build** (macos-15 = arm64, timeout 60 min): sparse checkout; runner facts (fails if not arm64);
   `build_bundle.sh` (see README "What the build does"; it ends with `check/verify_bundle.sh --ci` in place,
   which includes `bin/pm doctor`); then a second smoke on the **packed** tarball: `shasum -c`, fresh extract
   into a path containing a space, `verify_bundle.sh --ci` again; upload the artifact.
3. **release** (ubuntu-24.04, only if `publish=true`, so skipped now): re-runs `--check-pins` and the
   `NT_PUBLISH_ALLOWED` check, downloads the artifact, `sha256sum -c`, refuses if the tag exists, then
   `gh release create mac-build-native-tools-<ver> --prerelease --latest=false --target $GITHUB_SHA` with the
   tarball, `.sha256` and manifest. Never marked latest.

## Outputs

Artifact `peakpack-native-tools-<ver>-macos-arm64` (retention 30 days, stored uncompressed) containing:
- `peakpack-native-tools-0.1.0-macos-arm64.tar.xz`: expected ~15–25 MB (stage ~55–60 MB: CPython ~45 MB after
  pruning, packages ~12 MB, spirv-cross ~3 MB);
- `....tar.xz.sha256` (`shasum -c` format);
- `....MANIFEST.json` (copy of the one inside: versions, URLs and SHA-256 of every input, pip's own install
  report, SPIRV-Cross commit/revision/cmake flags/binary hash, converter file hashes, builder image/Xcode/cmake,
  pruned paths, source repo/commit/run).

## Runner minutes (public repo: free)

Per run: guard ~0.5 min (Linux) + build ~8–12 min (macOS arm64: downloads <1 min, pip <1 min, SPIRV-Cross
Release build ~3–5 min on 3 cores, byte-compile ~0.5 min, two verify passes ~1–2 min, xz -9 ~1–2 min) +
release ~0.5 min when enabled. GitHub-hosted runners, macOS included, are free for public repositories.

## First-run unknowns (worth watching in the log)

- `bin/pm doctor` must exist and exit 0 with no game data on the runner (converter team, in progress). If it
  is missing the build fails at the verify step after everything else has been checked.
- `zstd` on the macos-15 image: used only to read the licence files out of the full CPython archive; if absent
  the script installs it from Homebrew (logged; `HOMEBREW_NO_AUTO_UPDATE=1`).
- The full archive's member paths `python/licenses/` and `python/PYTHON.json` (python-build-standalone's
  documented layout; not inspectable on the PC without zstd).
- Mach-O minimum-version check: every shipped binary must target macOS ≤ 11.0 (python-build-standalone and the
  arm64 wheels are 11.0, Brotli universal2 10.13, spirv-cross is built for 11.0). A failure names the file.

## After a green publish=false run

Download the artifact, then G-C0 phase (b) on the iMac per README "Using it on a Mac". When that passes, a
commit setting `NT_PUBLISH_ALLOWED=1` lets a `publish=true` run create the prerelease.
