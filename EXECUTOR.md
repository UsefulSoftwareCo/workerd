# Executor build of workerd

This fork carries a few patches that Executor's self-hosted image needs on top of an upstream
workerd release. Branches are named `executor/<upstream tag>`; each one starts at that tag.

The patches only change behavior when enabled through `Config.memory` in `workerd.capnp`
(see `src/workerd/server/workerd.capnp`). Without it, the binary behaves like upstream.

| Commit | Setting | Problem it addresses |
| --- | --- | --- |
| Collect garbage in idle isolates | `idleIsolateGcDelayMs`, `idleIsolateGcMode`, `idleTaskPumpMs`, `pressureThresholdMb`, `pressureCooldownMs` | V8's memory reducer runs from foreground tasks that workerd only pumps at the end of a request, so an idle isolate keeps its peak heap. |
| Return free TCMalloc memory to the OS | `tcmallocBackgroundReleaseBytesPerSecond`, `releaseMemoryAfterGc` | workerd never runs TCMalloc's background actions, so freed memory stays in TCMalloc's page heap. |
| Unload idle named Worker loader isolates | `workerLoaderIdleTtlMs` | Named Worker loader isolates are kept until `abortIsolate()`, although the binding documents unloading unused Workers. |
| Allow reloading an unloaded Worker loader name with the inspector on | (always on) | With `--inspector-addr`, loading a name again after it was unloaded failed with "inserted row already exists in table". |

## Releases

`.github/workflows/executor-release.yml` builds Linux x64 and arm64 release binaries on every push
to an `executor/**` branch, runs `.github/executor/smoke-test.sh` against them, and publishes a
GitHub release tagged `<upstream tag>-executor.<commit>` with gzipped binaries and `SHA256SUMS`.

The release job first uploads the packaged files as the `release-files` artifact. Workflow tokens
in UsefulSoftwareCo default to read-only; two runs were refused release creation (HTTP 403) before
later runs succeeded with the same settings. If publishing is refused again, create the release
from that artifact with `gh release create`, or use the `from_run` input once publishing works.

The build uses standard GitHub-hosted runners and the Actions cache for Bazel's disk cache; there
is no remote cache. A cold build takes about two hours.
