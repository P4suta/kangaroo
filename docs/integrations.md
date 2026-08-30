# Birdie and qcheck

Kangaroo executes Birdie snapshot tests and qcheck property tests as ordinary
public `*_test` functions. Their failures pass through the same capture and
source-location pipeline as other Gleam panics, so counterexamples and shrink
text written by the library are not replaced by generic runner messages.

## Birdie

Keep the Birdie dependency and snapshot assertions in the test body. A pending
snapshot makes that test fail and remains visible in pretty, NDJSON, and editor
output. Review pending snapshots with Birdie's own review entry point, then
rerun the affected stable ID:

```sh
gleam run -m birdie
gleam test -- 'test/snapshot_test.gleam::render_test'
```

The Neovim integration exposes `:KangarooBirdie`, which opens the Birdie review
in a terminal split. Snapshot files should be included in watch
`extra_paths` when edits to them must trigger a generation.

## qcheck

Write a public test that invokes qcheck and keep the property assertion in the
test body. Do not catch or stringify its failure before Kangaroo sees it;
otherwise the original assertion, counterexample, and shrink history cannot be
reported. Add a tag when property tests need a separate CI lane:

```gleam
pub fn round_trip_property_test() {
  kangaroo.tag("property")
  // invoke the qcheck property here
}
```

Then select it with `gleam test -- tag:property` or exclude it from the default
watch command with `--exclude-tag property`.
