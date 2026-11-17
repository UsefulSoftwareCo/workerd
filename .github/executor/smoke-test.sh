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
    if curl -sf "http://127.0.0.1:$2/?name=probe" > /dev/null; then return 0; fi
    sleep 0.1
  done
  cat "$DIR/$1.log"
  echo "workerd did not start" >&2
  exit 1
}

expect() {
  local got
  got="$(curl -sf "$1")" || { echo "FAIL: $1 failed (curl exit $?)" >&2; exit 1; }
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
    curl -sf -o /dev/null "http://127.0.0.1:$2/?name=a&mode=native"
    curl -sf -o /dev/null "http://127.0.0.1:$2/?name=a&mode=dropnative"
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

  # Memory pressure pacing. A 1 ms budget per 200 ms interval, and a full collection of each child
  # isolate (two with about 10 MB of live objects) taking longer than that, so a pass collects one
  # isolate per interval: a pass that collects k isolates spans at least k - 1 intervals. Usage stays
  # above the 1 MiB threshold, so the 500 ms cooldown doubles after every pass. Measured from the
  # first pass that collects at least three isolates (passes skip isolates that have not run since
  # their last collection, so how many a pass finds depends on when the children were made). The log
  # is timestamped (ms).
  write_config pace 18090 "memory = (maintenanceIntervalMs = 200, pressureThresholdMb = 1, pressureCooldownMs = 500, pressureGcBudgetMs = 1),"
  "$WORKERD" serve --experimental --verbose "$DIR/pace.capnp" 2>&1 \
    | while IFS= read -r line; do printf '%s %s\n' "$(date +%s%3N)" "$line"; done > "$DIR/pace.log" &
  for _ in $(seq 1 100); do curl -sf -o /dev/null "http://127.0.0.1:18090/?name=probe" && break; sleep 0.1; done
  for i in 1 2 3 4 5 6; do
    curl -sf -o /dev/null "http://127.0.0.1:18090/?name=p$i&mode=$([ $i -le 2 ] && echo fillsmall || echo count)"
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
  [ "$pass" -ge $(( (collected - 1) * 150 )) ] || { echo "FAIL: pace: $collected isolates in $pass ms, so the pass did not keep to its budget" >&2; exit 1; }
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

echo "smoke test passed"
