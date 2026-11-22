// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

part of HazardReclamation;

method(HazardState) IsProtected(address: uintptr) -> bool {
  var index: int32 = 0;
  while index < self.records.length {
    if self.records[index].protected_address.Load(MemoryOrder.SeqCst) == address {
      return true;
    }

    index += 1;
  }

  return false;
}

method(HazardRecord) Collect(state: arc<HazardState>) -> int32 {
  if self.collecting || self.retired.Len() == 0 {
    return 0;
  }

  self.collecting = true;
  // Both buffers are reserved before retirement admission. Detach the batch
  // before scanning; callbacks cannot mutate this holder's collection buffers.
  var batch = move(self.retired);
  self.retired = move(self.scratch);
  var reclaimed: int32 = 0;
  while batch.Len() > 0 {
    let retirement = batch.Pop();
    if state.IsProtected(retirement.address) {
      self.retired.Push(move(retirement));
    } else {
      HazardRetirement.Run(move(retirement));
      reclaimed += 1;
    }
  }

  self.scratch = move(batch);
  self.collecting = false;

  return reclaimed;
}

static method(HazardRetirement) Run(retirement: HazardRetirement) -> void {
  // Consuming the callback in this frame releases its owner captures before
  // the caller publishes the reclaimed count or makes this record available.
  retirement.reclaim();
}

method(HazardState) operator drop() -> void {
  // Every lease retains this state, so final drop has no concurrent readers
  // or collectors. No waiting or forced clearing of live hazard records.
  var index: int32 = 0;
  while index < self.records.length {
    while self.records[index].retired.Len() > 0 {
      HazardRetirement.Run(self.records[index].retired.Pop());
    }

    index += 1;
  }
}
