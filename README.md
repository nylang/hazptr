# hazptr

MIT-licensed explicit hazard-pointer reclamation for Nyra. Import
`hazptr:hazptr.ny`. The core uses public kernel atomics, language-owned storage
and an injected allocator. There is no native bridge, OS mutex, global domain,
TLS dependency or background collector. See [module contracts](ARCHITECTURE.md)
and [source installation](INSTALL.md).

## Protection and retirement

Create `HazardDomain.New(records, allocator, retire_threshold: 64)` and check its
result. `records` sets simultaneous holder capacity explicitly. It is not a
limit on thread identities or retired objects. `Acquire()` returns a move-only
`HazardHolder`; retain one per active protection slot and reuse it across reads.
Multiple simultaneous pointers need multiple holders. `NoRecords` is visible
admission failure, not an implicit resize or a blocked registration.

Place each `HazardSource` at a stable address before sharing it. Publishers keep
the pointee's language owner alive. Its Load/Store/Exchange/CompareExchange
operations use the same SeqCst protocol as protection and scanning. A source
cannot be copied. A raw `Load()` does not protect a pointee.

```nyra
// holder is an acquired HazardHolder; source is a stable HazardSource.
scope (holder) {
  let address = holder.Protect(source);
  if address != 0up {
    unsafe {
      // Read the protected payload using its actual pointer type.
    }
  }
} // Reset protection, including on return, break or continue.
```

Protect loads an address, publishes it in the holder's record, then reloads the
source and retries if it changed. It performs no allocation, mutex acquisition,
record registration or ARC owner acquisition. Protection remains until Reset,
replacement by another Protect, scope exit or holder drop. Do not nest scopes
on one holder, move a holder while scoped, or share a holder concurrently.

After unlinking every publication route, transfer a move-only
`HazardRetirement{address, reclaim}` to `holder.TryRetire` inside `unsafe`.
The callback must retain the original language owner until reclamation; releasing
its captures then performs ordinary typed drop with the allocation's paired
allocator. Retire exactly once. Do not free or reuse a retired node directly.
The [complete consumer](tests/data/consumer.ny.in) demonstrates ownership transfer,
protected dereference, unlinking, deferred reclamation and final destruction.

For language-owned node slabs, `HazardRetirement.WithContext(address, context,
named_callback)` records a borrowed context and passes both addresses to a
capture-free callback. The slab owner must outlive every retirement, including
final domain destruction. This avoids per-retirement closure allocation; it
does not transfer or reconstruct allocation ownership.

Every failed retirement returns `HazardRetireFailure{kind, retirement}`. Keep
that retirement for retry: dropping an unaccepted callback may release an object
still being read. Configuration, exhaustion, OOM, capacity overflow, inactive
holders and same-record reentry have distinct error cases.

## Collection and progress

Each record owns a private retirement batch and a reusable scan buffer. Both
buffers reserve space before admission, so an allocation failure cannot strand
an accepted owner. Reaching `retire_threshold` scans the local batch; protected
survivors remain for a later scan. The threshold is a collection trigger, not a
maximum backlog. Reclamation order is unspecified.

`holder.TryReserveRetirements(capacity)` can warm both buffers before a queue
unlinks nodes. For distinct retired addresses, reserving
`max(records + 1, retire_threshold)` entries covers the batch plus protected
survivors under collect-on-threshold admission. Queue workers can therefore
avoid buffer allocation after committing a dequeue. Creating a caller's
ownership-bearing callback may still allocate independently.

`holder.Collect()` scans its own batch. `domain.Collect()` temporarily leases
unowned records and collects their abandoned batches without waiting for active
holders. Active owners collect their own batches; a global Collect is not a
quiescence barrier. Holder drop resets protection and returns its record without
waiting. A later acquisition reuses and scans that record's retained batch.

Live holders retain the domain. Last-state destruction invokes remaining
callbacks after all holders are gone. Callbacks run outside domain locks and
may reenter other records. Same-record collection returns zero while collecting;
same-record retirement returns its input with Reentrant. Callbacks must be safe
on any reclaiming thread. Capture cycles involving the same domain require an
explicit collection while a public handle is alive.

Reader protection is allocation-free; the complete domain is not advertised as
wait-free or entirely lock-free. Registration scans the fixed slab. Retirement
may grow buffers and execute destructors. A scan checks every protection record
for each retired address. Ordinary allocator/runtime work retains its own
progress properties. A stalled reader can retain its protected object.

## Boundaries and development

Hazard pointers protect lifetime. They do not synchronize mutable payload fields,
solve arbitrary logical ABA, supply a queue, or provide a task scheduler. Fixed
ring storage does not itself need node reclamation. A linked MPMC queue must
protect its head/tail/successor as required by its algorithm, validate links and
transfer payload ownership only after winning the relevant atomic operation.

Run `nyrac test . -O0` and `-O2` with a matching SDK and task-owned external
output directory. Tests include parallel readers, a replacing writer and a
concurrent collector, owner destruction, failure preservation and allocation-free
protection. Source consumers must declare hazptr in their package dependencies.
See [scripts/ci.py](scripts/ci.py) for isolated SDK-based checks and cleanup.
Freestanding and other-host runtime qualification remain separate.

Algorithm references: [WG21's hazard-pointer proposal](https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2023/p2530r3.pdf)
and [Folly's usage contracts](https://github.com/facebook/folly/blob/main/folly/docs/Hazptr.md).
This is an independent Nyra implementation, not a Folly binding or source port.
