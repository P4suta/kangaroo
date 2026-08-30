import glance
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{Gt, Lt}
import gleam/string

const base_probe_alias = "kangaroo_coverage_probe"

pub type Instrumented {
  Instrumented(source: String, executable_lines: List(Int))
}

type Edit {
  Edit(position: Int, text: String)
}

type Instrumentation {
  Instrumentation(edits: List(Edit), lines: List(Int))
}

/// Adds source-line probes using Glance's backend-native Gleam AST spans.
///
/// Every statement is executable. A case-clause body that consists of one
/// expression is wrapped in a block so each branch has its own source line.
/// The original file is never mutated; callers receive a transformed copy.
pub fn instrument(
  path: String,
  source: String,
) -> Result(Instrumented, String) {
  case glance.module(source) {
    Error(error) ->
      Error(
        path <> ": could not instrument coverage: " <> string.inspect(error),
      )
    Ok(parsed) -> {
      let probe_alias = unused_probe_alias(source, base_probe_alias)
      let instrumentation =
        parsed.functions
        |> list.fold(Instrumentation([], []), fn(state, definition) {
          let glance.Definition(_, function) = definition
          merge(
            state,
            instrument_statements(function.body, path, source, probe_alias),
          )
        })
      let edits = case instrumentation.lines {
        [] -> instrumentation.edits
        _ -> {
          let probe_import =
            "import kangaroo/coverage_probe as " <> probe_alias <> "\n"
          [
            Edit(module_import_position(source), probe_import),
            ..instrumentation.edits
          ]
        }
      }
      let transformed =
        edits
        |> list.sort(descending_edits)
        |> list.fold(source, fn(current, edit) {
          insert_at_offset(current, edit.position, edit.text)
        })
      Ok(Instrumented(
        source: transformed,
        executable_lines: instrumentation.lines
          |> list.unique
          |> list.sort(int.compare),
      ))
    }
  }
}

fn module_import_position(source: String) -> Int {
  module_doc_position(string.split(source, "\n"), 0)
}

fn module_doc_position(lines: List(String), position: Int) -> Int {
  case lines {
    [line, ..rest] ->
      case string.starts_with(line, "////") {
        True -> module_doc_position(rest, position + string.byte_size(line) + 1)
        False -> position
      }
    [] -> position
  }
}

fn instrument_statements(
  statements: List(glance.Statement),
  path: String,
  source: String,
  probe_alias: String,
) -> Instrumentation {
  list.fold(statements, Instrumentation([], []), fn(state, statement) {
    merge(state, instrument_statement(statement, path, source, probe_alias))
  })
}

fn instrument_statement(
  statement: glance.Statement,
  path: String,
  source: String,
  probe_alias: String,
) -> Instrumentation {
  let #(span, expressions) = case statement {
    glance.Use(location, _, function) -> #(location, [function])
    glance.Assignment(location, kind, _, _, value) -> {
      let messages = case kind {
        glance.Let -> []
        glance.LetAssert(message) -> option_list(message)
      }
      #(location, [value, ..messages])
    }
    glance.Assert(location, expression, message) -> #(location, [
      expression,
      ..option_list(message)
    ])
    glance.Expression(expression) -> #(expression_span(expression), [expression])
  }
  let glance.Span(start, _) = span
  let line = line_at_offset(source, start)
  let nested = instrument_expressions(expressions, path, source, probe_alias)
  Instrumentation(
    edits: [Edit(start, hit(path, line, probe_alias) <> "\n"), ..nested.edits],
    lines: [line, ..nested.lines],
  )
}

fn instrument_expressions(
  expressions: List(glance.Expression),
  path: String,
  source: String,
  probe_alias: String,
) -> Instrumentation {
  list.fold(expressions, Instrumentation([], []), fn(state, expression) {
    merge(state, instrument_expression(expression, path, source, probe_alias))
  })
}

fn instrument_expression(
  expression: glance.Expression,
  path: String,
  source: String,
  probe_alias: String,
) -> Instrumentation {
  case expression {
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> Instrumentation([], [])
    glance.NegateInt(_, value) | glance.NegateBool(_, value) ->
      instrument_expression(value, path, source, probe_alias)
    glance.Block(_, statements) ->
      instrument_statements(statements, path, source, probe_alias)
    glance.Panic(_, message) | glance.Todo(_, message) ->
      instrument_expressions(option_list(message), path, source, probe_alias)
    glance.Tuple(_, elements) ->
      instrument_expressions(elements, path, source, probe_alias)
    glance.List(_, elements, rest) ->
      instrument_expressions(
        list.append(elements, option_list(rest)),
        path,
        source,
        probe_alias,
      )
    glance.Fn(_, _, _, body) ->
      instrument_statements(body, path, source, probe_alias)
    glance.RecordUpdate(_, _, _, record, fields) -> {
      let values =
        list.filter_map(fields, fn(field) {
          let glance.RecordUpdateField(_, item) = field
          case item {
            Some(value) -> Ok(value)
            None -> Error(Nil)
          }
        })
      instrument_expressions([record, ..values], path, source, probe_alias)
    }
    glance.FieldAccess(_, container, _) ->
      instrument_expression(container, path, source, probe_alias)
    glance.Call(_, function, arguments) ->
      instrument_expressions(
        [function, ..field_values(arguments)],
        path,
        source,
        probe_alias,
      )
    glance.TupleIndex(_, tuple, _) ->
      instrument_expression(tuple, path, source, probe_alias)
    glance.FnCapture(_, _, function, before, after) ->
      instrument_expressions(
        [function, ..list.append(field_values(before), field_values(after))],
        path,
        source,
        probe_alias,
      )
    glance.BitString(_, segments) ->
      segments
      |> list.fold(Instrumentation([], []), fn(state, segment) {
        let #(value, options) = segment
        let values =
          options
          |> list.filter_map(fn(option) {
            case option {
              glance.SizeValueOption(value) -> Ok(value)
              _ -> Error(Nil)
            }
          })
        merge(
          state,
          instrument_expressions([value, ..values], path, source, probe_alias),
        )
      })
    glance.Case(_, subjects, clauses) -> {
      let state = instrument_expressions(subjects, path, source, probe_alias)
      list.fold(clauses, state, fn(state, clause) {
        merge(state, instrument_clause(clause, path, source, probe_alias))
      })
    }
    glance.BinaryOperator(_, _, left, right) ->
      instrument_expressions([left, right], path, source, probe_alias)
    glance.Echo(_, expression, message) ->
      instrument_expressions(
        list.append(option_list(expression), option_list(message)),
        path,
        source,
        probe_alias,
      )
  }
}

fn instrument_clause(
  clause: glance.Clause,
  path: String,
  source: String,
  probe_alias: String,
) -> Instrumentation {
  let glance.Clause(guard: guard, body: body, ..) = clause
  let guard_instrumentation =
    instrument_expressions(option_list(guard), path, source, probe_alias)
  case body {
    glance.Block(..) ->
      merge(
        guard_instrumentation,
        instrument_expression(body, path, source, probe_alias),
      )
    _ -> {
      let glance.Span(start, end) = expression_span(body)
      let line = line_at_offset(source, start)
      let body_instrumentation =
        instrument_expression(body, path, source, probe_alias)
      merge(
        guard_instrumentation,
        merge(
          Instrumentation(
            edits: [
              Edit(start, "{ " <> hit(path, line, probe_alias) <> "\n"),
              Edit(end, "\n}"),
            ],
            lines: [line],
          ),
          body_instrumentation,
        ),
      )
    }
  }
}

fn expression_span(expression: glance.Expression) -> glance.Span {
  case expression {
    glance.Int(location, _)
    | glance.Float(location, _)
    | glance.String(location, _)
    | glance.Variable(location, _)
    | glance.NegateInt(location, _)
    | glance.NegateBool(location, _)
    | glance.Block(location, _)
    | glance.Panic(location, _)
    | glance.Todo(location, _)
    | glance.Tuple(location, _)
    | glance.List(location, _, _)
    | glance.Fn(location, _, _, _)
    | glance.RecordUpdate(location, _, _, _, _)
    | glance.FieldAccess(location, _, _)
    | glance.Call(location, _, _)
    | glance.TupleIndex(location, _, _)
    | glance.FnCapture(location, _, _, _, _)
    | glance.BitString(location, _)
    | glance.Case(location, _, _)
    | glance.BinaryOperator(location, _, _, _)
    | glance.Echo(location, _, _) -> location
  }
}

fn field_values(
  fields: List(glance.Field(glance.Expression)),
) -> List(glance.Expression) {
  list.filter_map(fields, fn(field) {
    case field {
      glance.LabelledField(item: item, ..) | glance.UnlabelledField(item) ->
        Ok(item)
      glance.ShorthandField(..) -> Error(Nil)
    }
  })
}

fn option_list(value: Option(a)) -> List(a) {
  case value {
    Some(value) -> [value]
    None -> []
  }
}

fn hit(path: String, line: Int, probe_alias: String) -> String {
  probe_alias
  <> ".hit(\""
  <> escape_string(path)
  <> "\", "
  <> int.to_string(line)
  <> ")"
}

fn unused_probe_alias(source: String, candidate: String) -> String {
  case string.contains(source, candidate) {
    True -> unused_probe_alias(source, candidate <> "_")
    False -> candidate
  }
}

fn escape_string(value: String) -> String {
  value
  |> string.replace(each: "\\", with: "\\\\")
  |> string.replace(each: "\"", with: "\\\"")
  |> string.replace(each: "\n", with: "\\n")
  |> string.replace(each: "\r", with: "\\r")
}

fn merge(first: Instrumentation, second: Instrumentation) -> Instrumentation {
  Instrumentation(
    edits: list.append(first.edits, second.edits),
    lines: list.append(first.lines, second.lines),
  )
}

fn descending_edits(first: Edit, second: Edit) {
  case int.compare(first.position, second.position) {
    Lt -> Gt
    Gt -> Lt
    order -> order
  }
}

@external(erlang, "kangaroo_coverage_instrument_ffi", "insert_at_offset")
@external(javascript, "../../kangaroo_coverage_instrument_ffi.mjs", "insert_at_offset")
fn insert_at_offset(source: String, position: Int, insertion: String) -> String

@external(erlang, "kangaroo_coverage_instrument_ffi", "line_at_offset")
@external(javascript, "../../kangaroo_coverage_instrument_ffi.mjs", "line_at_offset")
fn line_at_offset(source: String, position: Int) -> Int
