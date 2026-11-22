// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Owns stable hazard records, exclusive record leases and deferred callback lifetimes. */
module HazardReclamation;
part "holder.ny";
part "records.ny";
import "kernel:kernel.ny";
import "interface/source.ni";
import "interface/domain.ni";

struct HazardRecord {
  claimed: Atomic<int32>;
  protected_address: Atomic<uintptr>;
  retired: FastArray<HazardRetirement>;
  scratch: FastArray<HazardRetirement>;
  collecting: bool;
}

struct HazardState {
  records: owned <HazardRecord>[];
  threshold: int32;
}

/** @brief Shared owner of the stable slab; no per-protection shared-owner acquisition. */
pub struct HazardDomain {
  state: arc<HazardState>?;
}

/** @brief Exclusive reusable lease whose raw record is pinned by state. */
@scoped pub struct HazardHolder {
  state: arc<HazardState>?;
  record: *mut HazardRecord;
  scoped: bool;
}

pub static method(HazardDomain) New(
  records: int32, allocator: Allocator, { retire_threshold: int32 = 64 }
) -> Result<HazardDomain, HazardError> {
  if records < 1 || retire_threshold < 1 {
    return HazardError.InvalidArgument;
  }

  var slab: owned <HazardRecord>[] = new(allocator) <HazardRecord>[records];
  if slab.length != records {
    return HazardError.OutOfMemory;
  }

  var index: int32 = 0;
  while index < records {
    slab[index] = HazardRecord{
      retired: FastArray<HazardRetirement>.NewWithAllocator(allocator),
      scratch: FastArray<HazardRetirement>.NewWithAllocator(allocator)
    };
    index += 1;
  }

  let state: arc<HazardState> = new(allocator) arc<HazardState>{
    records: move(slab), threshold: retire_threshold
  };
  unsafe {
    // Scalar managed new returns an inert zero handle on allocation failure.
    // Optional lifting would represent a present handle, not test that address.
    if (state as *const HazardState) == nil {
      return HazardError.OutOfMemory;
    }
  }

  return HazardDomain{state: state};
}

pub method(HazardDomain) Acquire() -> Result<HazardHolder, HazardError> {
  if self.state == nil {
    return HazardError.Inactive;
  }

  let state = self.state as arc<HazardState>;
  var index: int32 = 0;
  while index < state.records.length {
    var expected: int32 = 0;
    if state.records[index].claimed.CompareExchangeStrong(
      expected, 1, MemoryOrder.AcqRel, MemoryOrder.Acquire
    ) {
      var holder = HazardHolder{state: state, record: &mut state.records[index]};
      holder.Collect();
      return move(holder);
    }

    index += 1;
  }

  return HazardError.NoRecords;
}

pub method(HazardDomain) Collect() -> int64 {
  if self.state == nil {
    return 0i64;
  }

  let state = self.state as arc<HazardState>;
  var reclaimed: int64 = 0i64;
  var index: int32 = 0;
  while index < state.records.length {
    var expected: int32 = 0;
    if state.records[index].claimed.CompareExchangeStrong(
      expected, 1, MemoryOrder.AcqRel, MemoryOrder.Acquire
    ) {
      // The temporary lease releases itself even when a callback reenters the domain.
      let holder = HazardHolder{state: state, record: &mut state.records[index]};
      reclaimed += holder.Collect() as int64;
    }

    index += 1;
  }

  return reclaimed;
}

pub method(HazardDomain) Capacity() -> int32 {
  return self.state == nil ? 0 : (self.state as arc<HazardState>).records.length;
}
