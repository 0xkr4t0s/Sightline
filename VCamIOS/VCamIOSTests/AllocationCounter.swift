import Darwin
import Synchronization

private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

private let allocationsOnThread = Atomic<Int>(0)
nonisolated(unsafe) private var countedThread: pthread_t?

/// libmalloc calls `malloc_logger` (the MallocStackLogging hook, exported by libSystem) for every
/// allocation and free; bit 1 of `type` marks an allocation. Only the counted thread's count.
private let countingLogger: MallocLogger = { type, _, _, _, _, _ in
    guard type & 2 != 0, let thread = countedThread, pthread_equal(pthread_self(), thread) != 0 else {
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
    countedThread = pthread_self()
    let before = allocationsOnThread.load(ordering: .relaxed)
    slot.pointee = countingLogger
    body()
    slot.pointee = nil
    countedThread = nil
    return allocationsOnThread.load(ordering: .relaxed) - before
}
