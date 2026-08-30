# Supported runtimes and permissions

Kangaroo supports Gleam 1.18+ on Linux, macOS, and Windows with:

| Target | Supported runtime versions | Isolation |
| --- | --- | --- |
| Erlang | OTP 27, 28, 29 | one BEAM process per test |
| JavaScript | Node.js 22.12+, 24, 26 | Worker per test |
| JavaScript | Bun 1.4.0+ | Worker per test |
| JavaScript | Deno 2.9+ | Worker per test |

Use the normal Gleam runtime selector:

```sh
gleam test --target erlang
gleam test --target javascript --runtime nodejs
gleam test --target javascript --runtime bun
gleam test --target javascript --runtime deno
```

Watch and coverage preserve the target/runtime of their parent invocation.
Run `gleam run --target javascript --runtime bun -m kangaroo -- watch`, for
example, to keep Bun active in child generations.

Bun 1.4.0 can either drop a Node-compatible piped stdin write or return
`EPERM` while flushing a native `Bun.spawn` FileSink. Kangaroo owns that bridge
and writes the spawned pipe descriptor completely with bounded backpressure,
retaining bidirectional daemon/watch operation without raising the supported
minimum.

JavaScript tests may start asynchronous Node, Bun, or Deno child processes;
Kangaroo tracks and terminates their complete trees at completion, failure, or
timeout. Node synchronous subprocess calls are bounded and placed in an
isolated process group on Unix. Bun and Deno synchronous subprocess APIs, and
all synchronous subprocess APIs on Windows, fail before launch because those
runtimes cannot expose a live process tree to the test-timeout boundary. Use
the corresponding asynchronous API in portable test FFI.

On Windows, Kangaroo starts each compiler, test runtime, and daemon command
suspended, assigns it to a private kill-on-close Job Object, and only then
allows it to execute. Before completion is published, any descendants left by
the completed command are terminated through that Job Object. This ownership
boundary also applies when a command exits
successfully after starting background work, and to asynchronous subprocesses
started by an isolated JavaScript test. PowerShell compiles the immutable
console helper once, preferring the Windows PowerShell compiler host and falling
back to PowerShell 7. JavaScript runtimes execute it directly, while Erlang
opens native `cmd.exe` with AutoRun disabled and invokes the fixed helper
basename from its own cache directory around OTP's managed-executable boundary;
both paths preserve the raw redirected handles and child exit status. Erlang
derives the absolute per-user temporary cache path, passes it to the compiler
host as a literal `-OutputPath` argument, and validates that exact artifact
after exit zero. Helper preparation therefore never parses redirected
PowerShell output or depends on its locale-sensitive text encoding.
The command processor receives only the immutable helper basename and marker—never
a user executable, argument, environment value, or working directory.
Erlang transports Unicode environment overrides as private base64 metadata and
the helper restores them before launching user code, avoiding OTP port option
encoding differences. The helper's private environment
namespace is removed case-insensitively before user code starts, matching
Windows environment semantics and preventing inherited values from changing
or leaking its launch metadata.

## Deno permissions

Kangaroo discovers source files, writes build/coverage data, reads environment
configuration, and starts cancellable Gleam child processes. Deno therefore
needs the corresponding explicit capabilities. Add this to the consuming
package:

```toml
[javascript.deno]
allow_env = true
allow_read = true
allow_run = true
allow_sys = true
allow_write = true
```

These are broad Deno permissions. Grant them only to repositories whose test
code you trust; test functions themselves execute with the same authority.
Kangaroo does not require network permission at runtime, although Gleam may
need network access beforehand to download dependencies.

Coverage instruments a disposable clone and deletes only a real directory
carrying Kangaroo's validated, path-bound temporary-directory marker. Prefix
matches and symlinks are rejected. Original project source is read-only during
instrumentation.

## Runtime diagnosis

```sh
gleam run -m kangaroo -- doctor
```

Doctor reports the detected operating system, target, runtime and version,
discovery state, and exact coverage instrumentation capability. Its NDJSON form
is available with `--reporter ndjson`.
