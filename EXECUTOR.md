# Executor build of workerd

This fork carries a few patches that Executor's self-hosted image needs on top of an upstream
workerd release. Branches are named `executor/<upstream tag>`; each one starts at that tag.

The memory patches only change behavior when enabled through `Config.memory` in `workerd.capnp`
(see `src/workerd/server/workerd.capnp`). `Config.memory` is field `@8`: upstream added
`Config.cluster` as `@7`, which the fork used before v1.20261117.1. Text configs name the field, so
they are unaffected; a binary config encoded for an older fork build is not. The inspector fix below is the one exception: it is always
on, and only changes a case that fails upstream. Otherwise, without `Config.memory`, the binary
behaves like upstream; the smoke test checks that the default config logs no memory maintenance.

| Commit | Setting | Problem it addresses |
| --- | --- | --- |
| Collect garbage in idle isolates, Pace memory pressure collections | `idleIsolateGcDelayMs`, `idleIsolateGcMode`, `idleTaskPumpMs`, `pressureThresholdMb`, `pressureCooldownMs`, `pressureGcBudgetMs` | V8's memory reducer runs from foreground tasks that workerd only pumps at the end of a request, so an idle isolate keeps its peak heap. |
| Return free TCMalloc memory to the OS | `tcmallocBackgroundReleaseBytesPerSecond`, `releaseMemoryAfterGc` | workerd never runs TCMalloc's background actions, so freed memory stays in TCMalloc's page heap. |
| Unload idle named Worker loader isolates, Keep Worker loader entries loaded while waitUntil work or actors run | `workerLoaderIdleTtlMs` | Named Worker loader isolates are kept until `abortIsolate()`, although the binding documents unloading unused Workers. |
| Allow reloading an unloaded Worker loader name with the inspector on | (always on) | With `--inspector-addr`, loading a name again after it was unloaded failed with "inserted row already exists in table". |
| Limit each slice of a Worker loader Worker's JavaScript | `Config.dynamicWorkerLimits.sliceCpuMs` | An optional CPU budget for continuous JavaScript execution in Workers created through a Worker loader. Config-defined Workers retain their existing behavior. |

### Where the patches live

Since upstream moved the server to Rust (`src/workerd/server/server/`, with the isolate-facing C++
in `src/workerd/server/factory/`), the patches are split along that boundary:

- `factory/memory-maintenance.{h,c++}`: the idle-isolate and memory-pressure collections and the
  TCMalloc release. The worker factory registers each isolate it creates with it, and
  `server/run.rs` starts it (`factory_start_memory_maintenance`) for `workerd serve`, before any
  isolate exists; `workerd test` and `workerd bench` run without it. The server stops it
  (`factory_stop_memory_maintenance`) first when it shuts down, before actors and workers go.
- `server/loader.rs` (`start_idle_eviction`, `WorkerLoaderNamespace::evict_idle`): idle Worker
  loader unloading, a server task that runs every `maintenanceIntervalMs`. A loaded Worker counts
  as used while its `Rc<WorkerStub>` has another owner, or while `worker_has_pending_work` reports
  a request, `ctx.waitUntil()` work or an actor.
- `factory/worker-factory-rpc.c++` (`InspectorService::registerIsolate`): the inspector fix.
  Inspector-enabled reload support is for development use. Keep the inspector disabled in
  production; Executor's image does not pass `--inspector-addr`.
- `factory/slice-limit.{h,c++}`: the slice limit. `createEntrypoint` wraps the request's
  `NullLimitEnforcer`, and `makeIsolate` the isolate's `NullIsolateLimitEnforcer`, for a Worker
  loader's Workers only (`CompiledWorker::Impl::isDynamic`); `server/worker.rs` unloads a
  Worker whose top level exceeded the limit (`WorkerInfo.startup_exceeded_cpu`).

### Notes on the slice limit

- A slice is one entry into JavaScript for a request or event (`IoContext::runImpl()`, with the
  microtasks it runs), one top-level module evaluation (`enterStartupJs()`) or one dynamic import
  (`enterDynamicImportJs()`). Awaiting I/O, timers or RPC is outside every slice. Python startup,
  inspector commands are not limited. Memory maintenance runs a loader Worker's isolate (its
  collection, and every task and microtask it pumps) under a slice of its own, and a SQL
  statement of a limited Worker ends with the limit (SQLite's progress handler). A breach outside
  a request fails the Worker's next request with the limit and unloads it. The CPU budget
  applies only at these execution boundaries; it is not a process-wide responsiveness
  guarantee.
- The limit is on the CPU time of the thread that runs the slice. One watchdog thread checks the
  slices in progress every tenth of the limit (1 ms to 100 ms) and terminates a slice's JavaScript
  with `v8::Isolate::TerminateExecution()` once it has used the limit.
- The request then fails with the JavaScript error "Worker exceeded CPU time limit." and the
  outcome `exceededCpu`, and the Worker's isolate is aborted (`abortIsolate()`), so a named
  Worker's next `load()` or `get()` starts a fresh isolate. Other requests in flight in that isolate
  carry on in it until they end. A breach at the top level fails the load, and the name is unloaded
  the same way.
- A single native call that does not check for termination (a large sort, `JSON.parse` or
  `structuredClone`) ends the slice only when it returns.
- Known limits, with or without the limit set: V8 running out of heap ends the process, and the
  resident set grows by about 8 KiB each time an ordinary Worker isolate is replaced. A retired
  Durable Object facet can hold much more, about 1.7 MiB, until a full collection runs.

### Notes on the memory patches

- Memory pressure collections block the event loop. A pass over the isolates spends at most
  `pressureGcBudgetMs` per maintenance interval, skips isolates that have not run since their last
  full collection, and backs off while passes leave usage above the threshold. Usage is the cgroup
  v2 working set (`memory.current` minus `inactive_file`), not `memory.current`, which also counts
  reclaimable page cache.
- The maintenance loop runs pending V8 foreground tasks (and the microtasks FinalizationRegistry
  callbacks queue) outside of any request, like workerd does at the end of a request. Without a
  request there is no request LimitEnforcer, so it stops on the isolate's heap limit, on
  termination, or after 10000 tasks instead; the count bounds how many tasks run, not how long
  one runs. With `Config.dynamicWorkerLimits` set, a Worker loader's Worker runs them under the
  CPU slice limit. It can run while requests of that isolate are suspended.
- A named Worker loader entry is unloaded only when no stub, request, entrypoint or actor class
  channel references it, and its Worker has no `ctx.waitUntil()` work or actor running.

## Releases

`.github/workflows/executor-release.yml` builds Linux x64 and arm64 release binaries on every push
to an `executor/**` branch, runs `.github/executor/smoke-test.sh` against them, and publishes a
GitHub release tagged `<upstream tag>-executor.<commit>` with gzipped binaries and `SHA256SUMS`.
Consumers pin those files by SHA-256, so a published file is never changed. When the release
already exists, a re-run checks each file it has against this build and fails if any differs; it
then uploads the files a failed attempt left out (`SHA256SUMS` last), and succeeds only once both
archives and `SHA256SUMS` are there. The build is not known to be reproducible bit for bit, so a
re-run that rebuilds may be refused; to complete a partial release, use `from_run` with the run
that published its first files.

The release job first uploads the packaged files as the `release-files` artifact. Workflow tokens
in UsefulSoftwareCo default to read-only; two runs were refused release creation (HTTP 403) before
later runs succeeded with the same settings. If publishing is refused again, create the release
from that artifact with `gh release create`, or use the `from_run` input once publishing works.

The build uses standard GitHub-hosted runners and the Actions cache for Bazel's disk cache; there
is no remote cache. A cold build takes about two hours.

### Other workflows

Every workflow in this repository other than `executor-release.yml` comes from upstream and is
disabled on purpose in the repository's Actions settings, since 17 November 2026. They are
upstream's own development workflows (tests, lint, daily releases, bots), and this fork uses only
the release workflow. Their files are left unchanged so that upstream updates apply cleanly. To
run one, enable it in the Actions tab or with
`gh workflow enable <file> --repo UsefulSoftwareCo/workerd`.

The workflows disabled that day: `_bazel.yml`, `_wpt.yml`, `bigbonk.yml`, `bonk.yml`, `cla.yml`,
`codspeed.yml`, `compat-flag-docs.yml`, `coverage.yml`, `daily-release.yml`, `deps-updater.yml`,
`experimental-workflow.yml`, `fixup.yml`, `internal-build.yml`, `issues.yml`, `labels.yml`,
`lint.yml`, `new-pr-review.yml`, `release-python-runtime.yml`, `release-python-snapshots.yml`,
`release.yml`, `semgrep.yml`, `test.yml`, `update-wpt.yml` and `wpt-report.yml`. Three of them
(`bigbonk.yml`, `bonk.yml`, `new-pr-review.yml`) are not in this branch; GitHub lists them from
other branches. A workflow that upstream adds later is not covered and may start enabled, so
check the Actions tab after moving to a new upstream version.

A push that changes only this file does not start a release build. On 17 November 2026 a manual
run was refused with "Actions has been disabled for this repository"; Actions had to be re-enabled
for the fork before runs started.
