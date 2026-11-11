# ADR-0004: Segregated Coalescing Heap Allocator with Canaries

## Status
ACCEPTED
Date: 2026-11-10
Author: Principal OS Architect

## Context
A production kernel requires dynamic memory allocation for variable-sized data structures (such as process descriptors, VFS nodes, and buffer queues). The allocator must prevent internal and external memory fragmentation, enforce memory safety boundaries, detect double-frees and buffer overruns, and integrate cleanly with Zig's standard allocator interface (`std.mem.Allocator`).

## Decision
1. Implement a segregated, coalescing intrusive linked-list allocator mapped into higher-half virtual memory at base `0xffff900000000000` (up to 64 MiB).
2. Prepend a 32-byte header to every memory chunk containing:
   - Header integrity canary: `0xCAFEBABE`
   - State magic: `0x55534544` (USED) or `0x46524545` (FREE)
   - Block payload size and pointers to adjacent physical blocks (`prev`, `next`)
3. On allocation: search free blocks, split large blocks if remaining size exceeds header plus minimum payload, and mark block as USED. If capacity is insufficient, dynamically map new physical frames from PMM via VMM.
4. On deallocation: verify canary and state magic, mark as FREE, and perform bidirectional coalescing with adjacent free blocks.
5. Provide a compliant Zig `std.mem.Allocator` adapter.

## Alternatives Considered
- **Bump / Arena Allocator**: Rejected because it cannot reclaim or reuse memory on `free()`.
- **Slab / Buddy Allocator**: More complex for initial general-purpose allocation; deferred to a future phase for fixed-size object caches.

## Consequences
### Positive
- Robust bounds checking and instant corruption detection via header canaries.
- Zero external fragmentation on contiguous frees due to bidirectional coalescing.
- Standard Zig allocator interface compatibility.
### Negative / Trade-offs
- 32-byte overhead per allocation chunk.
- O(N) worst-case free-list traversal during allocation if free-list is fragmented.

## Security Implications
Detects underflow and overflow attacks targeting chunk headers. Prevents double-free vulnerabilities and invalid pointer deallocations.

## Testing & Verification Implications
Validated via host unit tests in `tests/unit_test.zig` (allocation, free, coalescing, canary verification, alignment) and in-kernel boot self-tests during QEMU execution.
