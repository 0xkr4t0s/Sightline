import Darwin
import Synchronization

private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

private let allocationsOnThread = Atomic<Int>(0)
/// The counted thread's `pthread_t` bits; 0 while nothing is counted.
private let countedThread = Atomic<UInt>(0)

/// libmalloc calls `malloc_logger` (the MallocStackLogging hook, exported by libSystem) for every
/// allocation and free on every thread; bit 1 of `type` marks an allocation. Only the counted
/// thread's count.
///
/// The hook runs inside malloc on any thread, so it stays out of the Swift runtime: `Atomic`
/// globals are `let`s, with no dynamic exclusivity checks. (A `var` global cost every allocation
/// on every thread a `swift_beginAccess` in Debug builds, whose per-thread state the runtime may
/// allocate, re-entering this hook. Suspected cause of the iOS 26.5 CI test crash, 2026-09-25.)
private let countingLogger: MallocLogger = { type, _, _, _, _, _ in
    guard type & 2 != 0, UInt(bitPattern: pthread_self()) == countedThread.load(ordering: .relaxed) else {
        return
    }
    allocationsOnThread.add(1, ordering: .relaxed)
}

/// Counts heap allocations (malloc, calloc, realloc, Swift objects and arrays) that the calling
/// thread makes inside `body`. Test-only: it installs a process-wide libmalloc hook for the
/// duration, so it must not run concurrently with itself.
func heapAllocations(_ body: () -> Void) -> Int {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else {
        return -1
    }
    let slot = symbol.assumingMemoryBound(to: Optional<MallocLogger>.self)
    countedThread.store(UInt(bitPattern: pthread_self()), ordering: .relaxed)
    let before = allocationsOnThread.load(ordering: .relaxed)
    slot.pointee = countingLogger
    body()
    slot.pointee = nil
    countedThread.store(0, ordering: .relaxed)
    return allocationsOnThread.load(ordering: .relaxed) - before
}
