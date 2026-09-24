import XCTest

final class FreeDPacketEncoderTests: XCTestCase {
    func testPacketLengthAndMarker() {
        let packet = FreeDPacketEncoder.encode(pose: .zero)

        XCTAssertEqual(packet.count, 29)
        XCTAssertEqual(packet.first, 0xD1)
    }

    func testChecksumMatchesFormula() {
        let pose = TrackingPose(
            timestamp: 1.0,
            x: 0.25,
            y: -0.5,
            z: 1.0,
            pitch: 1.0,
            yaw: -1.0,
            roll: 0.5
        )
        let bytes = [UInt8](FreeDPacketEncoder.encode(pose: pose, cameraID: 7, zoom: 1200, focus: 4095))

        let expected = UInt8((0x40 - bytes.prefix(28).reduce(0) { $0 + Int($1) }) & 0xFF)
        XCTAssertEqual(bytes[28], expected)
    }

    func testZeroPoseEncodesNeutralValues() {
        let bytes = [UInt8](FreeDPacketEncoder.encode(pose: .zero))

        XCTAssertEqual(Array(bytes[2...10]), Array(repeating: 0, count: 9))
        XCTAssertEqual(Array(bytes[11...19]), Array(repeating: 0, count: 9))
        XCTAssertEqual(Array(bytes[20...22]), [0x08, 0x00, 0x00])
        XCTAssertEqual(Array(bytes[23...25]), [0x08, 0x00, 0x00])
        XCTAssertEqual(Array(bytes[26...27]), [0x00, 0x00])
    }

    func testRepresentativePositiveAndNegativeValuesEncodeCorrectly() {
        let pose = TrackingPose(
            timestamp: 1.0,
            x: 0.25,
            y: -0.5,
            z: 1.0,
            pitch: 1.0,
            yaw: -1.0,
            roll: 0.5
        )
        let bytes = [UInt8](FreeDPacketEncoder.encode(pose: pose))

        XCTAssertEqual(Array(bytes[2...4]), [0x00, 0x80, 0x00])
        XCTAssertEqual(Array(bytes[5...7]), [0xFF, 0x80, 0x00])
        XCTAssertEqual(Array(bytes[8...10]), [0x00, 0x40, 0x00])

        XCTAssertEqual(Array(bytes[11...13]), [0x00, 0xFA, 0x00])
        XCTAssertEqual(Array(bytes[14...16]), [0xFF, 0x83, 0x00])
        XCTAssertEqual(Array(bytes[17...19]), [0x00, 0x3E, 0x80])
    }

    func testLensOffsetBehavior() {
        let bytes = [UInt8](FreeDPacketEncoder.encode(pose: .zero, zoom: 1200, focus: 4095))

        XCTAssertEqual(Array(bytes[20...22]), [0x08, 0x04, 0xB0])
        XCTAssertEqual(Array(bytes[23...25]), [0x08, 0x0F, 0xFF])
    }
}
