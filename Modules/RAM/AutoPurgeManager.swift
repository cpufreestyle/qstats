//
//  AutoPurgeManager.swift
//  Memory
//
//  Created for the memory optimizer extension on 23/08/2026.
//  Using Swift 5.0.
//

import Foundation
import Darwin
import SwiftUI
import os

/// Background manager that periodically checks memory usage and triggers a
/// reclaim when the configured threshold is exceeded, or on a fixed schedule.
public final class AutoPurgeManager: ObservableObject {
    public static let shared = AutoPurgeManager()

    private let queue = DispatchQueue(label: "com.stats.memoryoptimizer.autopurge", qos: .utility)
    private var timer: DispatchSourceTimer?

    // Published state surfaced to the RAM popup UI.
    @Published public var isEnabled: Bool = false
    @Published public var lastPurgeBytes: UInt64 = 0
    @Published public var lastPurgeDate: Date?
    @Published public var statusMessage: String = "未运行"
    @Published public var isBusy: Bool = false

    private var thresholdPercent: Int = 80
    private var useSystemPurge: Bool = false

    private init() {}

    /// Start the background scheduler.
    ///
    /// - Parameters:
    ///   - intervalMinutes: how often to evaluate (minutes)
    ///   - thresholdPercent: used-memory percentage that triggers a reclaim
    ///   - useSystemPurge: advanced — call `sudo purge` instead of the
    ///     no-root allocation technique
    public func start(intervalMinutes: Int, thresholdPercent: Int, useSystemPurge: Bool) {
        stop()
        isEnabled = true
        self.thresholdPercent = max(1, min(99, thresholdPercent))
        self.useSystemPurge = useSystemPurge

        let interval = max(1, TimeInterval(intervalMinutes) * 60)

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in
            self?.evaluateAndPurge()
        }
        source.resume()
        timer = source

        statusMessage = "已启动（每 \(intervalMinutes) 分钟检查，阈值 \(self.thresholdPercent)%）"
        os_log(.info, log: Self.log, "AutoPurgeManager started: interval=%d threshold=%d systemPurge=%d", intervalMinutes, self.thresholdPercent, useSystemPurge ? 1 : 0)
    }

    /// Stop the scheduler.
    public func stop() {
        timer?.cancel()
        timer = nil
        if isEnabled {
            isEnabled = false
            statusMessage = "已停止"
            os_log(.info, log: Self.log, "AutoPurgeManager stopped")
        }
    }

    /// Immediately perform one reclaim (used by the "立即优化" button).
    public func runOnce(thresholdPercent: Int? = nil, useSystemPurge: Bool = false) {
        let t = thresholdPercent.map { max(1, min(99, $0)) } ?? self.thresholdPercent
        let sys = thresholdPercent == nil ? self.useSystemPurge : useSystemPurge
        queue.async { [weak self] in
            guard let self else { return }
            if thresholdPercent != nil {
                self.evaluateAndPurge(thresholdPercent: t, useSystemPurge: sys)
            } else {
                self.performPurge(useSystemPurge: sys)
            }
        }
    }

    // MARK: - Private

    private func evaluateAndPurge(thresholdPercent: Int? = nil, useSystemPurge: Bool? = nil) {
        guard !isBusy else { return }

        let total = Self.totalMemoryBytes()
        guard total > 0 else {
            os_log(.info, log: Self.log, "Cannot read total memory; skipping scheduled evaluation")
            return
        }
        let used = Self.usedMemoryBytes()
        let threshold = thresholdPercent ?? self.thresholdPercent
        let sysPurge = useSystemPurge ?? self.useSystemPurge
        let usedPercent = total > 0 ? Double(used) / Double(total) * 100.0 : 0
        let thresholdBytes = UInt64(Double(total) * Double(threshold) / 100.0)

        os_log(.info, log: Self.log, "Evaluation: used=%d threshold=%d", Int(usedPercent), threshold)

        if MemoryPurge.shouldPurge(usedBytes: used, thresholdBytes: thresholdBytes) {
            performPurge(useSystemPurge: sysPurge)
        } else {
            DispatchQueue.main.async {
                self.statusMessage = "内存占用 \(Int(usedPercent))%，未达阈值"
            }
        }
    }

    private func performPurge(useSystemPurge: Bool) {
        guard !isBusy else { return }
        isBusy = true
        DispatchQueue.main.async {
            self.statusMessage = "正在优化内存…"
        }

        let freed: UInt64
        if useSystemPurge {
            let status = MemoryPurge.purgeViaSystemPurge()
            freed = status == 0 ? MemoryPurge.freeMemoryBytes() : 0
            os_log(.info, log: Self.log, "system purge exit status=%d", status)
        } else {
            do {
                freed = try MemoryPurge.purgeInactiveMemory(onProgress: nil)
            } catch {
                freed = 0
                os_log(.error, log: Self.log, "purge failed: %{public}s", error.localizedDescription)
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.statusMessage = "优化失败：\(error.localizedDescription)"
                }
                return
            }
        }

        DispatchQueue.main.async {
            self.isBusy = false
            self.lastPurgeBytes = freed
            self.lastPurgeDate = Date()
            let mb = Double(freed) / (1024 * 1024)
            self.statusMessage = freed > 0 ? String(format: "已释放 %.0f MB", mb) : "已执行优化"
        }
    }

    // MARK: - Memory read helpers (mirrors Stats' UsageReader)

    private static func totalMemoryBytes() -> UInt64 {
        var stats = host_basic_info()
        var count = UInt32(MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_info(mach_host_self(), HOST_BASIC_INFO, $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return UInt64(stats.max_mem)
    }

    private static func usedMemoryBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let speculative = UInt64(stats.speculative_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let purgeable = UInt64(stats.purgeable_count) * pageSize
        let external = UInt64(stats.external_page_count) * pageSize
        let used = active + inactive + speculative + wired + compressed - purgeable - external
        return used
    }

    static let log = OSLog(subsystem: "com.stats.memoryoptimizer", category: "AutoPurgeManager")
}
