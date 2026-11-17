#!/usr/bin/env bash
# Smoke test for the Executor workerd build. Runs the built binary against small configs and
# checks both the default behavior (must match upstream) and the Executor-specific knobs.
#
# Usage: smoke-test.sh /path/to/workerd
set -euo pipefail

WORKERD="$1"
DIR="$(mktemp -d)"
# The longest any one request may take. A missing limit, or a hung server, fails the check that
# made the request instead of holding the run.
REQUEST_TIMEOUT=${REQUEST_TIMEOUT:-30}
# SIGKILL: a server whose thread is held (a limit that does not work) would ignore SIGTERM and keep
# its port.
trap 'kill -9 $(jobs -p) 2>/dev/null || true; rm -rf "$DIR"' EXIT

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
        // mode=state reports how many of those finished in this isolate. mode=fill keeps about
        // 100 MB of JavaScript objects (fillsmall about 10 MB) and mode=native 200 MiB of
        // ArrayBuffer contents in 128 KiB buffers (native memory, from malloc) alive in a global; mode=drop and mode=dropnative
        // let go of them, leaving garbage that only a collection frees; mode=weak reports whether
        // the objects mode=drop let go of have been collected.
        'child.js': `let hits = 0; let bg = 0; let keep = null; let keepNative = null; let weak = null;
export default { fetch(request, env, ctx) {
  hits += 1;
  const mode = new URL(request.url).searchParams.get('mode');
  if (mode === 'fill' || mode === 'fillsmall') {
    keep = [];
    for (let i = 0, n = mode === 'fill' ? 1000000 : 100000; i < n; i++) keep.push({ i, s: 'item ' + i });
  }
  if (mode === 'drop') { weak = new WeakRef(keep); keep = null; }
  if (mode === 'weak') return new Response(weak === null ? 'none' : weak.deref() === undefined ? 'collected' : 'alive');
  if (mode === 'native') {
    keepNative = [];
    for (let i = 0; i < 1600; i++) keepNative.push(new Uint8Array(128 << 10).fill(1));
  }
  if (mode === 'dropnative') keepNative = null;
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
  WPID=$!
  for _ in $(seq 1 100); do
    if curl -sf -m 2 "http://127.0.0.1:$2/?name=probe" > /dev/null; then return 0; fi
    sleep 0.1
  done
  cat "$DIR/$1.log"
  echo "workerd did not start" >&2
  exit 1
}

expect() {
  local got
  got="$(curl -sf -m "$REQUEST_TIMEOUT" "$1")" || { echo "FAIL: $1 failed (curl exit $?)" >&2; exit 1; }
  if [ "$got" != "$2" ]; then
    echo "FAIL: $1 returned '$got', expected '$2'" >&2
    exit 1
  fi
  echo "ok: $1 -> $got"
}

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

# rss_mb: the resident set size of the workerd started last, in MiB.
rss_mb() {
  awk '/^VmRSS:/ { printf "%d", $2 / 1024 }' "/proc/$WPID/status"
}

# expect_rss_drop LABEL FROM_MB MIN_DROP_MB SECONDS: waits up to SECONDS for the resident set to
# fall at least MIN_DROP_MB below FROM_MB. Measures that memory actually went back to the OS.
expect_rss_drop() {
  local now
  for _ in $(seq 1 $(( $4 * 10 ))); do
    now=$(rss_mb)
    if [ $(( $2 - now )) -ge "$3" ]; then
      echo "ok: $1: resident set fell from $2 MiB to $now MiB"
      return 0
    fi
    sleep 0.1
  done
  echo "FAIL: $1: resident set is $now MiB, not $3 MiB below $2 MiB after $4 s" >&2
  exit 1
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

# Idle-isolate GC (moderate): after the isolates go idle they get collected, and they still
# serve requests afterwards with their state intact.
write_config idle 18082 "memory = (maintenanceIntervalMs = 100, idleIsolateGcDelayMs = 500, idleTaskPumpMs = 1000),"
start idle 18082
expect "http://127.0.0.1:18082/?name=a" 1
expect_log idle "executor: collected idle isolate.*moderate"
expect "http://127.0.0.1:18082/?name=a" 2
# No effect check for the moderate mode: measured on the original fork and on this one alike, the
# moderate notification and 30 s of task pumping leave 100 MB of dropped objects uncollected for
# at least 45 s, so there is no effect to tell apart from a build without it. The full mode below
# has one.

# Idle-isolate GC (full) alone, with no pressure collections or malloc release to free the memory
# instead: once the isolate has been idle, without another request, about 100 MB of objects a
# request let go of are collected and leave the resident set. Upstream workerd collects neither.
write_config idlefull 18093 "memory = (maintenanceIntervalMs = 100, idleIsolateGcDelayMs = 500, idleIsolateGcMode = full),"
start idlefull 18093
expect "http://127.0.0.1:18093/?name=a&mode=fill" 1
peak=$(rss_mb)
expect "http://127.0.0.1:18093/?name=a&mode=drop" 2
expect_rss_drop "idle collection" "$peak" 40 15
expect "http://127.0.0.1:18093/?name=a&mode=weak" collected

# Idle-isolate GC (full), the memory pressure path, and TCMalloc release. A 1 MiB threshold is
# always exceeded. TCMalloc is only used in Linux builds.
write_config full 18083 "memory = (maintenanceIntervalMs = 100, idleIsolateGcDelayMs = 500, idleIsolateGcMode = full, pressureThresholdMb = 1, pressureCooldownMs = 500, tcmallocBackgroundReleaseBytesPerSecond = 10485760, releaseMemoryAfterGc = true),"
start full 18083
expect "http://127.0.0.1:18083/?name=a" 1
expect_log full "executor: collected idle isolate.*full"
if [ "$(uname -s)" = "Linux" ]; then
  expect_log full "executor: memory usage above threshold"
  expect_log full "executor: memory pressure pass done; collected = [1-9]"
  # Once every isolate is idle and has had its full collection, later passes skip them all.
  expect_log full "executor: memory pressure pass done; collected = 0"
  expect_log full "executor: TCMalloc background release enabled"
  expect_log full "executor: released free malloc memory to the OS"
fi
expect "http://127.0.0.1:18083/?name=a" 2

if [ "$(uname -s)" = "Linux" ]; then
  # TCMalloc keeps freed memory. A full idle collection frees 200 MiB of ArrayBuffer contents; 10 s
  # later the resident set is measured with no release, with releaseMemoryAfterGc and with the
  # background release at 100 MiB/s. Each release must leave at least 12 MiB less than no release.
  # (Measured on this build and on the original fork: no release 178-186 MiB, a release 146-156 MiB,
  # and 179-187 MiB with the release calls removed.)
  native_after() { # NAME PORT MEMORY: the resident set 10 s after the collection, in MiB.
    write_config "$1" "$2" "memory = (maintenanceIntervalMs = 100, idleIsolateGcDelayMs = 500, idleIsolateGcMode = full$3),"
    start "$1" "$2"
    curl -sf -m "$REQUEST_TIMEOUT" -o /dev/null "http://127.0.0.1:$2/?name=a&mode=native"
    curl -sf -m "$REQUEST_TIMEOUT" -o /dev/null "http://127.0.0.1:$2/?name=a&mode=dropnative"
    sleep 10
    rss_mb
    # Started in this command substitution's subshell, so the script's exit trap would not stop it.
    kill "$WPID"; wait "$WPID" 2>/dev/null || true
  }
  kept=$(native_after norelease 18094 "")
  after_gc=$(native_after release 18091 ", releaseMemoryAfterGc = true")
  background=$(native_after bgrelease 18092 ", tcmallocBackgroundReleaseBytesPerSecond = 104857600")
  echo "native memory 10 s after the collection: no release $kept MiB, releaseMemoryAfterGc $after_gc MiB, background release $background MiB"
  [ $(( kept - after_gc )) -ge 12 ] || { echo "FAIL: releaseMemoryAfterGc left $after_gc MiB against $kept MiB without it" >&2; exit 1; }
  [ $(( kept - background )) -ge 12 ] || { echo "FAIL: the background release left $background MiB against $kept MiB without it" >&2; exit 1; }
  echo "ok: both releases return freed native memory to the OS"

  # Memory pressure pacing. A 1 ms budget per 200 ms interval, and a full collection of each of the
  # two child isolates with about 10 MB of live objects taking longer than that, so a pass that
  # collects them cannot finish within one interval: it spans at least one more. (Small isolates
  # can collect in under 1 ms, several in one interval, so the bound counts only the two large.) Usage stays
  # above the 1 MiB threshold, so the 500 ms cooldown doubles after every pass. Measured from the
  # first pass that collects at least three isolates (passes skip isolates that have not run since
  # their last collection, so how many a pass finds depends on when the children were made). The log
  # is timestamped (ms).
  write_config pace 18090 "memory = (maintenanceIntervalMs = 200, pressureThresholdMb = 1, pressureCooldownMs = 500, pressureGcBudgetMs = 1),"
  "$WORKERD" serve --experimental --verbose "$DIR/pace.capnp" 2>&1 \
    | while IFS= read -r line; do printf '%s %s\n' "$(date +%s%3N)" "$line"; done > "$DIR/pace.log" &
  for _ in $(seq 1 100); do curl -sf -m "$REQUEST_TIMEOUT" -o /dev/null "http://127.0.0.1:18090/?name=probe" && break; sleep 0.1; done
  for i in 1 2 3 4 5 6; do
    curl -sf -m "$REQUEST_TIMEOUT" -o /dev/null "http://127.0.0.1:18090/?name=p$i&mode=$([ $i -le 2 ] && echo fillsmall || echo count)"
  done
  pace_ready() { # prints "K COLLECTED" for the first pass K with at least 3 collected, once two more passes started
    local counts k
    counts=($(grep "executor: memory pressure pass done" "$DIR/pace.log" | sed -n 's/.*collected = \([0-9]*\).*/\1/p'))
    for k in "${!counts[@]}"; do
      if [ "${counts[$k]}" -ge 3 ]; then
        [ "$(grep -c "executor: memory usage above threshold" "$DIR/pace.log")" -ge $(( k + 3 )) ] && { echo "$k ${counts[$k]}"; return 0; }
        return 1
      fi
    done
    return 1
  }
  found=""
  for _ in $(seq 1 300); do found=$(pace_ready) && break; sleep 0.1; done
  if [ -z "$found" ]; then cat "$DIR/pace.log"; echo "FAIL: pace: no pass collected three isolates, or no two passes followed it" >&2; exit 1; fi
  read -r k collected <<< "$found"
  starts=($(grep "executor: memory usage above threshold" "$DIR/pace.log" | awk '{print $1}'))
  ends=($(grep "executor: memory pressure pass done" "$DIR/pace.log" | awk '{print $1}'))
  pass=$(( ends[k] - starts[k] )); gap1=$(( starts[k + 1] - ends[k] )); gap2=$(( starts[k + 2] - ends[k + 1] ))
  echo "pace: pass $k collected $collected isolates in ${pass} ms; the next passes waited ${gap1} ms and ${gap2} ms"
  [ "$pass" -ge 150 ] || { echo "FAIL: pace: $collected isolates in $pass ms, so the pass did not keep to its budget" >&2; exit 1; }
  [ "$gap1" -ge 750 ] || { echo "FAIL: pace: $gap1 ms before the next pass, under the cooldown" >&2; exit 1; }
  [ $(( gap2 * 2 )) -ge $(( gap1 * 3 )) ] || { echo "FAIL: pace: $gap2 ms after $gap1 ms, so the cooldown did not double" >&2; exit 1; }
  echo "ok: pressure passes keep to their budget and cooldown"
fi

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

# Pending ctx.waitUntil() work keeps a named Worker loaded past the TTL. The work takes 3 s, longer
# than the 2 s TTL, and runs to completion in the same isolate; the entry is unloaded only once the
# work has finished and the TTL has passed again.
write_config waituntil 18086 "memory = (maintenanceIntervalMs = 100, workerLoaderIdleTtlMs = 2000),"
start waituntil 18086
expect "http://127.0.0.1:18086/?name=a" 1
expect "http://127.0.0.1:18086/?name=a&mode=bg" 2
sleep 3
expect_log waituntil "child waitUntil done"
expect "http://127.0.0.1:18086/?name=a&mode=state" "3 bg=1"
sleep 3
expect_log waituntil "executor: unloaded idle Worker loader isolates"
expect "http://127.0.0.1:18086/?name=a" 1

# An actor keeps its Worker loader entry loaded past the TTL. A Durable Object of a config Worker
# runs a facet of the class "Counter" of loader Worker "act"; the facet and the Worker's default
# entrypoint share one module-level counter, so the default entrypoint's count shows whether the
# entry was unloaded (a fresh isolate counts from 1) while the facet lived.
cat > "$DIR/actor-parent.js" <<'JS'
import { DurableObject } from 'cloudflare:workers';
const CHILD = `import { DurableObject } from 'cloudflare:workers';
let hits = 0;
export class Counter extends DurableObject { fetch() { hits += 1; return new Response(String(hits)); } }
export default { fetch() { hits += 1; return new Response(String(hits)); } };`;
const code = () => ({ compatibilityDate: '2026-01-01', mainModule: 'child.js', modules: { 'child.js': CHILD } });
export class Host extends DurableObject {
  fetch() {
    const facet = this.ctx.facets.get('counter', () => ({
      class: this.env.LOADER.get('act', code).getDurableObjectClass('Counter'),
    }));
    return facet.fetch('http://facet/');
  }
}
export default {
  fetch(request, env) {
    const url = new URL(request.url);
    if (url.searchParams.get('name') === 'probe') return new Response('ok');
    if (url.searchParams.get('to') === 'facet') return env.HOST.get(env.HOST.idFromName('host')).fetch(request);
    return env.LOADER.get('act', code).getEntrypoint().fetch('http://act/');
  },
};
JS
mkdir -p "$DIR/actor-storage"
cat > "$DIR/actor.capnp" <<CAPNP
using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [
    (name = "parent", worker = (
      compatibilityDate = "2026-01-01",
      compatibilityFlags = ["experimental"],
      modules = [(name = "parent.js", esModule = embed "actor-parent.js")],
      bindings = [(name = "LOADER", workerLoader = ()),
                  (name = "HOST", durableObjectNamespace = "Host")],
      durableObjectNamespaces = [(className = "Host", uniqueKey = "host", enableSql = true)],
      durableObjectStorage = (localDisk = "storage"),
    )),
    (name = "storage", disk = (path = "$DIR/actor-storage", writable = true)),
  ],
  sockets = [(name = "http", address = "127.0.0.1:18089", http = (), service = "parent")],
  memory = (maintenanceIntervalMs = 100, workerLoaderIdleTtlMs = 500),
);
CAPNP
start actor 18089
expect "http://127.0.0.1:18089/?to=facet" 1
sleep 2
expect "http://127.0.0.1:18089/?to=default" 2
expect "http://127.0.0.1:18089/?to=facet" 3

# The same with the inspector enabled: loading a name again after it was unloaded must work.
write_config inspector 18085 "memory = (maintenanceIntervalMs = 100, workerLoaderIdleTtlMs = 500),"
INSPECTOR=19229 start inspector 18085
expect "http://127.0.0.1:18085/?name=a" 1
sleep 1.5
expect_log inspector "executor: unloaded idle Worker loader isolates"
expect "http://127.0.0.1:18085/?name=a" 1

# Slice limit (Config.dynamicWorkerLimits): a separate parent whose loader children loop in
# JavaScript, in WebAssembly or at their top level. limit-parent.js answers
#   /health                       directly (a config Worker, never limited)
#   /static-busy?n=N              after N loop iterations of its own (never limited)
#   /?name=X&mode=M               by calling child X (modes: count, loop, wasm, busy&n=N, wait&ms=N)
# with "<status> <elapsed ms> <body or error>". Date.now() does not advance while JavaScript runs,
# so busy work is counted in loop iterations, calibrated below against wall time. The code for a
# name changes from the second time the loader asks for it, so a fresh isolate is visible: "top"
# loops at its top level only in its first isolate, and every child's counter restarts at 1.
cat > "$DIR/limit-parent.js" <<'JS'
import spinBytes from './spin.bin';
const loads = {};
const child = (name, first) => `import spin from './spin.wasm';
let hits = 0;
${first ? ({
  top: 'for (;;) {}',
  topmicro: 'Promise.resolve().then(() => { for (;;) {} });',
  topchain: 'const chain = () => Promise.resolve().then(chain); chain();',
})[name] ?? '' : ''}
export default { async fetch(request) {
  hits += 1;
  const url = new URL(request.url);
  const mode = url.searchParams.get('mode');
  if (mode === 'loop') { for (;;) {} }
  if (mode === 'wasm') { new WebAssembly.Instance(spin).exports.spin(); }
  if (mode === 'busy') { let x = 0; for (let i = 0, n = Number(url.searchParams.get('n')); i < n; i++) x += i; if (x < 0) hits = 0; }
  if (mode === 'wait') { await new Promise((resolve) => setTimeout(resolve, Number(url.searchParams.get('ms')))); }
  if (mode === 'import') { await import('./heavy.js'); }
  if (mode === 'finalizer') {
    const registry = new FinalizationRegistry(() => { for (;;) {} });
    for (let i = 0; i < 1000; i++) registry.register({ junk: new Array(100).fill(i) }, i);
    globalThis.keepRegistry = registry;
    return new Response('armed');
  }
  return new Response(String(hits));
} }`;
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health') return new Response('ok');
    if (url.pathname === '/static-busy') {
      let x = 0;
      for (let i = 0, n = Number(url.searchParams.get('n')); i < n; i++) x += i;
      return new Response(x < 0 ? 'impossible' : 'static ok');
    }
    const name = url.searchParams.get('name') ?? 'child';
    const stub = env.LOADER.get(name, () => {
      loads[name] = (loads[name] ?? 0) + 1;
      return {
        // registry=new: the new module registry, which a later compatibility date turns on.
        compatibilityDate: url.searchParams.get('registry') === 'new' ? '2026-11-17' : '2026-01-01',
        mainModule: 'child.js',
        modules: {
          'child.js': child(name, loads[name] === 1),
          'spin.wasm': { wasm: spinBytes },
          'heavy.js': 'for (;;) {}\nexport const done = true;',
        },
      };
    });
    const start = Date.now();
    try {
      const response = await stub.getEntrypoint().fetch('http://child/' + url.search);
      return new Response(`${response.status} ${Date.now() - start} ${await response.text()}`);
    } catch (e) {
      return new Response(`error ${Date.now() - start} ${String(e)}`);
    }
  },
};
JS
# (module (func (export "spin") (loop br 0)))
printf '\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x04\x01\x60\x00\x00\x03\x02\x01\x00\x07\x08\x01\x04\x73\x70\x69\x6e\x00\x00\x0a\x09\x01\x07\x00\x03\x40\x0c\x00\x0b\x0b' > "$DIR/spin.wasm"

# write_limit_config NAME PORT EXTRA_CONFIG
write_limit_config() {
  cat > "$DIR/$1.capnp" <<CAPNP
using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [
    (name = "parent", worker = (
      compatibilityDate = "2026-01-01",
      modules = [(name = "parent.js", esModule = embed "limit-parent.js"),
                 (name = "spin.bin", data = embed "spin.wasm")],
      bindings = [(name = "LOADER", workerLoader = ())],
    )),
  ],
  sockets = [(name = "http", address = "127.0.0.1:$2", http = (), service = "parent")],
  $3
);
CAPNP
}

# expect_match URL REGEX: the response, on one line, must match REGEX (grep -E).
expect_match() {
  local got
  got="$(curl -sf -m "$REQUEST_TIMEOUT" "$1" | tr '\n' ' ')" \
    || { echo "FAIL: $1 failed (curl exit ${PIPESTATUS[0]:-?}): no answer within ${REQUEST_TIMEOUT} s, or none at all" >&2; exit 1; }
  if ! printf '%s' "$got" | grep -qE "$2"; then
    echo "FAIL: $1 returned '$got', expected /$2/" >&2
    exit 1
  fi
  echo "ok: $1 -> $got"
}

# expect_ms_between URL MIN MAX REGEX: the response matches REGEX and its elapsed field (the
# second word) is within [MIN, MAX] ms.
expect_ms_between() {
  local got ms
  got="$(curl -sf -m "$REQUEST_TIMEOUT" "$1" | tr '\n' ' ')" \
    || { echo "FAIL: $1 failed (curl exit ${PIPESTATUS[0]:-?}): no answer within ${REQUEST_TIMEOUT} s, or none at all" >&2; exit 1; }
  ms="$(printf '%s' "$got" | awk '{print $2}')"
  if ! printf '%s' "$got" | grep -qE "$4" || [ "$ms" -lt "$2" ] || [ "$ms" -gt "$3" ]; then
    echo "FAIL: $1 returned '$got', expected /$4/ in $2..$3 ms" >&2
    exit 1
  fi
  echo "ok: $1 -> $got"
}

# wall_ms URL: the wall time of a request, in ms.
wall_ms() {
  local t
  t="$(curl -sf -m "$REQUEST_TIMEOUT" -o /dev/null -w '%{time_total}' "$1")" \
    || { echo "FAIL: $1 failed (curl exit $?): no answer within ${REQUEST_TIMEOUT} s, or none at all" >&2; exit 1; }
  printf '%s' "$t" | awk '{printf "%d", $1 * 1000}'
}

CPU_ERROR='^error [0-9]+ .*exceeded CPU time limit'
# Default config: no limit. Calibrate busy work against the static parent, then let a child and
# the static parent each spin for about a second.
L=18087
write_limit_config nolimit $L ""
start nolimit $L
n=50000000
while [ "$(wall_ms "http://127.0.0.1:$L/static-busy?n=$n")" -lt 200 ]; do n=$(( n * 2 )); done
per_ms=$(( n / $(wall_ms "http://127.0.0.1:$L/static-busy?n=$n") ))
[ "$per_ms" -gt 0 ] || { echo "FAIL: could not calibrate busy work" >&2; exit 1; }
echo "ok: busy work runs about $per_ms iterations per ms"
expect_match "http://127.0.0.1:$L/?name=a&mode=busy&n=$(( per_ms * 1000 ))" '^200 [0-9]+ 1$'
expect_match "http://127.0.0.1:$L/static-busy?n=$(( per_ms * 1000 ))" '^static ok$'
if grep -q "exceeded its CPU slice limit" "$DIR/nolimit.log"; then
  cat "$DIR/nolimit.log"; echo "FAIL: default config limited a Worker" >&2; exit 1
fi
echo "ok: default config limited nothing"

# A 500 ms limit.
L=18088
write_limit_config limit $L "dynamicWorkerLimits = (sliceCpuMs = 500),"
start limit $L
expect_match "http://127.0.0.1:$L/?name=a" '^200 [0-9]+ 1$'
expect_match "http://127.0.0.1:$L/?name=b" '^200 [0-9]+ 1$'
# A JavaScript loop ends at about the limit while the config Worker waits for the thread; the
# failed name's next call starts a fresh isolate, and the other loader Worker keeps its state.
curl -sf -m "$REQUEST_TIMEOUT" "http://127.0.0.1:$L/?name=a&mode=loop" > "$DIR/loop.out" &
loop=$!
sleep 0.1
health_ms=$(wall_ms "http://127.0.0.1:$L/health")
wait $loop || { echo "FAIL: the looping call got no answer within ${REQUEST_TIMEOUT} s (curl exit $?)" >&2; exit 1; }
got="$(cat "$DIR/loop.out")"
printf '%s' "$got" | grep -qE "$CPU_ERROR" || { echo "FAIL: loop returned '$got'" >&2; exit 1; }
loop_ms="$(printf '%s' "$got" | awk '{print $2}')"
[ "$loop_ms" -ge 450 ] && [ "$loop_ms" -le 1500 ] || { echo "FAIL: loop ended after $loop_ms ms" >&2; exit 1; }
[ "$health_ms" -le 1500 ] || { echo "FAIL: /health waited $health_ms ms during the loop" >&2; exit 1; }
echo "ok: loop -> $got; /health answered after $health_ms ms during it"
expect_log limit "executor: Worker loader Worker exceeded its CPU slice limit"
expect_match "http://127.0.0.1:$L/?name=a" '^200 [0-9]+ 1$'
expect_match "http://127.0.0.1:$L/?name=b" '^200 [0-9]+ 2$'
expect_match "http://127.0.0.1:$L/health" '^ok$'
# A WebAssembly loop ends the same way.
expect_ms_between "http://127.0.0.1:$L/?name=w&mode=wasm" 450 1500 "$CPU_ERROR"
expect_match "http://127.0.0.1:$L/?name=w" '^200 [0-9]+ 1$'
# A dynamic import of a module whose top level does not finish ends the same way with either module
# registry, and the name's next call starts a fresh isolate.
expect_ms_between "http://127.0.0.1:$L/?name=imp&mode=import" 450 1500 "$CPU_ERROR"
expect_match "http://127.0.0.1:$L/?name=imp" '^200 [0-9]+ 1$'
expect_ms_between "http://127.0.0.1:$L/?name=imp&mode=import" 450 1500 "$CPU_ERROR"
expect_match "http://127.0.0.1:$L/?name=imp" '^200 [0-9]+ 1$'
expect_ms_between "http://127.0.0.1:$L/?name=impnew&mode=import&registry=new" 450 1500 "$CPU_ERROR"
expect_match "http://127.0.0.1:$L/?name=impnew&registry=new" '^200 [0-9]+ 1$'
# A loop at the top level fails the load; the name's next load compiles afresh.
expect_ms_between "http://127.0.0.1:$L/?name=top" 450 1500 "$CPU_ERROR"
expect_match "http://127.0.0.1:$L/?name=top" '^200 [0-9]+ 1$'
# The same when the top level queues the work in a microtask, or as a promise chain that never
# ends: the load fails with the limit, and is not taken for a started Worker.
expect_ms_between "http://127.0.0.1:$L/?name=topmicro" 450 1500 "$CPU_ERROR"
expect_match "http://127.0.0.1:$L/?name=topmicro" '^200 [0-9]+ 1$'
expect_ms_between "http://127.0.0.1:$L/?name=topchain" 450 1500 "$CPU_ERROR"
expect_match "http://127.0.0.1:$L/?name=topchain" '^200 [0-9]+ 1$'
# Under the limit, waiting longer than it, and the config Worker: never limited.
expect_match "http://127.0.0.1:$L/?name=c&mode=busy&n=$(( per_ms * 150 ))" '^200 [0-9]+ 1$'
expect_ms_between "http://127.0.0.1:$L/?name=c&mode=wait&ms=2000" 1900 4000 '^200 [0-9]+ 2$'
expect_match "http://127.0.0.1:$L/static-busy?n=$(( per_ms * 1500 ))" '^static ok$'
if grep -q "exceeded its CPU slice limit.*\"parent\"" "$DIR/limit.log"; then
  cat "$DIR/limit.log"; echo "FAIL: the config Worker was limited" >&2; exit 1
fi

# Memory maintenance runs a loader Worker's pending tasks under the limit too. Its finalizer never
# returns; the idle collection runs it, the limit ends it, and the server keeps answering. The
# Worker's next request fails with the limit and unloads it, and the one after starts afresh.
L=18095
write_limit_config limitmaint $L "dynamicWorkerLimits = (sliceCpuMs = 500), memory = (maintenanceIntervalMs = 100, idleIsolateGcDelayMs = 500, idleIsolateGcMode = full, idleTaskPumpMs = 3000),"
start limitmaint $L
expect_match "http://127.0.0.1:$L/?name=fin&mode=finalizer" '^200 [0-9]+ armed$'
expect_log limitmaint "executor: collected idle isolate; entry->name = LOADER:fin"
expect_log limitmaint "executor: Worker loader Worker exceeded its CPU slice limit outside a request"
expect_match "http://127.0.0.1:$L/health" '^ok$'
expect_match "http://127.0.0.1:$L/?name=fin" "$CPU_ERROR"
expect_match "http://127.0.0.1:$L/?name=fin" '^200 [0-9]+ 1$'

# A SQL statement of a loader Worker's facet ends with the limit, its transaction rolled back, and
# the facet's next call reads the data as it was. The same statement of a config Worker's Durable
# Object is not limited.
cat > "$DIR/sql-parent.js" <<'JS'
import { DurableObject } from 'cloudflare:workers';
const STORE = `import { DurableObject } from 'cloudflare:workers';
export class Store extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS t (v TEXT)');
  }
  fetch(request) {
    const sql = this.ctx.storage.sql;
    const mode = new URL(request.url).searchParams.get('mode');
    if (mode === 'put') sql.exec("INSERT INTO t VALUES ('kept')");
    if (mode === 'count') sql.exec('WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT max(x) FROM c').one();
    if (mode === 'txcount') this.ctx.storage.transactionSync(() => {
      sql.exec("INSERT INTO t VALUES ('never')");
      sql.exec('WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT max(x) FROM c').one();
    });
    return new Response(sql.exec('SELECT v FROM t').toArray().map((row) => row.v).join(','));
  }
}
export default { fetch() { return new Response('store'); } };`;
const code = () => ({ compatibilityDate: '2026-01-01', mainModule: 'store.js', modules: { 'store.js': STORE } });
export class Host extends DurableObject {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.searchParams.get('own') === '1') {
      this.ctx.storage.sql.exec('WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < ' + url.searchParams.get('n') + ') SELECT max(x) FROM c').one();
      return new Response('own ok');
    }
    const facet = this.ctx.facets.get('store', () => ({
      class: this.env.LOADER.get('store', code).getDurableObjectClass('Store'),
    }));
    return facet.fetch(request);
  }
}
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health') return new Response('ok');
    if (url.searchParams.get('name') === 'probe') return new Response('ok');
    const start = Date.now();
    try {
      const response = await env.HOST.get(env.HOST.idFromName('host')).fetch(request);
      return new Response(`${response.status} ${Date.now() - start} ${await response.text()}`);
    } catch (e) {
      return new Response(`error ${Date.now() - start} ${String(e)}`);
    }
  },
};
JS
mkdir -p "$DIR/sql-storage"
cat > "$DIR/limitsql.capnp" <<CAPNP
using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [
    (name = "parent", worker = (
      compatibilityDate = "2026-01-01",
      compatibilityFlags = ["experimental"],
      modules = [(name = "parent.js", esModule = embed "sql-parent.js")],
      bindings = [(name = "LOADER", workerLoader = ()),
                  (name = "HOST", durableObjectNamespace = "Host")],
      durableObjectNamespaces = [(className = "Host", uniqueKey = "host", enableSql = true)],
      durableObjectStorage = (localDisk = "storage"),
    )),
    (name = "storage", disk = (path = "$DIR/sql-storage", writable = true)),
  ],
  sockets = [(name = "http", address = "127.0.0.1:18096", http = (), service = "parent")],
  dynamicWorkerLimits = (sliceCpuMs = 500),
);
CAPNP
L=18096
start limitsql $L
expect_match "http://127.0.0.1:$L/?mode=put" '^200 [0-9]+ kept$'
curl -sf -m "$REQUEST_TIMEOUT" "http://127.0.0.1:$L/?mode=count" > "$DIR/sqlcount.out" &
sqlcount=$!
sleep 0.2
health_ms=$(wall_ms "http://127.0.0.1:$L/health")
wait $sqlcount || { echo "FAIL: the SQL statement's call got no answer within ${REQUEST_TIMEOUT} s (curl exit $?)" >&2; exit 1; }
got="$(tr '\n' ' ' < "$DIR/sqlcount.out")"
printf '%s' "$got" | grep -qE "$CPU_ERROR" || { echo "FAIL: a SQL statement without an end returned '$got'" >&2; exit 1; }
sql_ms="$(printf '%s' "$got" | awk '{print $2}')"
[ "$sql_ms" -ge 450 ] && [ "$sql_ms" -le 3000 ] || { echo "FAIL: the SQL statement ended after $sql_ms ms" >&2; exit 1; }
[ "$health_ms" -le 3000 ] || { echo "FAIL: /health waited $health_ms ms during the SQL statement" >&2; exit 1; }
echo "ok: SQL statement -> $got; /health answered after $health_ms ms during it"
expect_match "http://127.0.0.1:$L/" '^200 [0-9]+ kept$'
expect_ms_between "http://127.0.0.1:$L/?mode=txcount" 450 3000 "$CPU_ERROR"
expect_match "http://127.0.0.1:$L/" '^200 [0-9]+ kept$'
expect_match "http://127.0.0.1:$L/?mode=put" '^200 [0-9]+ kept,kept$'
# The config Worker's own Durable Object runs a statement longer than the limit; it is not limited.
expect_ms_between "http://127.0.0.1:$L/?own=1&n=20000000" 500 25000 '^200 [0-9]+ own ok$'

echo "smoke test passed"
