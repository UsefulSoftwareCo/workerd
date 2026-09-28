# Executor build of workerd

This fork carries a few patches that Executor's self-hosted image needs on top of an upstream
workerd release. Branches are named `executor/<upstream tag>`; each one starts at that tag.

The memory patches only change behavior when enabled through `Config.memory` in `workerd.capnp`
(see `src/workerd/server/workerd.capnp`). The inspector fix below is the one exception: it is always
on, and only changes a case that fails upstream. Otherwise, without `Config.memory`, the binary
behaves like upstream; the smoke test checks that the default config logs no memory maintenance.

| Commit | Setting | Problem it addresses |
| --- | --- | --- |
| Collect garbage in idle isolates, Pace memory pressure collections | `idleIsolateGcDelayMs`, `idleIsolateGcMode`, `idleTaskPumpMs`, `pressureThresholdMb`, `pressureCooldownMs`, `pressureGcBudgetMs` | V8's memory reducer runs from foreground tasks that workerd only pumps at the end of a request, so an idle isolate keeps its peak heap. |
| Return free TCMalloc memory to the OS | `tcmallocBackgroundReleaseBytesPerSecond`, `releaseMemoryAfterGc` | workerd never runs TCMalloc's background actions, so freed memory stays in TCMalloc's page heap. |
| Unload idle named Worker loader isolates, Keep Worker loader entries loaded while waitUntil work or actors run | `workerLoaderIdleTtlMs` | Named Worker loader isolates are kept until `abortIsolate()`, although the binding documents unloading unused Workers. |
| Allow reloading an unloaded Worker loader name with the inspector on | (always on) | With `--inspector-addr`, loading a name again after it was unloaded failed with "inserted row already exists in table". |

### Notes on the memory patches

- Memory pressure collections block the event loop. A pass over the isolates spends at most
  `pressureGcBudgetMs` per maintenance interval, skips isolates that have not run since their last
  full collection, and backs off while passes leave usage above the threshold. Usage is the cgroup
  v2 working set (`memory.current` minus `inactive_file`), not `memory.current`, which also counts
  reclaimable page cache.
- The maintenance loop runs pending V8 foreground tasks (and the microtasks FinalizationRegistry
  callbacks queue) outside of any request, like workerd does at the end of a request. Without a
  request there is no request LimitEnforcer, so it stops on the isolate's heap limit, on
  termination, or after 10000 tasks instead. It can run while requests of that isolate are
  suspended.
- A named Worker loader entry is unloaded only when no stub, request, entrypoint or actor class
  channel references it, and its Worker has no `ctx.waitUntil()` work or actor running.

## Releases

`.github/workflows/executor-release.yml` builds Linux x64 and arm64 release binaries on every push
to an `executor/**` branch, runs `.github/executor/smoke-test.sh` against them, and publishes a
GitHub release tagged `<upstream tag>-executor.<commit>` with gzipped binaries and `SHA256SUMS`.
Consumers pin those files by SHA-256, so a published release is never changed: a re-run only adds
files a failed attempt left out, and fails if the release has a different `SHA256SUMS`.

The release job first uploads the packaged files as the `release-files` artifact. Workflow tokens
in UsefulSoftwareCo default to read-only; two runs were refused release creation (HTTP 403) before
later runs succeeded with the same settings. If publishing is refused again, create the release
from that artifact with `gh release create`, or use the `from_run` input once publishing works.

The build uses standard GitHub-hosted runners and the Actions cache for Bazel's disk cache; there
is no remote cache. A cold build takes about two hours.
