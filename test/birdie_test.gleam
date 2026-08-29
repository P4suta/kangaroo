import kangaroo/internal/birdie

pub fn birdie_pending_snapshot_selection_test() {
  assert birdie.select_pending([
      "test/birdie_snapshots/zeta.new",
      "test\\birdie_snapshots\\alpha.new",
      "test/birdie_snapshots/alpha.accepted",
      "src/not-a-snapshot.new",
      "birdie_snapshots/legacy.new",
    ])
    == [
      "birdie_snapshots/legacy.new",
      "test/birdie_snapshots/alpha.new",
      "test/birdie_snapshots/zeta.new",
    ]
}

pub fn birdie_review_command_and_rerun_policy_test() {
  assert birdie.arguments() == ["run", "-m", "birdie"]
  assert birdie.rerun_after_review(0) == True
  assert birdie.rerun_after_review(1) == False
  assert birdie.rerun_after_review(2) == False
}
