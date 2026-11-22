// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

import "kernel:kernel.ny";

/** @brief Atomic address source paired with HazardHolder.Protect.
 * @note Initialize before publication, keep its address stable and never copy it concurrently.
 *       Addresses are non-owning. A publisher retains each pointee until unlink and successful
 *       retirement in the same domain as its readers. All mutations use these SeqCst operations.
 *       Protection covers lifetime, not concurrent mutation of payload fields or every ABA pattern. */
pub struct HazardSource;

/** @brief Publication cells cannot be duplicated; move them only before sharing. */
pub method(HazardSource) operator copy() -> HazardSource = delete;

/** @brief Initialize an unpublished source; zero represents no pointee.
 * @returns A source value to place at its final stable address before sharing. */
pub static method(HazardSource) New(address: uintptr) -> HazardSource;

/** @brief Observe an address without acquiring lifetime protection.
 * @returns Non-owning address; use a holder before dereferencing a shared pointee. */
pub method(HazardSource) Load() -> uintptr;

/** @brief Publish an address; the publisher separately retains its owner. */
pub method(HazardSource) Store(address: uintptr) -> void;

/** @brief Replace publication and obtain the address to retire after unlinking.
 * @returns Previous non-owning address; this operation does not destroy its pointee. */
pub method(HazardSource) Exchange(address: uintptr) -> uintptr;

/** @brief Conditionally replace publication with the same ordering as protection validation.
 * @returns True on replacement; failure updates expected with the observed address. */
pub method(HazardSource) CompareExchange(expected: ref mut uintptr, desired: uintptr) -> bool;
