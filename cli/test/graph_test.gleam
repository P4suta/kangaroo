import gleam/list
import gleam/option.{Some}
import kangaroo/expect.{expect, to_equal}
import kangaroo/suite.{it, suite}
import kangaroo_cli/graph.{
  ModuleName, imports, module_name, module_name_of_file, module_name_string,
  source_path,
}

pub fn suites() {
  [
    suite("graph", [
      it("parses simple imports", fn() {
        let source = "import a/b\nimport c\n"
        let modules = imports(source)
        expect(list.map(modules, module_name_string))
        |> to_equal(["a/b"])
      }),
      it("ignores stdlib imports", fn() {
        let source =
          "import gleam/list\nimport gleam/string.{pop}\nimport a/b\n"
        let modules = imports(source)
        expect(list.map(modules, module_name_string)) |> to_equal(["a/b"])
      }),
      it("ignores import with braces for stdlib", fn() {
        let source = "import a/b.{type B}\n"
        let modules = imports(source)
        expect(list.map(modules, module_name_string)) |> to_equal(["a/b"])
      }),
      it("handles module aliases", fn() {
        let source = "import a/b as thing\n"
        let modules = imports(source)
        expect(list.map(modules, module_name_string)) |> to_equal(["a/b"])
      }),
      it("ignores non-import lines", fn() {
        let source = "import a/b\n\npub fn main() { Nil }\n// import x/y\n"
        let modules = imports(source)
        expect(list.map(modules, module_name_string)) |> to_equal(["a/b"])
      }),
      it("extracts module names from source paths", fn() {
        expect(module_name_of_file("src/foo.gleam", ".gleam"))
        |> to_equal(Some(ModuleName(["foo"])))
        expect(module_name_of_file("src/a/b.gleam", ".gleam"))
        |> to_equal(Some(ModuleName(["a", "b"])))
        expect(module_name_of_file("test/foo_test.gleam", ".gleam"))
        |> to_equal(Some(ModuleName(["foo_test"])))
      }),
      it("computes source paths", fn() {
        expect(source_path(module_name(["foo"]), "src"))
        |> to_equal("src/foo.gleam")
        expect(source_path(module_name(["a", "b"]), "src"))
        |> to_equal("src/a/b.gleam")
      }),
    ]),
  ]
}
