import gleam/option.{None, Some}
import kangaroo/internal/generation.{Cancel, Publish, Start}

pub fn changed_generation_cancels_active_before_starting_next_test() {
  let #(first, first_actions) = generation.changed(generation.idle())
  assert first_actions == [Start(1)]
  let #(second, second_actions) = generation.changed(first)
  assert second_actions == [Cancel(1), Start(2)]
  assert generation.active(second) == Some(2)
}

pub fn stale_generation_result_is_never_published_test() {
  let #(first, _) = generation.changed(generation.idle())
  let #(second, _) = generation.changed(first)
  let #(unchanged, stale_actions) = generation.finished(second, 1)
  assert stale_actions == []
  assert unchanged == second
  let #(done, latest_actions) = generation.finished(second, 2)
  assert latest_actions == [Publish(2)]
  assert generation.active(done) == None
}

pub fn duplicate_generation_completion_is_ignored_test() {
  let #(running, _) = generation.changed(generation.idle())
  let #(done, _) = generation.finished(running, 1)
  let #(same, actions) = generation.finished(done, 1)
  assert actions == []
  assert same == done
}
