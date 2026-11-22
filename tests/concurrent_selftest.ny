// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

import "stdlib:stdlib.ny";
import "ntest:ntest.ny";
import "hazptr.ny";

struct HazardRaceCounts {
  reclaimed: Atomic<int32>;
  dropped: Atomic<int32>;
}

struct HazardRacePayload {
  sequence: int64;
  inverse: int64;
}

struct HazardRaceOwner {
  payload: HazardRacePayload;
  counts: arc<HazardRaceCounts>;
}

struct HazardRacePublication {
  source: HazardSource;
  stop: Atomic<int32>;
  reads: Atomic<int64>;
  errors: Atomic<int32>;
  ready: Semaphore;
  start: Event;
}

method(HazardRaceOwner) Address() -> uintptr {
  return (&mut self.payload) as uintptr;
}

method(HazardRaceOwner) operator drop() -> void {
  self.counts.dropped.FetchAdd(1, MemoryOrder.Relaxed);
}

static method(HazardRaceOwner) Retirement(owner: arc<HazardRaceOwner>) -> HazardRetirement {
  return HazardRetirement{address: owner.Address(), reclaim: lambda[copy owner]() -> void {
    AssertTrue(owner.payload.inverse == ~owner.payload.sequence);
    owner.counts.reclaimed.FetchAdd(1, MemoryOrder.Relaxed);
  }};
}

method(HazardRacePublication) Read(holder: ref mut HazardHolder) -> bool {
  scope (holder) {
    let address = holder.Protect(self.source);
    if address == 0up {
      return false;
    }

    unsafe {
      let payload = address as *const HazardRacePayload;
      let value = (*payload).sequence;
      if value < 1i64 || (*payload).inverse != ~value {
        self.errors.FetchAdd(1, MemoryOrder.Relaxed);
      }
    }

    self.reads.FetchAdd(1i64, MemoryOrder.Relaxed);
    return true;
  }
}

static method(HazardRaceOwner) Publish(
  domain: HazardDomain, publication: arc<HazardRacePublication>, counts: arc<HazardRaceCounts>
) -> void {
  var acquired = domain.Acquire();
  var writer = move(acquired.get_if<HazardHolder>()!);
  var current = new arc<HazardRaceOwner>{payload: HazardRacePayload{sequence: 1i64, inverse: ~1i64}, counts: counts};
  publication.source.Store(current.Address());
  var reader: int32 = 0;
  while reader < 4 {
    AssertTrue(publication.ready.WaitTimeout(5000u32));
    reader += 1;
  }

  publication.start.Signal();
  var index: int64 = 2i64;
  while index <= 1001i64 {
    let next = new arc<HazardRaceOwner>{
      payload: HazardRacePayload{sequence: index, inverse: ~index}, counts: counts
    };
    AssertTrue(publication.source.Exchange(next.Address()) == current.Address());
    unsafe {
      AssertTrue(writer.TryRetire(HazardRaceOwner.Retirement(current)).IsOk());
    }

    current = next;
    if index % 16i64 == 0i64 {
      Thread.Yield();
    }

    index += 1i64;
  }

  publication.source.Exchange(0up);
  unsafe {
    AssertTrue(writer.TryRetire(HazardRaceOwner.Retirement(current)).IsOk());
  }
}

@test
func test_hazptr_concurrent_replace_protect_read_and_collect() {
  let domain = HazardDomain.New(8, Allocator.ProcessHeap(0i64, 0i64), retire_threshold: 8).get_if<HazardDomain>()!;
  let counts = new arc<HazardRaceCounts>{};
  var ready = Semaphore.New(0u32);
  var start = Event.CreateManual();
  AssertTrue(ready.IsOk() && start.IsOk());
  let publication = new arc<HazardRacePublication>{
    source: HazardSource.New(0up), ready: move(ready.get_if<Semaphore>()!),
    start: move(start.get_if<Event>()!)
  };
  var readers = Array<Thread>.New();
  var index: int32 = 0;
  while index < 4 {
    var spawned = Thread.Spawn(lambda[copy domain, copy publication]() -> void {
      var acquired = domain.Acquire();
      var holder = move(acquired.get_if<HazardHolder>()!);
      while !publication.Read(holder) {
        Thread.Yield();
      }

      publication.ready.Release(1u32);
      publication.start.Wait();
      while publication.stop.Load(MemoryOrder.Acquire) == 0 {
        publication.Read(holder);
      }
    });
    AssertTrue(spawned.IsOk());
    readers.Push(move(spawned.get_if<Thread>()!));
    index += 1;
  }

  var collecting = Thread.Spawn(lambda[copy domain, copy publication]() -> void {
    while publication.stop.Load(MemoryOrder.Acquire) == 0 {
      domain.Collect();
      Thread.Yield();
    }
  });
  AssertTrue(collecting.IsOk());
  var collector = move(collecting.get_if<Thread>()!);
  HazardRaceOwner.Publish(domain, publication, counts);
  publication.stop.Store(1, MemoryOrder.Release);
  index = 0;
  while index < readers.Len() {
    AssertTrue(readers.GetMut(index).Join().IsOk());
    index += 1;
  }

  AssertTrue(collector.Join().IsOk());
  domain.Collect();
  AssertTrue(publication.reads.Load(MemoryOrder.Relaxed) >= 4i64);
  AssertEqI32(publication.errors.Load(MemoryOrder.Relaxed), 0);
  AssertEqI32(counts.reclaimed.Load(MemoryOrder.Relaxed), 1001);
  AssertEqI32(counts.dropped.Load(MemoryOrder.Relaxed), 1001);
}
