import glance
import gleam/list
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
      case has_kangaroo_main(source) {
        True -> AlreadyConfigured
        False ->
          case known_runner(compact(source)) {
            True -> ReplaceKnown(path, source, contents)
            False -> Suggest(path, contents)
          }
      }
  }
}

type KangarooImport {
  KangarooImport(module_aliases: List(String), unqualified_main: List(String))
}

/// Recognises a real direct call from the package entry point. Parsing the
/// source keeps comments and string literals containing `kangaroo.main()`
/// from turning a custom runner into a false successful no-op.
fn has_kangaroo_main(source: String) -> Bool {
  case glance.module(source) {
    Error(_) -> False
    Ok(parsed) -> {
      let imported = kangaroo_import(parsed.imports)
      list.any(parsed.functions, fn(definition) {
        let glance.Definition(_, function) = definition
        function.publicity == glance.Public
        && function.name == "main"
        && function.parameters == []
        && list.any(function.body, fn(statement) {
          case statement {
            glance.Expression(expression) ->
              is_kangaroo_main(expression, imported)
            _ -> False
          }
        })
      })
    }
  }
}

fn kangaroo_import(
  imports: List(glance.Definition(glance.Import)),
) -> KangarooImport {
  list.fold(imports, KangarooImport([], []), fn(found, definition) {
    let glance.Definition(_, imported) = definition
    case imported.module {
      "kangaroo" -> {
        let module_alias = case imported.alias {
          Some(glance.Named(name)) -> name
          _ -> "kangaroo"
        }
        let unqualified_main =
          imported.unqualified_values
          |> list.filter_map(fn(value) {
            let glance.UnqualifiedImport(name, alias) = value
            case name {
              "main" ->
                Ok(case alias {
                  Some(alias) -> alias
                  None -> name
                })
              _ -> Error(Nil)
            }
          })
        KangarooImport(
          module_aliases: [module_alias, ..found.module_aliases],
          unqualified_main: list.append(
            unqualified_main,
            found.unqualified_main,
          ),
        )
      }
      _ -> found
    }
  })
}

fn is_kangaroo_main(
  expression: glance.Expression,
  imported: KangarooImport,
) -> Bool {
  case expression {
    glance.Call(
      _,
      glance.FieldAccess(_, glance.Variable(_, module_alias), "main"),
      [],
    ) -> list.contains(imported.module_aliases, module_alias)
    glance.Call(_, glance.Variable(_, local_name), []) ->
      list.contains(imported.unqualified_main, local_name)
    _ -> False
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
