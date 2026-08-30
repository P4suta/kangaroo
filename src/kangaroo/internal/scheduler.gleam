import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{Eq}
import gleam/string
import kangaroo/internal/index.{type IndexedTest}

pub type Batch {
  Batch(module: String, path: String, tests: List(IndexedTest), serial: Bool)
}

pub type Wave {
  Wave(batches: List(Batch))
}

/// Produces deterministic execution waves from tests already ordered by the
/// source index. A batch is one module, so its functions are always serial.
pub fn plan(
  tests: List(IndexedTest),
  workers: Int,
  serial_tags: List(String),
) -> List(Wave) {
  plan_seeded(tests, workers, serial_tags, None)
}

/// Plans execution with an optional reproducible seed. Shuffling happens at
/// the module-batch boundary, preserving source definition order within each
/// module as required by the execution contract.
pub fn plan_seeded(
  tests: List(IndexedTest),
  workers: Int,
  serial_tags: List(String),
  seed: Option(Int),
) -> List(Wave) {
  let workers = case workers > 0 {
    True -> workers
    False -> 1
  }
  let batches = group_modules(tests, serial_tags)
  let batches = case seed {
    None -> batches
    Some(seed) ->
      list.sort(batches, fn(left, right) {
        let left_key =
          index.source_hash(int.to_string(seed) <> ":" <> left.path)
        let right_key =
          index.source_hash(int.to_string(seed) <> ":" <> right.path)
        case string.compare(left_key, right_key) {
          Eq -> string.compare(left.path, right.path)
          order -> order
        }
      })
  }
  let #(waves, pending) =
    list.fold(batches, #([], []), fn(state, batch) {
      let #(waves, pending) = state
      case batch.serial {
        True -> #(waves |> flush(pending) |> list.append([Wave([batch])]), [])
        False ->
          case list.length(pending) >= workers {
            True -> #(flush(waves, pending), [batch])
            False -> #(waves, list.append(pending, [batch]))
          }
      }
    })
  flush(waves, pending)
}

fn group_modules(
  tests: List(IndexedTest),
  serial_tags: List(String),
) -> List(Batch) {
  list.fold(tests, [], fn(batches, indexed) {
    append_to_batch(batches, indexed, serial_tags)
  })
}

fn append_to_batch(
  batches: List(Batch),
  indexed: IndexedTest,
  serial_tags: List(String),
) -> List(Batch) {
  case batches {
    [] -> [new_batch(indexed, serial_tags)]
    [batch, ..rest] if batch.module == indexed.module -> [
      Batch(
        ..batch,
        tests: list.append(batch.tests, [indexed]),
        serial: batch.serial || is_serial(indexed, serial_tags),
      ),
      ..rest
    ]
    [batch, ..rest] -> [batch, ..append_to_batch(rest, indexed, serial_tags)]
  }
}

fn new_batch(indexed: IndexedTest, serial_tags: List(String)) -> Batch {
  Batch(
    module: indexed.module,
    path: indexed.path,
    tests: [indexed],
    serial: is_serial(indexed, serial_tags),
  )
}

fn is_serial(indexed: IndexedTest, serial_tags: List(String)) -> Bool {
  indexed.serial
  || list.any(serial_tags, fn(tag) { list.contains(indexed.tags, tag) })
}

fn flush(waves: List(Wave), pending: List(Batch)) -> List(Wave) {
  case pending {
    [] -> waves
    _ -> list.append(waves, [Wave(pending)])
  }
}
