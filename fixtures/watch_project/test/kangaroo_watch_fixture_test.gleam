import kangaroo

@external(erlang, "kangaroo_watch_fixture_ffi", "delay")
@external(javascript, "./kangaroo_watch_fixture_ffi.mjs", "delay")
fn delay() -> Nil

pub fn cancellable_test() {
  delay()
}

pub fn main() {
  kangaroo.main()
}
