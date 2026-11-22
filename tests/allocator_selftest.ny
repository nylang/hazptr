// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

import "stdlib:stdlib.ny";
import "ntest:ntest.ny";
import "hazptr.ny";

// The context stays on this test's stack until every domain/lease has dropped.
struct HazardTestAllocator {
  upstream: Allocator;
  reject: bool;
  allocations: int32;
  deallocations: int32;
  fail_after: int32;
}

// nyra-lint-allow: prefer-type-owned-functions -- Capture-free Allocator ABI entry for the caller-owned test context.
func hazard_test_allocate(ctx: *mut uint8, size: uintptr, align: uintptr) -> *mut uint8 {
  unsafe {
    let state = ctx as *mut HazardTestAllocator;
    if (*state).reject || ((*state).fail_after > 0 && (*state).allocations >= (*state).fail_after) {
      return nil;
    }

    (*state).allocations += 1;
    return (*state).upstream.Alloc(size, align: align);
  }
}

// nyra-lint-allow: prefer-type-owned-functions -- Capture-free Allocator ABI entry for the caller-owned test context.
func hazard_test_deallocate(
  ctx: *mut uint8, address: *mut uint8, size: uintptr, align: uintptr
) -> void {
  unsafe {
    let state = ctx as *mut HazardTestAllocator;
    (*state).deallocations += 1;
    (*state).upstream.Dealloc(address, size: size, align: align);
  }
}

// nyra-lint-allow: prefer-type-owned-functions -- Capture-free Allocator ABI entry for the caller-owned test context.
func hazard_test_resize(
  ctx: *mut uint8, address: *mut uint8, old_size: uintptr, old_align: uintptr,
  new_size: uintptr, new_align: uintptr
) -> *mut uint8 {
  // Domain buffers use checked allocate/move/drop, not a realloc fast path.
  return nil;
}

method(HazardTestAllocator) Adapter() -> Allocator {
  return Allocator.FromSlots(hazard_test_allocate, hazard_test_deallocate,
    hazard_test_resize, (&mut self) as *mut uint8);
}

@test
func test_hazptr_record_slab_allocation_failure_is_reported() {
  var context = HazardTestAllocator{upstream: Allocator.ProcessHeap(0i64, 0i64), reject: true};
  AssertTrue(HazardDomain.New(1, context.Adapter()).get_if<HazardError>()! == HazardError.OutOfMemory);
}

@test
func test_hazptr_state_allocation_failure_releases_the_record_slab() {
  var context = HazardTestAllocator{upstream: Allocator.ProcessHeap(0i64, 0i64), fail_after: 1};
  AssertTrue(HazardDomain.New(1, context.Adapter()).get_if<HazardError>()! == HazardError.OutOfMemory);
  AssertEqI32(context.allocations, 1);
  AssertEqI32(context.deallocations, 1);
}

static method(HazardTestAllocator) VerifyRetirementFailure(fail_second: bool) -> void {
  var context = HazardTestAllocator{upstream: Allocator.ProcessHeap(0i64, 0i64)};
  let domain = HazardDomain.New(1, context.Adapter()).get_if<HazardDomain>()!;
  var acquired = domain.Acquire();
  var holder = move(acquired.get_if<HazardHolder>()!);
  let calls = new arc<Atomic<int32>>{value: 0};
  context.reject = !fail_second;
  if fail_second {
    context.fail_after = context.allocations + 1;
  }

  unsafe {
    var result = holder.TryRetire(HazardRetirement{
      address: (&mut calls.value) as uintptr, reclaim: lambda[copy calls]() -> void {
        calls.FetchAdd(1, MemoryOrder.Relaxed);
      }
    });
    AssertTrue(result.IsErr());
    var failure = move(result.get_if<HazardRetireFailure>()!);
    AssertTrue(failure.kind == HazardError.OutOfMemory);
    AssertEqI32(holder.Pending(), 0);
    AssertEqI32(calls.Load(MemoryOrder.Relaxed), 0);
    context.reject = false;
    context.fail_after = 0;
    AssertTrue(holder.TryRetire(move(failure.retirement)).IsOk());
  }

  AssertEqI32(holder.Collect(), 1);
  AssertEqI32(calls.Load(MemoryOrder.Relaxed), 1);
}

@test
func test_hazptr_failed_retirement_returns_callback_ownership_for_retry() {
  HazardTestAllocator.VerifyRetirementFailure(false);
}

@test
func test_hazptr_second_buffer_failure_preserves_unaccepted_retirement() {
  HazardTestAllocator.VerifyRetirementFailure(true);
}

@test
func test_hazptr_reused_protection_path_performs_no_allocator_calls() {
  var context = HazardTestAllocator{upstream: Allocator.ProcessHeap(0i64, 0i64)};
  let domain = HazardDomain.New(1, context.Adapter()).get_if<HazardDomain>()!;
  var acquired = domain.Acquire();
  var holder = move(acquired.get_if<HazardHolder>()!);
  var payload: int32 = 42;
  var source = HazardSource.New((&mut payload) as uintptr);
  let before = context.allocations;
  context.reject = true;
  var index: int32 = 0;
  while index < 100000 {
    scope (holder) {
      let address = holder.Protect(source);
      unsafe {
        AssertEqI32(*(address as *const int32), 42);
      }
    }

    index += 1;
  }

  AssertEqI32(context.allocations, before);
}

@test
func test_hazptr_reserved_retirement_batch_needs_no_buffer_allocation() {
  var context = HazardTestAllocator{upstream: Allocator.ProcessHeap(0i64, 0i64)};
  let domain = HazardDomain.New(1, context.Adapter()).get_if<HazardDomain>()!;
  var acquired = domain.Acquire();
  var holder = move(acquired.get_if<HazardHolder>()!);
  AssertTrue(holder.TryReserveRetirements(8).IsOk());
  AssertTrue(holder.TryReserveRetirements(-1).get_if<HazardError>()! == HazardError.InvalidArgument);
  let calls = new arc<Atomic<int32>>{value: 0};
  var payloads: owned <int32>[] = new <int32>[8];
  let before = context.allocations;
  context.reject = true;
  var index: int32 = 0;
  while index < 8 {
    unsafe {
      AssertTrue(holder.TryRetire(HazardRetirement{
        address: (&mut payloads[index]) as uintptr, reclaim: lambda[copy calls]() -> void {
          calls.FetchAdd(1, MemoryOrder.Relaxed);
        }
      }).IsOk());
    }

    index += 1;
  }

  AssertEqI32(holder.Collect(), 8);
  AssertEqI32(calls.Load(MemoryOrder.Relaxed), 8);
  AssertEqI32(context.allocations, before);
}
