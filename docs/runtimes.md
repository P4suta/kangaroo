# Supported runtimes and permissions

Kangaroo supports Gleam 1.18+ on Linux, macOS, and Windows with:

| Target | Supported runtime versions | Isolation |
| --- | --- | --- |
| Erlang | OTP 27, 28, 29 | one BEAM process per test |
| JavaScript | Node.js 22, 24, 26 | Worker per generation |
| JavaScript | Bun 1.4+ | Worker per generation |
| JavaScript | Deno 2.9+ | Worker per generation |

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

Coverage instruments a disposable clone and deletes only a workspace carrying
Kangaroo's validated temporary-directory marker. Original project source is
read-only during instrumentation.

## Runtime diagnosis

```sh
gleam run -m kangaroo -- doctor
```

Doctor reports the detected operating system, target, runtime and version,
discovery state, and exact coverage instrumentation capability. Its NDJSON form
is available with `--reporter ndjson`.
