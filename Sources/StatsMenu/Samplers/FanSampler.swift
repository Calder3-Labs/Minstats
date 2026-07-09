import IOKit
import PrivateIOKit

struct FanReading {
    let name: String
    let rpm: Double
}

/// Reads fan speeds from the SMC via the AppleSMC user client.
/// Fanless Macs (no "FNum" key or FNum == 0) yield an empty sample.
final class FanSampler {
    private let connection: io_connect_t

    init() {
        var connection: io_connect_t = 0
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if service != 0 {
            if IOServiceOpen(service, mach_task_self_, 0, &connection) != kIOReturnSuccess {
                connection = 0
            }
            IOObjectRelease(service)
        }
        self.connection = connection
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func sample() -> [FanReading] {
        guard let rawCount = readValue("FNum") else { return [] }
        let count = Int(rawCount)
        var fans: [FanReading] = []
        for index in 0..<count {
            guard let rpm = readValue("F\(index)Ac"), (0...20000).contains(rpm) else { continue }
            fans.append(FanReading(name: count == 1 ? "Fan" : "Fan \(index + 1)", rpm: rpm))
        }
        return fans
    }

    private func readValue(_ key: String) -> Double? {
        guard connection != 0 else { return nil }
        let keyCode = Self.fourCC(key)

        var infoInput = SMCParamStruct()
        infoInput.key = keyCode
        infoInput.data8 = UInt8(kSMCGetKeyInfo)
        guard let info = call(&infoInput) else { return nil }

        var readInput = SMCParamStruct()
        readInput.key = keyCode
        readInput.keyInfo.dataSize = info.keyInfo.dataSize
        readInput.data8 = UInt8(kSMCReadKey)
        guard let output = call(&readInput) else { return nil }

        let size = Int(min(info.keyInfo.dataSize, 32))
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        return Self.decode(dataType: info.keyInfo.dataType, bytes: bytes)
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let status = IOConnectCallStructMethod(
            connection, UInt32(kSMCHandleYPCEvent),
            &input, MemoryLayout<SMCParamStruct>.stride,
            &output, &outputSize
        )
        guard status == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private static func decode(dataType: UInt32, bytes: [UInt8]) -> Double? {
        switch dataType {
        case fourCC("ui8 ") where bytes.count >= 1:
            return Double(bytes[0])
        case fourCC("flt ") where bytes.count >= 4:
            var value: Float = 0
            withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes.prefix(4)) }
            return Double(value)
        case fourCC("fpe2") where bytes.count >= 2:
            // Big-endian fixed-point, 2 fractional bits (Intel fan format).
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        default:
            return nil
        }
    }

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
