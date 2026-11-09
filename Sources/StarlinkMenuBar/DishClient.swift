import Foundation

/// Talks to the dish's local gRPC-Web endpoint (the same one the Starlink web UI at
/// http://192.168.100.1 uses). gRPC-Web runs over plain HTTP/1.1, so URLSession is enough —
/// no HTTP/2 gRPC stack required. Native gRPC is also on :9200 if you prefer grpc-swift.
struct DishClient: Sendable {
    var host = "192.168.100.1"
    var port = 9201

    enum ClientError: Error, LocalizedError {
        case unreachable(String)
        case http(Int)
        case grpc(Int, String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .unreachable(let s): "Dish unreachable: \(s)"
            case .http(let c): "HTTP \(c) from dish"
            case .grpc(let c, let m): "gRPC status \(c): \(m)"
            case .malformed(let s): "Malformed response: \(s)"
            }
        }
    }

    // Request oneof field numbers (SpaceX.API.Device.Request)
    private static let reqGetStatus = 1004
    private static let reqObstructionMap = 2008
    // Response oneof field numbers (SpaceX.API.Device.Response)
    private static let respDishGetStatus = 2004
    private static let respObstructionMap = 2008

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 6
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    func getStatus() async throws -> DishStatus {
        let resp = try await handle(requestField: Self.reqGetStatus)
        guard let msg = resp.message(Self.respDishGetStatus) else {
            throw ClientError.malformed("no dish_get_status in response (is this a router, not a dish?)")
        }
        return DishStatus(msg)
    }

    func getObstructionMap() async throws -> ObstructionMap {
        let resp = try await handle(requestField: Self.reqObstructionMap)
        guard let msg = resp.message(Self.respObstructionMap) else {
            throw ClientError.malformed("no dish_get_obstruction_map in response")
        }
        return ObstructionMap(msg)
    }

    private func handle(requestField: Int) async throws -> ProtoMessage {
        let payload = ProtoWriter.emptyMessageField(requestField)
        var body = Data([0x00])                                   // gRPC-Web frame: flags = data
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { body.append(contentsOf: $0) }
        body.append(contentsOf: payload)

        var req = URLRequest(url: URL(string: "http://\(host):\(port)/SpaceX.API.Device.Device/Handle")!)
        req.httpMethod = "POST"
        req.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        req.httpBody = body

        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: req)
        } catch {
            throw ClientError.unreachable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClientError.http(http.statusCode)
        }
        return try Self.parseGrpcWeb([UInt8](data), headers: (response as? HTTPURLResponse)?.allHeaderFields)
    }

    /// Splits a gRPC-Web body into frames: [flag:1][len:4 BE][payload]. Flag 0x80 = trailers.
    private static func parseGrpcWeb(_ bytes: [UInt8], headers: [AnyHashable: Any]?) throws -> ProtoMessage {
        var i = 0
        var message: ProtoMessage?
        var trailers = ""
        while i + 5 <= bytes.count {
            let flag = bytes[i]
            let len = Int(bytes[i+1]) << 24 | Int(bytes[i+2]) << 16 | Int(bytes[i+3]) << 8 | Int(bytes[i+4])
            i += 5
            guard i + len <= bytes.count else { throw ClientError.malformed("truncated frame") }
            let frame = Array(bytes[i..<(i + len)])
            i += len
            if flag & 0x80 != 0 {
                trailers += String(decoding: frame, as: UTF8.self)
            } else if message == nil {
                message = try ProtoMessage(frame)
            }
        }
        // grpc-status may arrive as a trailer frame or (trailers-only responses) as a header.
        var status = 0, statusMessage = ""
        for line in trailers.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0].lowercased() == "grpc-status" { status = Int(parts[1]) ?? 0 }
            if parts[0].lowercased() == "grpc-message" { statusMessage = parts[1].removingPercentEncoding ?? parts[1] }
        }
        if let h = headers?.first(where: { ($0.key as? String)?.lowercased() == "grpc-status" })?.value as? String {
            status = Int(h) ?? status
        }
        if status != 0 { throw ClientError.grpc(status, statusMessage) }
        guard let message else { throw ClientError.malformed("empty response") }
        return message
    }
}
