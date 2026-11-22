# Module boundaries and ownership

| Module | State and responsibility | Exclusions |
| --- | --- | --- |
| HazardPublication | Stable atomic address cells, SeqCst publication and comparison | Pointee ownership, protection record admission and destruction |
| HazardReclamation | Explicit domain slab, move-only record leases, protection validation, private retirement batches and deferred owner release | OS threads, TLS, scheduler queues and payload synchronization |

HazardPublication depends only on kernel. HazardReclamation depends on its
public source contract and kernel. The root barrel exports the two public
faces and imports their implementations; no record layout is exported.
Domain, holder and record parts share one TU because they jointly own the
lease/protection/retirement invariant. Records never move after slab creation.

Each holder retains the state but its protection operations use a pinned raw
record pointer without acquiring another strong owner. Claimed-record CAS
uses acquire/release ordering. Return resets its hazard before releasing the
claim. A new lease observes the previous owner's buffer writes. Domain collection
uses the same lease protocol, so it never mutates a live holder's private batch.

Pointer publication, protection stores, validation loads and hazard scans are
sequentially consistent. No payload is dereferenced before publication is
revalidated. Removal happens before retirement and the scan; reuse happens only
after a successful scan excludes every holder. Algorithms must not republish a
retired node or mutate the atomic address field outside HazardSource methods.
This establishes lifetime protection, not a general proof for a client's ABA or
linked-structure algorithm.

Retirement first reserves both batch buffers, then transfers ownership. The
collector detaches the batch before checking hazards and forbids recursive
mutation of that record. Protected entries transfer to the other reserved
buffer. Unprotected callbacks execute and drop their captures before collection
returns its count. Reentry into another record is permitted without a domain
mutex. A callback can keep its own object alive through an ordinary ARC capture
containing move-only fields; the final compiler-generated drop remains the only
owner of typed destruction and allocator-paired deallocation.

The allocator row is copied into managed blocks and buffers; its context remains
borrowed and must outlive all domain and holder handles. Initial allocation and
buffer growth have explicit failure admission. Retired nodes are not raw heap
blocks owned by this library, so there is no public free operation.

The fixed slab makes participant capacity and metadata ownership explicit.
Callers reserve enough slots for every concurrent protection and reentrant
collector they need. Registration is a slab scan; protection reuses a lease.
Scans cost O(retirements * records), use no hazard-snapshot allocation and do not
require stopping or joining readers. Long-held protection and callback capture
cycles can retain memory; a collection call is not a promise of immediate empty
backlog.
