pub fn covered() {
  let base = 40
  base + 2
}

pub fn uncovered() {
  99
}

pub fn choose(value: Bool) {
  case value {
    True -> 1
    False -> 2
  }
}
