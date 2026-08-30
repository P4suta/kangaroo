import gleam/int
import gleam/list

/// Returns the 95th percentile using the nearest-rank definition.
///
/// The method is deterministic for small benchmark sample sets and does not
/// interpolate values that were never observed.
pub fn p95(samples: List(Int)) -> Result(Int, String) {
  case samples {
    [] -> Error("p95 requires at least one sample")
    _ -> {
      let count = list.length(samples)
      let assert Ok(rank) = int.divide(count * 95 + 99, by: 100)
      let assert Ok(value) =
        samples
        |> list.sort(int.compare)
        |> list.drop(up_to: rank - 1)
        |> list.first
      Ok(value)
    }
  }
}

/// Checks a non-negative measurement against an inclusive hard limit.
pub fn within_limit(actual: Int, limit: Int) -> Bool {
  actual >= 0 && limit >= 0 && actual <= limit
}

/// Checks a measurement against a baseline plus an allowed percentage.
///
/// Integer cross-multiplication keeps the gate identical on every target.
/// A zero baseline can only be matched by another zero measurement.
pub fn within_regression(
  actual: Int,
  baseline: Int,
  allowed_percent: Int,
) -> Bool {
  case actual < 0 || baseline < 0 || allowed_percent < 0 {
    True -> False
    False -> actual * 100 <= baseline * { 100 + allowed_percent }
  }
}
