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

pub method(HazardHolder) Reset() -> void {
  if self.state != nil {
    unsafe {
      (*self.record).protected_address.Store(0up, MemoryOrder.SeqCst);
    }
  }
}

pub method(HazardHolder) Enter() -> void {
  assert(!self.scoped && self.state != nil);
  self.scoped = true;
  self.Reset();
}

pub method(HazardHolder) Exit() -> void {
  self.Reset();
  self.scoped = false;
}

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

pub method(HazardHolder) Collect() -> int32 {
  if self.state == nil {
    return 0;
  }

  let state = self.state as arc<HazardState>;
  unsafe {
    return (*self.record).Collect(state);
  }
}

pub method(HazardHolder) Pending() -> int32 {
  if self.state == nil {
    return 0;
  }

  unsafe {
    return (*self.record).retired.Len();
  }
}
