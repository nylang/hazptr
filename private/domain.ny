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

/** @brief Allocate a caller-sized record slab; no hidden maximum participant count.
 * @param records Positive maximum number of simultaneously live holders, including collectors.
 * @param retire_threshold Positive batch trigger; protected survivors may exceed it.
 * @param allocator Allocator row copied into managed allocations and retirement buffers;
 *        its borrowed context must outlive all holders and final reclamation.
 * @returns Domain, InvalidArgument or OutOfMemory after checking metadata allocation.
 * @note Buffer growth during retirement is checked and returns unaccepted ownership on OOM. */
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

/** @brief Lease one reusable thread-confined record; registration does not affect existing readers.
 * @returns Move-only holder or NoRecords; an inert domain returns Inactive.
 * @note Reuses retired storage from the previous lease and may reclaim its safe entries. */
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

/** @brief Collect retirements from currently unleased records without waiting for active holders.
 * @returns Number reclaimed by this call. Active holders collect their own batches.
 * @note Safe with concurrent registration and collection. Callbacks execute without a domain lock. */
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

/** @brief Read configured simultaneous-holder capacity, or zero for an inert domain.
 * @returns Record capacity; not a reservation. */
pub method(HazardDomain) Capacity() -> int32 {
  return self.state == nil ? 0 : (self.state as arc<HazardState>).records.length;
}
