#!/usr/bin/env bash
# Measures the end-to-end watch latency: how long between a file save and
# the start of the affected test run. Run from the CLI package directory
# (`cd cli`). Prints the latency in milliseconds.
set -euo pipefail

probe="test/bench_probe.gleam"

cleanup() {
  rm -f "$probe"
}
trap cleanup EXIT

# A probe module whose content length grows on every write, so the change
# is always visible to the metadata layer (mtime is second-granular on
# Erlang).
probe_body() {
  printf 'import kangaroo/suite.{it, suite}\n'
  printf 'pub fn suites() { [suite("bench", [it("probe", fn() { Nil })])] }\n'
  printf '// probe %s\n' "$(date +%s%N)"
}

mkdir -p "$(dirname "$probe")"
probe_body > "$probe"
"${KANGAROO_GLEAM:-gleam}" test -t erlang > /dev/null 2>&1

"${KANGAROO_GLEAM:-gleam}" run -m kangaroo_cli -- watch --no-tui \
  > /tmp/kangaroo_bench.log 2>&1 &
cli_pid=$!

# Wait for the initial run to finish (the log stops growing while the
# loop idles), then save a change and measure how long the watch takes
# to react.
stable=0
while [ "$stable" -lt 10 ]; do
  lines=$(wc -l < /tmp/kangaroo_bench.log)
  sleep 0.2
  if [ "$lines" -eq "$(wc -l < /tmp/kangaroo_bench.log)" ]; then
    stable=$((stable + 1))
  else
    stable=0
  fi
done

start=$(date +%s%3N)
probe_body > "$probe"

for _ in $(seq 1 600); do
  if grep -q "changed: test/bench_probe.gleam" /tmp/kangaroo_bench.log; then
    end=$(date +%s%3N)
    echo "watch latency: $((end - start)) ms"
    kill $cli_pid 2>/dev/null || true
    wait $cli_pid 2>/dev/null || true
    exit 0
  fi
  sleep 0.02
done
echo "timed out waiting for the change to be detected" >&2
kill $cli_pid 2>/dev/null || true
exit 1
