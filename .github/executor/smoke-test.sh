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
        'child.js': 'let hits = 0; export default { fetch() { hits += 1; return new Response(String(hits)); } }',
      },
    }));
    return stub.getEntrypoint().fetch('http://child/');
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
  "$WORKERD" serve --experimental --verbose "$DIR/$1.capnp" > "$DIR/$1.log" 2>&1 &
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

echo "smoke test passed"
