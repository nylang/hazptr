// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

part of HazardReclamation;

pub method(HazardHolder) operator copy() -> HazardHolder = delete;

method(HazardHolder) operator move() -> HazardHolder {
  assert(!self.scoped);
  let state = move(self.state);
  let record = self.record;
  self.record = nil;

  return HazardHolder{state: move(state), record: record};
}

method(HazardHolder) operator drop() -> void {
  if self.state != nil {
    self.Reset();
    unsafe {
      (*self.record).claimed.Store(0, MemoryOrder.Release);
    }
  }
}

/** @brief Load, publish protection and revalidate until the source agrees.
 * @returns Protected address or zero. Protection lasts until reset, replacement, exit or drop.
 * @note Uses atomic operations only: no allocation, mutex, ARC acquisition or registration.
 *       The source's writers must use HazardSource operations and the same reclamation domain. */
pub method(HazardHolder) Protect(source: ref HazardSource) -> uintptr {
  assert(self.state != nil);
  unsafe {
    var address = source.Load();
    while true {
      (*self.record).protected_address.Store(address, MemoryOrder.SeqCst);
      let observed = source.Load();
      if observed == address {
        return address;
      }

      address = observed;
    }
  }
}

/** @brief Stop protecting the current address; it may be reclaimed immediately afterward. */
pub method(HazardHolder) Reset() -> void {
  if self.state != nil {
    unsafe {
      (*self.record).protected_address.Store(0up, MemoryOrder.SeqCst);
    }
  }
}

/** @brief Begin a protection region; the same holder must not have nested active scopes. */
pub method(HazardHolder) Enter() -> void {
  assert(!self.scoped && self.state != nil);
  self.scoped = true;
  self.Reset();
}

/** @brief End a protection region while retaining the reusable record lease. */
pub method(HazardHolder) Exit() -> void {
  self.Reset();
  self.scoped = false;
}

/** @brief Preallocate both retirement buffers before an algorithm unlinks a node.
 * @returns Ok, InvalidArgument, Inactive, Reentrant, CapacityOverflow or OutOfMemory.
 * @note Capacity is a total entry reservation. Failure preserves all accepted retirements.
 *       With distinct retired addresses, max(records + 1, retire_threshold) entries
 *       cover a collect-on-threshold batch and its protected survivors. This permits
 *       worker initialization to remove retirement-buffer growth from queue hot paths. */
pub method(HazardHolder) TryReserveRetirements(capacity: int32) -> Result<Unit, HazardError> {
  if self.state == nil {
    return HazardError.Inactive;
  }

  if capacity < 0 {
    return HazardError.InvalidArgument;
  }

  unsafe {
    if (*self.record).collecting {
      return HazardError.Reentrant;
    }

    var error = (*self.record).retired.TryReserve(capacity).get_if<CollectionError>();
    if error == nil {
      error = (*self.record).scratch.TryReserve(capacity).get_if<CollectionError>();
    }

    if error != nil {
      return error as CollectionError == CollectionError.CapacityOverflow
        ? HazardError.CapacityOverflow : HazardError.OutOfMemory;
    }
  }

  return UnitValue();
}

/** @brief Accept ownership of a valid retirement and collect when its batch reaches the threshold.
 * @returns Ok after acceptance or the entire unaccepted input on failure.
 * @note Address is nonzero and already unlinked from all sources in this domain. Reclamation
 *       may run inline and on another thread after this holder drops. Callers synchronize
 *       mutable payloads separately. A callback cannot retire recursively through this holder. */
pub unsafe method(HazardHolder) TryRetire(retirement: HazardRetirement) -> Result<Unit, HazardRetireFailure> {
  if self.state == nil || retirement.address == 0up {
    let kind = self.state == nil ? HazardError.Inactive : HazardError.InvalidArgument;
    return HazardRetireFailure{kind: kind, retirement: move(retirement)};
  }

  let state = self.state as arc<HazardState>;
  unsafe {
    let record = self.record;
    let count = (*record).retired.Len();
    var error: HazardError? = HazardError.CapacityOverflow;
    if count < kInt32Max {
      error = self.TryReserveRetirements(count + 1).get_if<HazardError>();
    }

    if error != nil {
      return HazardRetireFailure{kind: error as HazardError, retirement: move(retirement)};
    }

    (*record).retired.Push(move(retirement));
    if (*record).retired.Len() >= state.threshold {
      (*record).Collect(state);
    }
  }

  return UnitValue();
}

/** @brief Scan this holder's batch and invoke only unprotected retirements.
 * @returns Number reclaimed. Reentrant collection of the same record returns zero.
 * @note Scan and callback cost belongs to the retiring thread, not protection readers. */
pub method(HazardHolder) Collect() -> int32 {
  if self.state == nil {
    return 0;
  }

  let state = self.state as arc<HazardState>;
  unsafe {
    return (*self.record).Collect(state);
  }
}

/** @brief Read this holder's retained retirement count, or zero when inactive.
 * @returns Thread-confined count; no global statistics scan is performed. */
pub method(HazardHolder) Pending() -> int32 {
  if self.state == nil {
    return 0;
  }

  unsafe {
    return (*self.record).retired.Len();
  }
}
