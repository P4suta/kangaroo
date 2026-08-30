import gleam/dict
import kangaroo/internal/source_positions.{Position}

pub fn locates_unsorted_utf8_byte_offsets_in_one_source_index_test() {
  let positions = source_positions.locate("α\nhello\n世界", [15, 0, 12, 3, 9, 2])
  assert dict.get(positions, 0) == Ok(Position(1, 1))
  assert dict.get(positions, 2) == Ok(Position(1, 2))
  assert dict.get(positions, 3) == Ok(Position(2, 1))
  assert dict.get(positions, 9) == Ok(Position(3, 1))
  assert dict.get(positions, 12) == Ok(Position(3, 2))
  assert dict.get(positions, 15) == Ok(Position(3, 3))
}

pub fn clamps_negative_and_past_end_offsets_test() {
  let positions = source_positions.locate("one", [-1, 99])
  assert dict.get(positions, -1) == Ok(Position(1, 1))
  assert dict.get(positions, 99) == Ok(Position(1, 4))
}
