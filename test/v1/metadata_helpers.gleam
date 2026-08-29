import gleam/string
import kangaroo

pub fn metadata_helpers_test() {
  kangaroo.tag("unit")
  kangaroo.tags(["fast", "public-api"])
  kangaroo.timeout(5000)
  kangaroo.serial()
  assert string.length("kangaroo") == 8
}
