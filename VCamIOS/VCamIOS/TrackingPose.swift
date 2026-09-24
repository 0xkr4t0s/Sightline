import Foundation
import simd

struct TrackingPose: Equatable {
    let timestamp: TimeInterval
    let x: Double
    let y: Double
    let z: Double
    let pitch: Double
    let yaw: Double
    let roll: Double

    static let zero = TrackingPose(
        timestamp: 0,
        x: 0,
        y: 0,
        z: 0,
        pitch: 0,
        yaw: 0,
        roll: 0
    )

    nonisolated init(
        timestamp: TimeInterval,
        x: Double,
        y: Double,
        z: Double,
        pitch: Double,
        yaw: Double,
        roll: Double
    ) {
        self.timestamp = timestamp
        self.x = x
        self.y = y
        self.z = z
        self.pitch = pitch
        self.yaw = yaw
        self.roll = roll
    }

    nonisolated init(cameraTransform transform: simd_float4x4, timestamp: TimeInterval) {
        let translation = transform.columns.3
        let quaternion = simd_quatf(transform)

        let qx = Double(quaternion.imag.x)
        let qy = Double(quaternion.imag.y)
        let qz = Double(quaternion.imag.z)
        let qw = Double(quaternion.real)

        let sinPitch = 2.0 * (qw * qx + qy * qz)
        let cosPitch = 1.0 - 2.0 * (qx * qx + qy * qy)
        let pitchRadians = atan2(sinPitch, cosPitch)

        let sinYaw = 2.0 * (qw * qy - qz * qx)
        let yawRadians: Double
        if abs(sinYaw) >= 1.0 {
            yawRadians = copysign(.pi / 2.0, sinYaw)
        } else {
            yawRadians = asin(sinYaw)
        }

        let sinRoll = 2.0 * (qw * qz + qx * qy)
        let cosRoll = 1.0 - 2.0 * (qy * qy + qz * qz)
        let rollRadians = atan2(sinRoll, cosRoll)

        self.init(
            timestamp: timestamp,
            x: Double(translation.x),
            y: Double(translation.y),
            z: Double(translation.z),
            pitch: pitchRadians * 180.0 / .pi,
            yaw: yawRadians * 180.0 / .pi,
            roll: rollRadians * 180.0 / .pi
        )
    }
}
