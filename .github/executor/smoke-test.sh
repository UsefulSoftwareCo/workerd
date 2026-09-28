#!/usr/bin/env bash
# Smoke test for the Executor workerd build. Runs the built binary against small configs and
# checks both the default behavior (must match upstream) and the Executor-specific knobs.
#
# Usage: smoke-test.sh /path/to/workerd
set -euo pipefail

WORKERD="$1"
DIR="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$DIR"' EXIT

cat > "$DIR/parent.js" <<'JS'
// Loads a named child Worker through the Worker loader. The child keeps a module-level counter,
// so the response shows whether the same isolate was reused (count increases) or recreated
// (count restarts at 1).
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const name = url.searchParams.get('name') ?? 'child';
    const stub = env.LOADER.get(name, () => ({
      compatibilityDate: '2026-01-01',
      mainModule: 'child.js',
      modules: {
        // mode=bg schedules ctx.waitUntil() work that finishes 3 s after the response;
        // mode=state reports how many of those finished in this isolate.
        'child.js': `let hits = 0; let bg = 0;
export default { fetch(request, env, ctx) {
  hits += 1;
  const mode = new URL(request.url).searchParams.get('mode');
  if (mode === 'bg') {
    ctx.waitUntil(new Promise((resolve) => setTimeout(resolve, 3000)).then(() => {
      bg += 1;
      console.log('child waitUntil done');
    }));
  }
  return new Response(mode === 'state' ? hits + ' bg=' + bg : String(hits));
} }`,
      },
    }));
    return stub.getEntrypoint().fetch('http://child/' + url.search);
  },
};
JS

# write_config NAME PORT EXTRA_CONFIG
write_config() {
  cat > "$DIR/$1.capnp" <<CAPNP
using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [
    (name = "parent", worker = (
      compatibilityDate = "2026-01-01",
      modules = [(name = "parent.js", esModule = embed "parent.js")],
      bindings = [(name = "LOADER", workerLoader = ())],
    )),
  ],
  sockets = [(name = "http", address = "127.0.0.1:$2", http = (), service = "parent")],
  $3
);
CAPNP
}

# start NAME PORT: starts workerd in the background and waits for it to listen.
start() {
  "$WORKERD" serve --experimental --verbose ${INSPECTOR:+--inspector-addr=127.0.0.1:$INSPECTOR} "$DIR/$1.capnp" > "$DIR/$1.log" 2>&1 &
  for _ in $(seq 1 100); do
    if curl -sf "http://127.0.0.1:$2/?name=probe" > /dev/null; then return 0; fi
    sleep 0.1
  done
  cat "$DIR/$1.log"
  echo "workerd did not start" >&2
  exit 1
}

expect() {
  local got
  got="$(curl -sf "$1")"
  if [ "$got" != "$2" ]; then
    echo "FAIL: $1 returned '$got', expected '$2'" >&2
    exit 1
  fi
  echo "ok: $1 -> $got"
}

# Default config: named loader entries live until the process exits (upstream behavior).
write_config default 18081 ""
start default 18081
expect "http://127.0.0.1:18081/?name=a" 1
expect "http://127.0.0.1:18081/?name=a" 2
sleep 3
expect "http://127.0.0.1:18081/?name=a" 3
# Without a memory config none of the Executor maintenance runs.
if grep -q "executor:" "$DIR/default.log"; then
  cat "$DIR/default.log"
  echo "FAIL: default config logged Executor memory maintenance" >&2
  exit 1
fi
echo "ok: default config ran no Executor memory maintenance"

# expect_log NAME PATTERN: waits up to 10s for PATTERN in the workerd log.
expect_log() {
  for _ in $(seq 1 100); do
    if grep -q "$2" "$DIR/$1.log"; then echo "ok: $1 log has '$2'"; return 0; fi
    sleep 0.1
  done
  cat "$DIR/$1.log"
  echo "FAIL: $1 log is missing '$2'" >&2
  exit 1
}

# Idle-isolate GC (moderate): after the isolates go idle they get collected, and they still
# serve requests afterwards with their state intact.
write_config idle 18082 "memory = (maintenanceIntervalMs = 100, idleIsolateGcDelayMs = 500, idleTaskPumpMs = 1000),"
start idle 18082
expect "http://127.0.0.1:18082/?name=a" 1
expect_log idle "executor: collected idle isolate.*moderate"
expect "http://127.0.0.1:18082/?name=a" 2

# Idle-isolate GC (full), the memory pressure path, and TCMalloc release. A 1 MiB threshold is
# always exceeded. TCMalloc is only used in Linux builds.
write_config full 18083 "memory = (maintenanceIntervalMs = 100, idleIsolateGcDelayMs = 500, idleIsolateGcMode = full, pressureThresholdMb = 1, pressureCooldownMs = 500, tcmallocBackgroundReleaseBytesPerSecond = 10485760, releaseMemoryAfterGc = true),"
start full 18083
expect "http://127.0.0.1:18083/?name=a" 1
expect_log full "executor: collected idle isolate.*full"
if [ "$(uname -s)" = "Linux" ]; then
  expect_log full "executor: memory usage above threshold"
  expect_log full "executor: TCMalloc background release enabled"
  expect_log full "executor: released free malloc memory to the OS"
fi
expect "http://127.0.0.1:18083/?name=a" 2

# Worker loader idle eviction: once nothing references a named Worker for the TTL, the next
# get() starts a fresh isolate, so the child's counter restarts.
write_config loader 18084 "memory = (maintenanceIntervalMs = 100, workerLoaderIdleTtlMs = 500),"
start loader 18084
expect "http://127.0.0.1:18084/?name=a" 1
expect "http://127.0.0.1:18084/?name=a" 2
sleep 1.5
expect_log loader "executor: unloaded idle Worker loader isolates"
expect "http://127.0.0.1:18084/?name=a" 1
expect "http://127.0.0.1:18084/?name=a" 2

# Pending ctx.waitUntil() work keeps a named Worker loaded past the TTL. It runs to completion in
# the same isolate, and the entry is unloaded only once it finished and the TTL passed again.
write_config waituntil 18086 "memory = (maintenanceIntervalMs = 100, workerLoaderIdleTtlMs = 500),"
start waituntil 18086
expect "http://127.0.0.1:18086/?name=a" 1
expect "http://127.0.0.1:18086/?name=a&mode=bg" 2
sleep 4
expect_log waituntil "child waitUntil done"
expect "http://127.0.0.1:18086/?name=a&mode=state" "3 bg=1"
sleep 1.5
expect_log waituntil "executor: unloaded idle Worker loader isolates"
expect "http://127.0.0.1:18086/?name=a" 1

# The same with the inspector enabled: loading a name again after it was unloaded must work.
write_config inspector 18085 "memory = (maintenanceIntervalMs = 100, workerLoaderIdleTtlMs = 500),"
INSPECTOR=19229 start inspector 18085
expect "http://127.0.0.1:18085/?name=a" 1
sleep 1.5
expect_log inspector "executor: unloaded idle Worker loader isolates"
expect "http://127.0.0.1:18085/?name=a" 1

echo "smoke test passed"
