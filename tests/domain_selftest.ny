// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

import "stdlib:stdlib.ny";
import "ntest:ntest.ny";
import "hazptr.ny";

struct HazardTestCounts {
  reclaimed: Atomic<int32>;
  dropped: Atomic<int32>;
}

struct HazardTestObject {
  value: int32;
  counts: arc<HazardTestCounts>;
}

method(HazardTestObject) Address() -> uintptr {
  return (&mut self.value) as uintptr;
}

method(HazardTestObject) Reclaim() -> void {
  AssertTrue(self.value > 0);
  self.counts.reclaimed.FetchAdd(1, MemoryOrder.Relaxed);
}

method(HazardTestObject) operator drop() -> void {
  self.counts.dropped.FetchAdd(1, MemoryOrder.Relaxed);
}

static method(HazardTestObject) Retire(
  holder: ref mut HazardHolder, owner: arc<HazardTestObject>
) -> Result<Unit, HazardRetireFailure> {
  unsafe {
    return holder.TryRetire(HazardRetirement{address: owner.Address(), reclaim: lambda[copy owner]() -> void {
      owner.Reclaim();
    }});
  }
}

method(HazardDomain) TestHolder() -> HazardHolder {
  var result = self.Acquire();
  AssertTrue(result.IsOk());

  return move(result.get_if<HazardHolder>()!);
}

static method(HazardTestObject) EarlyReturn(domain: HazardDomain, source: ref HazardSource) -> void {
  var holder = domain.TestHolder();
  scope (holder) {
    holder.Protect(source);
    return;
  }
}

@test
func test_hazptr_domain_configuration_and_inactive_handles() {
  let heap = Allocator.ProcessHeap(0i64, 0i64);
  AssertTrue(HazardDomain.New(0, heap).get_if<HazardError>()! == HazardError.InvalidArgument);
  AssertTrue(HazardDomain.New(1, heap, retire_threshold: 0).IsErr());
  let domain = HazardDomain.New(2, heap).get_if<HazardDomain>()!;
  AssertEqI32(domain.Capacity(), 2);
  AssertEqI64(domain.Collect(), 0i64);
  AssertEqI32(HazardDomain{}.Capacity(), 0);
  AssertTrue(HazardDomain{}.Acquire().get_if<HazardError>()! == HazardError.Inactive);
  var holder = HazardHolder{};
  holder.Reset();
  AssertEqI32(holder.Pending(), 0);
  AssertEqI32(holder.Collect(), 0);
}

@test
func test_hazptr_source_exchange_and_compare_validation() {
  var source = HazardSource.New(11up);
  AssertTrue(source.Load() == 11up);
  var expected = 12up;
  AssertTrue(!source.CompareExchange(expected, 22up));
  AssertTrue(expected == 11up);
  AssertTrue(source.CompareExchange(expected, 22up));
  AssertTrue(source.Exchange(0up) == 22up);
  AssertTrue(source.Load() == 0up);
}

@test
func test_hazptr_leases_exhaust_move_and_reuse_without_copying() {
  let domain = HazardDomain.New(1, Allocator.ProcessHeap(0i64, 0i64)).get_if<HazardDomain>()!;
  let lease = lambda[copy domain]() -> void {
    var first = domain.TestHolder();
    var second = move(first);
    AssertTrue(domain.Acquire().get_if<HazardError>()! == HazardError.NoRecords);
    AssertEqI64(domain.Collect(), 0i64);
  };
  lease();
  var reused = domain.TestHolder();
  AssertEqI32(reused.Pending(), 0);
}

@test
func test_hazptr_protected_retirement_waits_for_reset() {
  let domain = HazardDomain.New(2, Allocator.ProcessHeap(0i64, 0i64), retire_threshold: 1).get_if<HazardDomain>()!;
  var reader = domain.TestHolder();
  var writer = domain.TestHolder();
  let counts = new arc<HazardTestCounts>{};
  let object = new arc<HazardTestObject>{value: 7, counts: counts};
  var source = HazardSource.New(object.Address());
  AssertTrue(reader.Protect(source) == object.Address());
  source.Exchange(0up);
  AssertTrue(HazardTestObject.Retire(writer, object).IsOk());
  AssertEqI32(writer.Pending(), 1);
  AssertEqI32(counts.reclaimed.Load(MemoryOrder.Relaxed), 0);
  reader.Reset();
  AssertEqI32(writer.Collect(), 1);
  AssertEqI32(writer.Pending(), 0);
  AssertEqI32(writer.Collect(), 0);
  AssertEqI32(counts.reclaimed.Load(MemoryOrder.Relaxed), 1);
}

@test
func test_hazptr_all_protectors_must_release_the_address() {
  let domain = HazardDomain.New(3, Allocator.ProcessHeap(0i64, 0i64)).get_if<HazardDomain>()!;
  var first = domain.TestHolder();
  var second = domain.TestHolder();
  var writer = domain.TestHolder();
  let counts = new arc<HazardTestCounts>{};
  let object = new arc<HazardTestObject>{value: 8, counts: counts};
  var source = HazardSource.New(object.Address());
  first.Protect(source);
  second.Protect(source);
  source.Store(0up);
  AssertTrue(HazardTestObject.Retire(writer, object).IsOk());
  first.Reset();
  AssertEqI32(writer.Collect(), 0);
  second.Reset();
  AssertEqI32(writer.Collect(), 1);
}

@test
func test_hazptr_replacing_protection_does_not_pin_the_previous_address() {
  let domain = HazardDomain.New(2, Allocator.ProcessHeap(0i64, 0i64)).get_if<HazardDomain>()!;
  var reader = domain.TestHolder();
  var writer = domain.TestHolder();
  let counts = new arc<HazardTestCounts>{};
  let first = new arc<HazardTestObject>{value: 9, counts: counts};
  let second = new arc<HazardTestObject>{value: 10, counts: counts};
  var source = HazardSource.New(first.Address());
  reader.Protect(source);
  source.Exchange(second.Address());
  AssertTrue(HazardTestObject.Retire(writer, first).IsOk());
  AssertEqI32(writer.Collect(), 0);
  reader.Protect(source);
  AssertEqI32(writer.Collect(), 1);
  source.Store(0up);
  AssertTrue(HazardTestObject.Retire(writer, second).IsOk());
  AssertEqI32(writer.Collect(), 0);
  AssertTrue(reader.Protect(source) == 0up);
  AssertEqI32(writer.Collect(), 1);
}

@test
func test_hazptr_scope_return_break_and_continue_reset_the_slot() {
  let domain = HazardDomain.New(2, Allocator.ProcessHeap(0i64, 0i64)).get_if<HazardDomain>()!;
  var writer = domain.TestHolder();
  let counts = new arc<HazardTestCounts>{};
  let object = new arc<HazardTestObject>{value: 11, counts: counts};
  var source = HazardSource.New(object.Address());
  HazardTestObject.EarlyReturn(domain, source);
  var holder = domain.TestHolder();
  var index: int32 = 0;
  while index < 2 {
    scope (holder) {
      holder.Protect(source);
      index += 1;
      if index == 1 {
        continue;
      }

      break;
    }
  }

  source.Store(0up);
  AssertTrue(HazardTestObject.Retire(writer, object).IsOk());
  AssertEqI32(writer.Collect(), 1);
}

@test
func test_hazptr_abandoned_batch_survives_until_reader_and_domain_collection() {
  let domain = HazardDomain.New(2, Allocator.ProcessHeap(0i64, 0i64)).get_if<HazardDomain>()!;
  var reader = domain.TestHolder();
  let counts = new arc<HazardTestCounts>{};
  let object = new arc<HazardTestObject>{value: 12, counts: counts};
  var source = HazardSource.New(object.Address());
  reader.Protect(source);
  source.Store(0up);
  let abandon = lambda[copy domain, copy object]() -> void {
    var writer = domain.TestHolder();
    AssertTrue(HazardTestObject.Retire(writer, object).IsOk());
  };
  abandon();
  AssertEqI64(domain.Collect(), 0i64);
  reader.Reset();
  AssertEqI64(domain.Collect(), 1i64);
  AssertEqI64(domain.Collect(), 0i64);
}

@test
func test_hazptr_holder_keeps_domain_alive_after_last_public_handle() {
  var domain = HazardDomain.New(1, Allocator.ProcessHeap(0i64, 0i64)).get_if<HazardDomain>()!;
  var holder = domain.TestHolder();
  domain = HazardDomain{};
  var source = HazardSource.New(0up);
  AssertTrue(holder.Protect(source) == 0up);
  AssertEqI32(holder.Collect(), 0);
}

@test
func test_hazptr_final_state_drop_drains_an_uncollected_batch() {
  let counts = new arc<HazardTestCounts>{};
  let run = lambda[copy counts]() -> void {
    let domain = HazardDomain.New(1, Allocator.ProcessHeap(0i64, 0i64)).get_if<HazardDomain>()!;
    var holder = domain.TestHolder();
    let object = new arc<HazardTestObject>{value: 13, counts: counts};
    AssertTrue(HazardTestObject.Retire(holder, object).IsOk());
    AssertEqI32(counts.reclaimed.Load(MemoryOrder.Relaxed), 0);
  };
  run();
  AssertEqI32(counts.reclaimed.Load(MemoryOrder.Relaxed), 1);
  AssertEqI32(counts.dropped.Load(MemoryOrder.Relaxed), 1);
}

@test
func test_hazptr_reclaimed_owner_capture_drops_before_collect_returns() {
  let domain = HazardDomain.New(1, Allocator.ProcessHeap(0i64, 0i64)).get_if<HazardDomain>()!;
  var holder = domain.TestHolder();
  let counts = new arc<HazardTestCounts>{};
  // The returned retirement is the sole remaining owner once this frame ends.
  let make = lambda[copy counts]() -> HazardRetirement {
    let object = new arc<HazardTestObject>{value: 14, counts: counts};
    return HazardRetirement{address: object.Address(), reclaim: lambda[copy object]() -> void {
      object.Reclaim();
    }};
  };
  unsafe {
    AssertTrue(holder.TryRetire(make()).IsOk());
  }

  AssertEqI32(counts.dropped.Load(MemoryOrder.Relaxed), 0);
  AssertEqI32(holder.Collect(), 1);
  AssertEqI32(counts.dropped.Load(MemoryOrder.Relaxed), 1);
}

@test
func test_hazptr_reclaim_callback_can_acquire_and_collect_another_record() {
  let domain = HazardDomain.New(2, Allocator.ProcessHeap(0i64, 0i64)).get_if<HazardDomain>()!;
  var holder = domain.TestHolder();
  let counts = new arc<HazardTestCounts>{};
  let object = new arc<HazardTestObject>{value: 15, counts: counts};
  unsafe {
    AssertTrue(holder.TryRetire(HazardRetirement{address: object.Address(), reclaim: lambda[copy domain, copy object]() -> void {
      var other = domain.TestHolder();
      AssertEqI64(domain.Collect(), 0i64);
      object.Reclaim();
    }}).IsOk());
  }

  AssertEqI32(holder.Collect(), 1);
  AssertEqI32(counts.reclaimed.Load(MemoryOrder.Relaxed), 1);
}

@test
func test_hazptr_invalid_and_inactive_retirements_return_their_callbacks() {
  let domain = HazardDomain.New(1, Allocator.ProcessHeap(0i64, 0i64)).get_if<HazardDomain>()!;
  var holder = domain.TestHolder();
  let calls = new arc<Atomic<int32>>{value: 0};
  unsafe {
    var invalid = holder.TryRetire(HazardRetirement{address: 0up, reclaim: lambda[copy calls]() -> void {
      calls.FetchAdd(1, MemoryOrder.Relaxed);
    }});
    var failure = move(invalid.get_if<HazardRetireFailure>()!);
    AssertTrue(failure.kind == HazardError.InvalidArgument);
    AssertEqI32(calls.Load(MemoryOrder.Relaxed), 0);
    failure.retirement.reclaim();
    var inert = HazardHolder{};
    var inactive = inert.TryRetire(HazardRetirement{
      address: (&mut calls.value) as uintptr, reclaim: lambda[copy calls]() -> void {
        calls.FetchAdd(1, MemoryOrder.Relaxed);
      }
    });
    var returned = move(inactive.get_if<HazardRetireFailure>()!);
    AssertTrue(returned.kind == HazardError.Inactive);
    returned.retirement.reclaim();
  }

  AssertEqI32(calls.Load(MemoryOrder.Relaxed), 2);
  AssertEqI32(holder.Pending(), 0);
}

@test
func test_hazptr_same_record_reentrant_retirement_is_rejected_without_losing_ownership() {
  let domain = HazardDomain.New(1, Allocator.ProcessHeap(0i64, 0i64)).get_if<HazardDomain>()!;
  var holder = domain.TestHolder();
  let address = &mut holder;
  let calls = new arc<Atomic<int32>>{value: 0};
  let inner = new arc<Atomic<int32>>{value: 0};
  unsafe {
    AssertTrue(holder.TryRetire(HazardRetirement{
      address: (&mut calls.value) as uintptr,
      reclaim: lambda[copy address, copy calls, copy inner]() -> void {
        unsafe {
          AssertEqI32((*address).Collect(), 0);
          var result = (*address).TryRetire(HazardRetirement{
            address: (&mut inner.value) as uintptr, reclaim: lambda[copy inner]() -> void {
              inner.FetchAdd(1, MemoryOrder.Relaxed);
            }
          });
          var failure = move(result.get_if<HazardRetireFailure>()!);
          AssertTrue(failure.kind == HazardError.Reentrant);
          // The unaccepted object was never published, so the test may reclaim it directly.
          failure.retirement.reclaim();
        }

        calls.FetchAdd(1, MemoryOrder.Relaxed);
      }
    }).IsOk());
  }

  AssertEqI32(holder.Collect(), 1);
  AssertEqI32(calls.Load(MemoryOrder.Relaxed), 1);
  AssertEqI32(inner.Load(MemoryOrder.Relaxed), 1);
  AssertEqI32(holder.Pending(), 0);
}

@test
func test_hazptr_batch_threshold_keeps_protected_survivors_across_buffer_reuse() {
  let domain = HazardDomain.New(2, Allocator.ProcessHeap(0i64, 0i64), retire_threshold: 3).get_if<HazardDomain>()!;
  var reader = domain.TestHolder();
  var writer = domain.TestHolder();
  let counts = new arc<HazardTestCounts>{};
  let held = new arc<HazardTestObject>{value: 16, counts: counts};
  var source = HazardSource.New(held.Address());
  reader.Protect(source);
  source.Store(0up);
  AssertTrue(HazardTestObject.Retire(writer, held).IsOk());
  var index: int32 = 0;
  while index < 10 {
    AssertTrue(HazardTestObject.Retire(writer, new arc<HazardTestObject>{value: index + 1, counts: counts}).IsOk());
    index += 1;
  }

  AssertEqI32(counts.reclaimed.Load(MemoryOrder.Relaxed), 10);
  AssertEqI32(writer.Pending(), 1);
  reader.Reset();
  AssertEqI32(writer.Collect(), 1);
}
