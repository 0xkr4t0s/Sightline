import Foundation

nonisolated enum FreeDPacketEncoder {
    static let marker: UInt8 = 0xD1
    static let packetLength = 29
    static let rotationDivisor = 32768.0
    static let positionDivisor = 64.0
    static let millimetersPerMeter = 1000.0
    static let lensOffset: UInt32 = 524288

    static func encode(
        pose: TrackingPose,
        cameraID: UInt8 = 0,
        zoom: UInt16 = 0,
        focus: UInt16 = 0
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: packetLength)
        bytes[0] = marker
        bytes[1] = cameraID

        encodeSigned24(Int32(pose.pitch * rotationDivisor), into: &bytes, at: 2)
        encodeSigned24(Int32(pose.yaw * rotationDivisor), into: &bytes, at: 5)
        encodeSigned24(Int32(pose.roll * rotationDivisor), into: &bytes, at: 8)

        encodeSigned24(Int32(pose.z * millimetersPerMeter * positionDivisor), into: &bytes, at: 11)
        encodeSigned24(Int32(pose.y * millimetersPerMeter * positionDivisor), into: &bytes, at: 14)
        encodeSigned24(Int32(pose.x * millimetersPerMeter * positionDivisor), into: &bytes, at: 17)

        encodeUnsigned24(UInt32(zoom) + lensOffset, into: &bytes, at: 20)
        encodeUnsigned24(UInt32(focus) + lensOffset, into: &bytes, at: 23)

        bytes[28] = checksum(for: bytes)
        return Data(bytes)
    }

    static func checksum(for bytes: [UInt8]) -> UInt8 {
        let sum = bytes.prefix(28).reduce(0) { partialResult, byte in
            partialResult + UInt32(byte)
        }
        return UInt8((0x40 &- sum) & 0xFF)
    }

    private static func encodeSigned24(_ value: Int32, into bytes: inout [UInt8], at offset: Int) {
        let clamped = min(max(value, -0x800000), 0x7FFFFF)
        let encoded = clamped < 0 ? clamped + 0x1000000 : clamped

        bytes[offset] = UInt8((encoded >> 16) & 0xFF)
        bytes[offset + 1] = UInt8((encoded >> 8) & 0xFF)
        bytes[offset + 2] = UInt8(encoded & 0xFF)
    }

    private static func encodeUnsigned24(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        let clamped = min(value, 0xFFFFFF)
        bytes[offset] = UInt8((clamped >> 16) & 0xFF)
        bytes[offset + 1] = UInt8((clamped >> 8) & 0xFF)
        bytes[offset + 2] = UInt8(clamped & 0xFF)
    }
}
