import gleam/option.{None, Some}
import kangaroo/internal/init.{AlreadyConfigured, Create, ReplaceKnown, Suggest}

pub fn annotated_known_runner_test() {
  let unitest =
    "import unitest\n\npub fn main() -> Nil {\n  unitest.main()\n}\n"
  assert init.plan("my_app", Some(unitest))
    == ReplaceKnown(
      "test/my_app_test.gleam",
      unitest,
      "import kangaroo\n\npub fn main() {\n  kangaroo.main()\n}\n",
    )
}

pub fn init_creates_package_test_main_only_when_absent_test() {
  assert init.plan("my_app", None)
    == Create(
      "test/my_app_test.gleam",
      "import kangaroo\n\npub fn main() {\n  kangaroo.main()\n}\n",
    )
}

pub fn init_recognises_existing_kangaroo_main_test() {
  assert init.plan(
      "my_app",
      Some("import kangaroo\npub fn main() { kangaroo.main() }"),
    )
    == AlreadyConfigured
}

pub fn init_does_not_treat_comments_or_strings_as_a_configured_runner_test() {
  let commented = "pub fn main() { custom() }\n// Suggested: kangaroo.main()\n"
  let string_literal =
    "pub fn main() { let hint = \"kangaroo.main()\" custom(hint) }\n"

  let assert Suggest(_, _) = init.plan("my_app", Some(commented))
  let assert Suggest(_, _) = init.plan("my_app", Some(string_literal))
}

pub fn init_recognises_aliased_and_unqualified_kangaroo_main_test() {
  assert init.plan(
      "my_app",
      Some("import kangaroo as k\npub fn main() { k.main() }\n"),
    )
    == AlreadyConfigured
  assert init.plan(
      "my_app",
      Some("import kangaroo.{main as run}\npub fn main() { run() }\n"),
    )
    == AlreadyConfigured
}

pub fn init_does_not_accept_a_private_kangaroo_entrypoint_test() {
  let assert Suggest(_, _) =
    init.plan(
      "my_app",
      Some("import kangaroo\nfn main() { kangaroo.main() }\n"),
    )
}

pub fn init_replaces_only_known_gleeunit_or_unitest_main_test() {
  let gleeunit = "import gleeunit\n\npub fn main() {\n  gleeunit.main()\n}\n"
  assert init.plan("my_app", Some(gleeunit))
    == ReplaceKnown(
      "test/my_app_test.gleam",
      gleeunit,
      "import kangaroo\n\npub fn main() {\n  kangaroo.main()\n}\n",
    )
}

pub fn init_suggests_diff_for_custom_existing_file_test() {
  let assert Suggest(path, suggestion) =
    init.plan("my_app", Some("pub fn main() { custom() }"))
  assert path == "test/my_app_test.gleam"
  assert suggestion
    == "import kangaroo\n\npub fn main() {\n  kangaroo.main()\n}\n"
}
