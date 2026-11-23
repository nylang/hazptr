// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

import "kernel:kernel.ny";
import "interface/source.ni";

/** @brief Domain configuration, lease availability and retirement admission failures. */
pub enum HazardError {
  InvalidArgument,
  NoRecords,
  OutOfMemory,
  CapacityOverflow,
  Inactive,
  Reentrant
}

/** @brief Address/context reclamation slot; a named callback needs no environment allocation. */
pub typedef HazardReclaimFn = (uintptr, *mut uint8) -> void;

/** @brief An unlinked address paired with ownership-bearing deferred reclamation.
 * @note The callback retains the object's language owner until invoked and released. It must
 *       reclaim only this retirement, be thread safe, and not throw or block indefinitely.
 *       Retire each object exactly once, after removing all publication routes in its domain.
 *       Never destroy the object directly while protected. Reclamation order is unspecified. */
pub struct HazardRetirement {
  address: uintptr;
  reclaim:() -> void;
  context: *mut uint8;
  reclaim_address: HazardReclaimFn;
  contextual: bool;
}

/** @brief Construct a retirement using an address/context callback.
 * @returns Move-only deferred action; a named callback does not allocate a capture environment.
 * @note The caller pins context and pointee storage until reclamation, including domain final
 *       destruction. This borrows context; it does not invent or recover allocation ownership. */
pub static method(HazardRetirement) WithContext(
  address: uintptr, context: *mut uint8, reclaim: HazardReclaimFn
) -> HazardRetirement;

/** @brief A retirement transfers its callback owner once; duplication is forbidden. */
pub method(HazardRetirement) operator copy() -> HazardRetirement = delete;

/** @brief Failure returning the complete unaccepted retirement, including its owner.
 * @note Preserve it for retry; dropping it may release the owner while readers still use it. */
pub struct HazardRetireFailure {
  kind: HazardError;
  retirement: HazardRetirement;
}

/** @brief Copyable explicit owner of stable protection records and deferred retirements.
 * @note No global domain, TLS, OS synchronization or background collector. Live holders retain
 *       the domain. Last-state drop invokes remaining callbacks after every holder is gone.
 *       Callback capture cycles require an explicit Collect while a domain handle is live. */
pub struct HazardDomain;

/** @brief Allocate a caller-sized record slab; no hidden maximum participant count.
 * @param records Positive maximum number of simultaneously live holders, including collectors.
 * @param retire_threshold Positive batch trigger; protected survivors may exceed it.
 * @param allocator Allocator row copied into managed allocations and retirement buffers;
 *        its borrowed context must outlive all holders and final reclamation.
 * @returns Domain, InvalidArgument or OutOfMemory after checking metadata allocation.
 * @note Buffer growth during retirement is checked and returns unaccepted ownership on OOM. */
pub static method(HazardDomain) New(
  records: int32, allocator: Allocator, { retire_threshold: int32 = 64 }
) -> Result<HazardDomain, HazardError>;

/** @brief Lease one reusable thread-confined record; registration does not affect existing readers.
 * @returns Move-only holder or NoRecords; an inert domain returns Inactive.
 * @note Reuses retired storage from the previous lease and may reclaim its safe entries. */
pub method(HazardDomain) Acquire() -> Result<HazardHolder, HazardError>;

/** @brief Collect retirements from currently unleased records without waiting for active holders.
 * @returns Number reclaimed by this call. Active holders collect their own batches.
 * @note Safe with concurrent registration and collection. Callbacks execute without a domain lock. */
pub method(HazardDomain) Collect() -> int64;

/** @brief Read configured simultaneous-holder capacity, or zero for an inert domain.
 * @returns Record capacity; not a reservation. */
pub method(HazardDomain) Capacity() -> int32;

/** @brief Move-only, reusable protection record; methods require one thread at a time.
 * @note A holder protects one address at a time. Reset, scope exit and drop end protection.
 *       Drop returns the record without blocking; surviving retirements stay domain-owned.
 *       Keep every source and its owning structure alive through Protect's validation loop. */
@scoped pub struct HazardHolder;

/** @brief A protection lease cannot be duplicated. */
pub method(HazardHolder) operator copy() -> HazardHolder = delete;

/** @brief Load, publish protection and revalidate until the source agrees.
 * @returns Protected address or zero. Protection lasts until reset, replacement, exit or drop.
 * @note Uses atomic operations only: no allocation, mutex, ARC acquisition or registration.
 *       The source's writers must use HazardSource operations and the same reclamation domain. */
pub method(HazardHolder) Protect(source: ref HazardSource) -> uintptr;

/** @brief Stop protecting the current address; it may be reclaimed immediately afterward. */
pub method(HazardHolder) Reset() -> void;

/** @brief Begin a protection region; the same holder must not have nested active scopes. */
pub method(HazardHolder) Enter() -> void;

/** @brief End a protection region while retaining the reusable record lease. */
pub method(HazardHolder) Exit() -> void;

/** @brief Preallocate both retirement buffers before an algorithm unlinks a node.
 * @returns Ok, InvalidArgument, Inactive, Reentrant, CapacityOverflow or OutOfMemory.
 * @note Capacity is a total entry reservation. Failure preserves all accepted retirements.
 *       With distinct retired addresses, max(records + 1, retire_threshold) entries
 *       cover a collect-on-threshold batch and its protected survivors. This permits
 *       worker initialization to remove retirement-buffer growth from queue hot paths. */
pub method(HazardHolder) TryReserveRetirements(capacity: int32) -> Result<Unit, HazardError>;

/** @brief Accept ownership of a valid retirement and collect when its batch reaches the threshold.
 * @returns Ok after acceptance or the entire unaccepted input on failure.
 * @note Address is nonzero and already unlinked from all sources in this domain. Reclamation
 *       may run inline and on another thread after this holder drops. Callers synchronize
 *       mutable payloads separately. A callback cannot retire recursively through this holder. */
pub unsafe method(HazardHolder) TryRetire(retirement: HazardRetirement) -> Result<Unit, HazardRetireFailure>;

/** @brief Scan this holder's batch and invoke only unprotected retirements.
 * @returns Number reclaimed. Reentrant collection of the same record returns zero.
 * @note Scan and callback cost belongs to the retiring thread, not protection readers. */
pub method(HazardHolder) Collect() -> int32;

/** @brief Read this holder's retained retirement count, or zero when inactive.
 * @returns Thread-confined count; no global statistics scan is performed. */
pub method(HazardHolder) Pending() -> int32;
