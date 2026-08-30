import calculator
import kangaroo

pub fn main() {
  kangaroo.main()
}

pub fn covered_test() {
  assert calculator.covered() == 42
  assert calculator.choose(True) == 1
}
