# Migrating from gleeunit or unitest

Most generated Gleam tests already have the shape Kangaroo discovers. The
migration changes the entry point and keeps ordinary public `*_test` functions
and built-in assertions.

## 1. Change the dependency

Add Kangaroo as a development dependency and remove the old runner when no
other test module imports it:

```sh
gleam add --dev kangaroo
gleam remove gleeunit
```

For unitest, remove `unitest` instead.

## 2. Change the test entry point

```gleam
import kangaroo

pub fn main() {
  kangaroo.main()
}
```

`gleam run -m kangaroo -- init` performs this replacement only when the
existing file is the exact generated gleeunit/unitest main. It never overwrites
a custom test entry point; it prints the suggested contents and exits 2 when
manual integration is required.

## 3. Keep or simplify tests

This test needs no change:

```gleam
pub fn addition_test() {
  assert 20 + 22 == 42
}
```

Prefer `assert` for conditions and equality, and `let assert` for destructuring:

```gleam
pub fn decoder_test() {
  let assert Ok(value) = decode("42")
  assert value == 42
}
```

Kangaroo restores the expression, values, useful text/list diff, snippet, and
source location from structured Gleam failures. A custom assertion DSL is not
required.

## 4. Add metadata only where needed

```gleam
pub fn database_test() {
  kangaroo.tag("database")
  kangaroo.timeout(10_000)
  kangaroo.serial()
  // test body
}
```

Literal metadata is indexed without executing the test. Use `fixture` for
guaranteed teardown and `skip_if` for runtime-only conditions.

## 5. Update commands

```sh
gleam test
gleam run -m kangaroo -- watch
gleam run -m kangaroo -- coverage
```

Remove scripts that invoke a separate runner package. Move all settings into
`[tools.kangaroo]` in `gleam.toml`; see the root README for the complete table.

An empty selection is an exit-2 configuration/infrastructure result, which
helps catch misspelled CI selectors instead of silently succeeding.
