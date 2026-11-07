import Darwin

struct ProcessMemorySnapshot {
    let residentBytes: UInt64
    let physFootprintBytes: UInt64

    static func capture() -> ProcessMemorySnapshot? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        return ProcessMemorySnapshot(
            residentBytes: UInt64(info.resident_size),
            physFootprintBytes: UInt64(info.phys_footprint)
        )
    }

}
