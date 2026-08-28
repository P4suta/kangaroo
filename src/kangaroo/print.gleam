/// Converts a value to a human-readable representation for failure
/// messages. Strings are shown as their raw content so that multi-line
/// diffs work; everything else is inspected structurally.
@external(erlang, "kangaroo_print_ffi", "to_string")
@external(javascript, "../kangaroo_print_ffi.mjs", "to_string")
pub fn to_string(value: a) -> String
