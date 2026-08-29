import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order, Eq, Gt, Lt}
import gleam/result
import gleam/string
import glexer
import kangaroo/internal/source_positions

/// A test function discovered from a Gleam source module.
///
/// Paths are normalised project-relative paths. Lines and columns are
/// one-based; end positions are exclusive.
pub type IndexedTest {
  IndexedTest(
    id: String,
    name: String,
    path: String,
    module: String,
    line: Int,
    column: Int,
    end_line: Int,
    end_column: Int,
    tags: List(String),
    timeout_ms: Option(Int),
    serial: Bool,
    skip: Option(String),
  )
}

/// The source information used by discovery and dependency invalidation.
pub type IndexedModule {
  IndexedModule(
    path: String,
    module: String,
    content_hash: String,
    imports: List(String),
    tests: List(IndexedTest),
  )
}

pub type IndexError {
  ParseError(path: String, line: Int, message: String)
  InvalidMetadata(id: String, line: Int, message: String)
}

type KangarooImport {
  KangarooImport(module_aliases: List(String), values: List(#(String, String)))
}

type Metadata {
  Metadata(
    tags: List(String),
    timeout_ms: Option(Int),
    serial: Bool,
    skip: Option(String),
  )
}

type Directive {
  Tag(value: String)
  Tags(values: List(String))
  Timeout(value: Int)
  Serial
  Skip(reason: String)
}

/// Parses and indexes one Gleam source file.
///
/// Only public, zero-argument functions whose names end in `_test` are test
/// functions. Glance supplies a real Gleam AST and byte-offset spans, so
/// comments, strings, multiline declarations and aliases are handled without
/// source-text heuristics.
pub fn index(
  path: String,
  source: String,
  test_paths: List(String),
) -> Result(IndexedModule, IndexError) {
  let path = normalise_path(path)
  let module_name = module_name(path, test_paths)

  case glance.module(source) {
    Error(error) ->
      Error(ParseError(
        path,
        parse_error_line(source, error),
        parse_error_message(error),
      ))
    Ok(parsed) -> {
      let imports =
        parsed.imports
        |> list.reverse
        |> list.map(fn(definition) {
          let glance.Definition(_, import_) = definition
          import_.module
        })
      let kangaroo_import = kangaroo_import(parsed.imports)
      let position_offsets =
        parsed.functions
        |> list.map(fn(definition) {
          let glance.Definition(_, function) = definition
          let glance.Span(start, end) = function.location
          [start, end]
        })
        |> list.flatten
      let positions = source_positions.locate(source, position_offsets)
      use tests <- result.try(
        parsed.functions
        |> list.reverse
        |> list.try_map(fn(definition) {
          indexed_test(
            path,
            module_name,
            positions,
            kangaroo_import,
            definition,
          )
        })
        |> result.map(fn(tests) {
          list.filter_map(tests, fn(indexed) {
            case indexed {
              Some(indexed) -> Ok(indexed)
              None -> Error(Nil)
            }
          })
        }),
      )

      Ok(IndexedModule(
        path:,
        module: module_name,
        content_hash: content_hash(source),
        imports:,
        tests:,
      ))
    }
  }
}

fn indexed_test(
  path: String,
  module_name: String,
  positions: Dict(Int, source_positions.Position),
  kangaroo_import: KangarooImport,
  definition: glance.Definition(glance.Function),
) -> Result(Option(IndexedTest), IndexError) {
  let glance.Definition(_, function) = definition
  case
    function.publicity == glance.Public
    && function.parameters == []
    && string.ends_with(function.name, "_test")
  {
    False -> Ok(None)
    True -> {
      let id = path <> "::" <> function.name
      let glance.Span(start, end) = function.location
      let assert Ok(source_positions.Position(line, column)) =
        dict.get(positions, start)
      let assert Ok(source_positions.Position(end_line, end_column)) =
        dict.get(positions, end)
      use metadata <- result.try(metadata(
        function.body,
        kangaroo_import,
        id,
        line,
      ))
      Ok(
        Some(IndexedTest(
          id:,
          name: function.name,
          path:,
          module: module_name,
          line:,
          column:,
          end_line:,
          end_column:,
          tags: metadata.tags,
          timeout_ms: metadata.timeout_ms,
          serial: metadata.serial,
          skip: metadata.skip,
        )),
      )
    }
  }
}

fn metadata(
  statements: List(glance.Statement),
  kangaroo_import: KangarooImport,
  id: String,
  line: Int,
) -> Result(Metadata, IndexError) {
  statements
  |> list.filter_map(statement_expression)
  |> list.fold_until(Ok(Metadata([], None, False, None)), fn(state, expression) {
    case state {
      Error(error) -> list.Stop(Error(error))
      Ok(metadata) ->
        case directive(expression, kangaroo_import, id, line) {
          Error(error) -> list.Stop(Error(error))
          Ok(None) -> list.Continue(Ok(metadata))
          Ok(Some(Tag(value))) ->
            list.Continue(Ok(
              Metadata(..metadata, tags: append_unique(metadata.tags, [value])),
            ))
          Ok(Some(Tags(values))) ->
            list.Continue(Ok(
              Metadata(..metadata, tags: append_unique(metadata.tags, values)),
            ))
          Ok(Some(Timeout(value))) ->
            list.Continue(Ok(Metadata(..metadata, timeout_ms: Some(value))))
          Ok(Some(Serial)) ->
            list.Continue(Ok(Metadata(..metadata, serial: True)))
          Ok(Some(Skip(reason))) ->
            list.Continue(Ok(Metadata(..metadata, skip: Some(reason))))
        }
    }
  })
}

fn statement_expression(
  statement: glance.Statement,
) -> Result(glance.Expression, Nil) {
  case statement {
    glance.Expression(expression) -> Ok(expression)
    glance.Use(function: expression, ..) -> Ok(expression)
    _ -> Error(Nil)
  }
}

fn directive(
  expression: glance.Expression,
  kangaroo_import: KangarooImport,
  id: String,
  fallback_line: Int,
) -> Result(Option(Directive), IndexError) {
  case expression {
    glance.Call(location, function, fields) -> {
      let arguments = list.filter_map(fields, field_expression)
      case directive_name(function, kangaroo_import) {
        None -> Ok(None)
        Some("tag") ->
          case arguments {
            [glance.String(_, value)] -> Ok(Some(Tag(value)))
            _ ->
              invalid(
                id,
                source_line(location, fallback_line),
                "tag must be a string literal",
              )
          }
        Some("tags") ->
          case arguments {
            [glance.List(_, values, None)] ->
              case list.try_map(values, string_literal) {
                Ok(values) -> Ok(Some(Tags(values)))
                Error(_) ->
                  invalid(
                    id,
                    source_line(location, fallback_line),
                    "tags must be a list of string literals",
                  )
              }
            _ ->
              invalid(
                id,
                source_line(location, fallback_line),
                "tags must be a list of string literals",
              )
          }
        Some("timeout") ->
          case arguments {
            [glance.Int(_, value)] ->
              case parse_int_literal(value) {
                Ok(value) if value > 0 -> Ok(Some(Timeout(value)))
                _ ->
                  invalid(
                    id,
                    source_line(location, fallback_line),
                    "timeout must be a positive integer literal",
                  )
              }
            _ ->
              invalid(
                id,
                source_line(location, fallback_line),
                "timeout must be a positive integer literal",
              )
          }
        Some("serial") ->
          case arguments {
            [] -> Ok(Some(Serial))
            _ ->
              invalid(
                id,
                source_line(location, fallback_line),
                "serial takes no arguments",
              )
          }
        Some("skip") ->
          case arguments {
            [glance.String(_, reason)] -> Ok(Some(Skip(reason)))
            _ -> Ok(None)
          }
        _ -> Ok(None)
      }
    }
    _ -> Ok(None)
  }
}

fn parse_int_literal(source: String) -> Result(Int, Nil) {
  let source = string.replace(source, "_", "")
  case source {
    "0b" <> digits -> int.base_parse(digits, 2)
    "0o" <> digits -> int.base_parse(digits, 8)
    "0x" <> digits -> int.base_parse(digits, 16)
    _ -> int.parse(source)
  }
}

fn source_line(_location: glance.Span, fallback: Int) -> Int {
  // The containing source location is supplied by indexed_test. Directive
  // byte offsets are retained in the AST and can be exposed independently in
  // the protocol later; metadata errors currently point at the test function.
  fallback
}

fn invalid(id: String, line: Int, message: String) -> Result(a, IndexError) {
  Error(InvalidMetadata(id:, line:, message:))
}

fn string_literal(expression: glance.Expression) -> Result(String, Nil) {
  case expression {
    glance.String(_, value) -> Ok(value)
    _ -> Error(Nil)
  }
}

fn field_expression(
  field: glance.Field(glance.Expression),
) -> Result(glance.Expression, Nil) {
  case field {
    glance.UnlabelledField(expression) -> Ok(expression)
    glance.LabelledField(item: expression, ..) -> Ok(expression)
    glance.ShorthandField(..) -> Error(Nil)
  }
}

fn directive_name(
  function: glance.Expression,
  kangaroo_import: KangarooImport,
) -> Option(String) {
  case function {
    glance.FieldAccess(_, glance.Variable(_, module_alias), name) ->
      case list.contains(kangaroo_import.module_aliases, module_alias) {
        True -> Some(name)
        False -> None
      }
    glance.Variable(_, local_name) ->
      case
        list.find_map(kangaroo_import.values, fn(value) {
          case value.0 == local_name {
            True -> Ok(value.1)
            False -> Error(Nil)
          }
        })
      {
        Ok(name) -> Some(name)
        Error(_) -> None
      }
    _ -> None
  }
}

fn kangaroo_import(
  imports: List(glance.Definition(glance.Import)),
) -> KangarooImport {
  imports
  |> list.fold(KangarooImport([], []), fn(found, definition) {
    let glance.Definition(_, import_) = definition
    case import_.module {
      "kangaroo" -> {
        let module_alias = case import_.alias {
          Some(glance.Named(name)) -> name
          _ -> "kangaroo"
        }
        let values =
          import_.unqualified_values
          |> list.filter_map(fn(value) {
            let glance.UnqualifiedImport(name, alias) = value
            case is_directive(name) {
              False -> Error(Nil)
              True -> {
                let local_name = case alias {
                  Some(alias) -> alias
                  None -> name
                }
                Ok(#(local_name, name))
              }
            }
          })
        KangarooImport(
          module_aliases: [module_alias, ..found.module_aliases],
          values: list.append(values, found.values),
        )
      }
      _ -> found
    }
  })
}

fn is_directive(name: String) -> Bool {
  name == "tag"
  || name == "tags"
  || name == "timeout"
  || name == "serial"
  || name == "skip"
}

fn append_unique(existing: List(String), values: List(String)) -> List(String) {
  list.fold(values, existing, fn(acc, value) {
    case list.contains(acc, value) {
      True -> acc
      False -> list.append(acc, [value])
    }
  })
}

fn normalise_path(path: String) -> String {
  path
  |> string.replace(each: "\\", with: "/")
  |> drop_dot_slash
  |> collapse_slashes
}

fn drop_dot_slash(path: String) -> String {
  case string.starts_with(path, "./") {
    True -> drop_dot_slash(string.drop_start(path, 2))
    False -> path
  }
}

fn collapse_slashes(path: String) -> String {
  case string.contains(path, "//") {
    True -> collapse_slashes(string.replace(path, each: "//", with: "/"))
    False -> path
  }
}

fn module_name(path: String, test_paths: List(String)) -> String {
  // Gleam's compiler always derives module names from its `test/` and `src/`
  // source roots. A narrower discovery root (for example `test/integration`)
  // must not change the compiled module name.
  case fixed_source_relative(path) {
    Some(relative) -> string.remove_suffix(relative, ".gleam")
    None -> configured_module_name(path, test_paths)
  }
}

fn fixed_source_relative(path: String) -> Option(String) {
  case path {
    "test/" <> relative -> Some(relative)
    "src/" <> relative -> Some(relative)
    _ -> None
  }
}

fn configured_module_name(path: String, test_paths: List(String)) -> String {
  let root =
    test_paths
    |> list.map(normalise_path)
    |> list.filter(fn(root) {
      path == root || string.starts_with(path, root <> "/")
    })
    |> list.sort(longest_first)
    |> list.first

  let relative = case root {
    Ok(root) if path == root -> ""
    Ok(root) -> string.drop_start(path, string.length(root) + 1)
    Error(_) -> path
  }
  string.remove_suffix(relative, ".gleam")
}

fn longest_first(a: String, b: String) -> Order {
  case int.compare(string.length(a), string.length(b)) {
    Lt -> Gt
    Gt -> Lt
    Eq -> Eq
  }
}

fn parse_error_line(source: String, error: glance.Error) -> Int {
  case error {
    glance.UnexpectedEndOfInput -> string.split(source, "\n") |> list.length
    glance.UnexpectedToken(_, position) -> {
      let glexer.Position(offset) = position
      let positions = source_positions.locate(source, [offset])
      let assert Ok(source_positions.Position(line, _)) =
        dict.get(positions, offset)
      line
    }
  }
}

fn parse_error_message(error: glance.Error) -> String {
  case error {
    glance.UnexpectedEndOfInput -> "unexpected end of input"
    glance.UnexpectedToken(..) -> "unexpected token"
  }
}

fn content_hash(source: String) -> String {
  let hash =
    source
    |> string.to_utf_codepoints
    |> list.fold(2_166_136_261, fn(hash, codepoint) {
      let value = string.utf_codepoint_to_int(codepoint)
      result.unwrap(
        int.remainder(hash * 16_777_619 + value, 2_147_483_647),
        hash,
      )
    })
  int.to_base16(hash)
}

pub fn source_hash(source: String) -> String {
  content_hash(source)
}
