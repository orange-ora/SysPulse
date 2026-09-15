import Foundation
import IOKit
import Metal

// 用 Metal 计算负载压 GPU，同时轮询 IOAccelerator，验证利用率是否真实联动。

func gpuUtilization() -> Int? {
    var iterator: io_iterator_t = 0
    guard let matching = IOServiceMatching("IOAccelerator"),
          IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var best: Int?
    var service = IOIteratorNext(iterator)
    while service != 0 {
        var props: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let dict = props?.takeRetainedValue() as? [String: Any],
           let stats = dict["PerformanceStatistics"] as? [String: Any],
           let value = stats["Device Utilization %"] as? Int {
            best = max(best ?? 0, value)
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    return best
}

print("空载 GPU: \(gpuUtilization().map { "\($0)%" } ?? "-")")
Thread.sleep(forTimeInterval: 2)
print("空载 GPU: \(gpuUtilization().map { "\($0)%" } ?? "-")")

guard let device = MTLCreateSystemDefaultDevice() else {
    print("无 Metal 设备，跳过加压测试")
    exit(0)
}
print("Metal 设备: \(device.name)")

let source = """
#include <metal_stdlib>
using namespace metal;
kernel void busy(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float x = float(id) * 1e-7f + 1e-3f;
    for (int i = 0; i < 40000; ++i) { x = sin(x) * 1.0000001f + 1e-7f; }
    out[id % 1024] = x;
}
"""

guard let library = try? device.makeLibrary(source: source, options: nil),
      let function = library.makeFunction(name: "busy"),
      let queue = device.makeCommandQueue(),
      let pipeline = try? device.makeComputePipelineState(function: function),
      let buffer = device.makeBuffer(length: 1024 * 4, options: .storageModePrivate) else {
    print("Metal 管线创建失败，跳过加压测试")
    exit(0)
}

let deadline = Date().addingTimeInterval(6)
var frames = 0
var lastBuffer: MTLCommandBuffer?
while Date() < deadline {
    guard let commandBuffer = queue.makeCommandBuffer(),
          let encoder = commandBuffer.makeComputeCommandEncoder() else { break }
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    let threads = MTLSize(width: 8192, height: 1, depth: 1)
    let group = MTLSize(width: 64, height: 1, depth: 1)
    encoder.dispatchThreads(threads, threadsPerThreadgroup: group)
    encoder.endEncoding()
    commandBuffer.commit()
    lastBuffer = commandBuffer
    frames += 1
    if frames % 8 == 0 {
        print("加压中 GPU: \(gpuUtilization().map { "\($0)%" } ?? "-")")
    }
}
lastBuffer?.waitUntilCompleted()
print("加压结束 GPU: \(gpuUtilization().map { "\($0)%" } ?? "-")")
Thread.sleep(forTimeInterval: 2)
print("恢复后 GPU: \(gpuUtilization().map { "\($0)%" } ?? "-")")
