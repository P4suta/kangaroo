import kangaroo/report.{type CaseResult}

@external(erlang, "kangaroo_reporter_ffi", "append")
@external(javascript, "../../kangaroo_reporter_ffi.mjs", "append")
pub fn append(result: CaseResult) -> Nil

@external(erlang, "kangaroo_reporter_ffi", "take")
@external(javascript, "../../kangaroo_reporter_ffi.mjs", "take")
pub fn take() -> List(CaseResult)

@external(erlang, "kangaroo_reporter_ffi", "append_output")
@external(javascript, "../../kangaroo_reporter_ffi.mjs", "append_output")
pub fn append_output(case_name: String, stdout: String, stderr: String) -> Nil

@external(erlang, "kangaroo_reporter_ffi", "take_output")
@external(javascript, "../../kangaroo_reporter_ffi.mjs", "take_output")
pub fn take_output() -> List(#(String, String, String))
