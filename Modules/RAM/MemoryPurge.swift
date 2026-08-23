//
//  MemoryPurge.swift
//  Memory
//
//  Created for the memory optimizer extension on 23/08/2026.
//  Using Swift 5.0.
//
//  Free, no-root memory reclaim: briefly allocate and immediately free
//  large memory blocks to push the kernel into reclaiming inactive /
//  compressible / cached memory. This is the same technique used by most
//  third-party "memory cleaner" apps and does not require `sudo`.
//

import Foundation
import os.log
import Darwin

public enum MemoryPurgeError: Error, LocalizedError {
    case allocationFailed(atIndex: Int)
    case insufficientFreeMemory(availableBytes: UInt64)
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .allocationFailed(let idx):
            return "Memory allocation failed at block \(idx)."
        case .insufficientFreeMemory(let availableBytes):
            return "Not enough free memory to safely reclaim (\(availableBytes) bytes available)."
        case .alreadyRunning:
            return "A memory reclaim is already in progress."
        }
    }
}

public struct MemoryPurge {
    /// Logger subsystem for the memory optimizer.
    static let log = OSLog(subsystem: "com.stats.memoryoptimizer", category: "MemoryPurge")

    /// Size of a single allocation block (100 MB).
    static let blockSize: UInt64 = 100 * 1024 * 1024

    /// Hard cap on total bytes we ever try to allocate in one pass (~1.5 GB).
    static let maxTotalBytes: UInt64 = 3 * 768 * 1024 * 1024

    private static var running = false

    /// Decide whether a reclaim should be triggered given the current used
    /// bytes and the configured threshold (in bytes).
    ///
    /// - Parameters:
    ///   - usedBytes: currently used physical memory in bytes
    ///   - thresholdBytes: used-memory threshold in bytes; trigger when exceeded
    /// - Returns: `true` if a reclaim should run
    public static func shouldPurge(usedBytes: UInt64, thresholdBytes: UInt64) -> Bool {
        return usedBytes >= thresholdBytes
    }

    /// Reclaim inactive/compressible memory by allocating and immediately
    /// freeing memory blocks. Runs synchronously on the calling thread; call
    /// from a background queue.
    ///
    /// - Parameters:
    ///   - targetBytes: optional cap on total bytes to churn (defaults to `maxTotalBytes`)
    ///   - onProgress: optional callback invoked with the freed bytes count so far
    /// - Throws: `MemoryPurgeError`
    @discardableResult
    public static func purgeInactiveMemory(
        targetBytes: UInt64? = nil,
        onProgress: ((UInt64) -> Void)? = nil
    ) throws -> UInt64 {
        guard !running else { throw MemoryPurgeError.alreadyRunning }
        running = true
        defer { running = false }

        let available = Self.freeMemoryBytes()
        // Do not start if the system is already starved; we need headroom to
        // allocate the reclaim buffers.
        guard available > blockSize * 2 else {
            throw MemoryPurgeError.insufficientFreeMemory(availableBytes: available)
        }

        let total = min(targetBytes ?? maxTotalBytes, maxTotalBytes)
        let blockCount = Int(total / blockSize)

        os_log(.info, log: log, "Starting memory reclaim: %{public}d blocks of %{public}lld bytes", blockCount, blockSize)

        var freed: UInt64 = 0
        for i in 0..<blockCount {
            // During the loop, keep allocating but release the previous block so
            // peak footprint stays around one block. This pattern reliably nudges
            // the kernel to reclaim caches/inactive pages.
            let ptr = malloc(Int(blockSize))
            guard let ptr else {
                running = false
                throw MemoryPurgeError.allocationFailed(atIndex: i)
            }
            // Touch every page so the allocation is actually committed (not lazy).
            memset(ptr, 0, Int(blockSize))
            // Immediately release — this is what frees the pages back to the OS.
            free(ptr)

            freed += blockSize
            onProgress?(freed)
        }

        os_log(.info, log: log, "Memory reclaim finished: %{public}lld bytes churned", freed)
        return freed
    }

    /// Run the system `purge` command via `sudo` (advanced users only, requires
    /// passwordless sudo to be configured). Returns the termination status.
    public static func purgeViaSystemPurge() -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["/usr/sbin/purge"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            os_log(.error, log: log, "system purge failed: %{public}s", error.localizedDescription)
            return -1
        }
    }

    /// Number of currently free bytes, read from `vm_stat`/`host_statistics`.
    public static func freeMemoryBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let pageSize = UInt64(vm_kernel_page_size)
        let kerr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kerr == KERN_SUCCESS else {
            // Fallback: assume a conservative free amount.
            return blockSize * 4
        }
        let freePages = UInt64(stats.free_count)
        let speculative = UInt64(stats.speculative_count)
        return (freePages + speculative) * pageSize
    }
}
