import Foundation

/// A tiny, schema-less protobuf wire-format reader/writer — just enough to talk to the dish
/// without pulling in swift-protobuf + generated code for SpaceX's ~170 KB of descriptors.
/// Field numbers come from the dish's own gRPC reflection service (see docs/dish.protoset).
enum ProtoError: Error {
    case truncated
    case badWireType(Int)
}

enum ProtoValue {
    case varint(UInt64)
    case fixed64(UInt64)
    case bytes([UInt8])
    case fixed32(UInt32)
}

struct ProtoMessage {
    private(set) var fields: [Int: [ProtoValue]] = [:]

    init(_ bytes: [UInt8]) throws {
        var i = 0
        while i < bytes.count {
            let key = try Self.readVarint(bytes, &i)
            let field = Int(key >> 3)
            let value: ProtoValue
            switch Int(key & 7) {
            case 0:
                value = .varint(try Self.readVarint(bytes, &i))
            case 1:
                guard i + 8 <= bytes.count else { throw ProtoError.truncated }
                var v: UInt64 = 0
                for b in 0..<8 { v |= UInt64(bytes[i + b]) << (8 * UInt64(b)) }
                i += 8
                value = .fixed64(v)
            case 2:
                let len = Int(try Self.readVarint(bytes, &i))
                guard len >= 0, i + len <= bytes.count else { throw ProtoError.truncated }
                value = .bytes(Array(bytes[i..<(i + len)]))
                i += len
            case 5:
                guard i + 4 <= bytes.count else { throw ProtoError.truncated }
                var v: UInt32 = 0
                for b in 0..<4 { v |= UInt32(bytes[i + b]) << (8 * UInt32(b)) }
                i += 4
                value = .fixed32(v)
            case let t:
                throw ProtoError.badWireType(t)
            }
            fields[field, default: []].append(value)
        }
    }

    private static func readVarint(_ bytes: [UInt8], _ i: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard i < bytes.count else { throw ProtoError.truncated }
            let b = bytes[i]; i += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw ProtoError.truncated }
        }
    }

    func has(_ n: Int) -> Bool { fields[n] != nil }

    // Scalars: proto3 uses "last one wins".
    func float(_ n: Int) -> Float? {
        if case .fixed32(let v)? = fields[n]?.last { return Float(bitPattern: v) }
        return nil
    }
    func uint(_ n: Int) -> UInt64? {
        if case .varint(let v)? = fields[n]?.last { return v }
        return nil
    }
    func int(_ n: Int) -> Int64? { uint(n).map { Int64(bitPattern: $0) } }
    func int32(_ n: Int) -> Int32? { uint(n).map { Int32(truncatingIfNeeded: $0) } }
    func bool(_ n: Int) -> Bool { (uint(n) ?? 0) != 0 }
    func bytes(_ n: Int) -> [UInt8]? {
        if case .bytes(let b)? = fields[n]?.last { return b }
        return nil
    }
    func string(_ n: Int) -> String? { bytes(n).map { String(decoding: $0, as: UTF8.self) } }
    func message(_ n: Int) -> ProtoMessage? { bytes(n).flatMap { try? ProtoMessage($0) } }

    func strings(_ n: Int) -> [String] {
        (fields[n] ?? []).compactMap {
            if case .bytes(let b) = $0 { return String(decoding: b, as: UTF8.self) }
            return nil
        }
    }

    /// `repeated float` — packed (one length-delimited blob) or unpacked.
    func floats(_ n: Int) -> [Float] {
        var out: [Float] = []
        for v in fields[n] ?? [] {
            switch v {
            case .fixed32(let x):
                out.append(Float(bitPattern: x))
            case .bytes(let b):
                out.reserveCapacity(out.count + b.count / 4)
                var i = 0
                while i + 4 <= b.count {
                    let x = UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24
                    out.append(Float(bitPattern: x))
                    i += 4
                }
            default: break
            }
        }
        return out
    }
}

enum ProtoWriter {
    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }

    /// Encodes `{ <field>: {} }` — every request we send is an empty sub-message in the Request oneof.
    static func emptyMessageField(_ field: Int) -> [UInt8] {
        varint(UInt64(field) << 3 | 2) + [0]
    }
}
