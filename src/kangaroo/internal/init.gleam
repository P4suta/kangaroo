import gleam/option.{type Option, None, Some}
import gleam/string

pub type Action {
  Create(path: String, contents: String)
  ReplaceKnown(path: String, expected: String, contents: String)
  AlreadyConfigured
  Suggest(path: String, contents: String)
}

pub fn plan(package: String, existing: Option(String)) -> Action {
  let path = "test/" <> package <> "_test.gleam"
  let contents = entrypoint()
  case existing {
    None -> Create(path, contents)
    Some(source) ->
      case string.contains(compact(source), "kangaroo.main()") {
        True -> AlreadyConfigured
        False ->
          case known_runner(compact(source)) {
            True -> ReplaceKnown(path, source, contents)
            False -> Suggest(path, contents)
          }
      }
  }
}

pub fn entrypoint() -> String {
  "import kangaroo\n\npub fn main() {\n  kangaroo.main()\n}\n"
}

fn known_runner(source: String) -> Bool {
  let source = string.replace(source, each: "->Nil", with: "")
  source == "importgleeunitpubfnmain(){gleeunit.main()}"
  || source == "importunitestpubfnmain(){unitest.main()}"
}

fn compact(source: String) -> String {
  source
  |> string.replace(each: " ", with: "")
  |> string.replace(each: "\n", with: "")
  |> string.replace(each: "\r", with: "")
  |> string.replace(each: "\t", with: "")
}
