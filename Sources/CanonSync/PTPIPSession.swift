import Foundation

public final class PTPIPSession: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let clientGUID: UUID
    private let clientName: String

    private var cmdSocket: Int32 = -1
    private var evtSocket: Int32 = -1
    private var sessionID: UInt32 = 0
    private var transactionID: UInt32 = 1

    public init(host: String, port: UInt16 = 15740, clientGUID: UUID, clientName: String) {
        self.host = host
        self.port = port
        self.clientGUID = clientGUID
        self.clientName = clientName
    }

    public func connectAndOpen() -> Bool {
        // 1. Connect Command Socket
        cmdSocket = createSocket(timeoutSec: 3)
        guard cmdSocket >= 0 else { return false }

        var sin = sockaddr_in()
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &sin.sin_addr)

        let res = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(cmdSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard res == 0 else {
            close(cmdSocket)
            cmdSocket = -1
            return false
        }

        // 2. Send Init_Command_Request (Type 1)
        // GUID (16 bytes), Friendly Name (UTF-16LE null-terminated), Protocol Version (0x00010000)
        let guidBytes = withUnsafeBytes(of: clientGUID.uuid) { Array($0) }
        var nameBytes = Array(clientName.utf16)
        nameBytes.append(0) // null terminator
        let nameData = nameBytes.withUnsafeBufferPointer { Data(buffer: $0) }
        var ver: UInt32 = 0x00010000

        var payload = Data()
        payload.append(contentsOf: guidBytes)
        payload.append(nameData)
        payload.append(Data(bytes: &ver, count: 4))

        var pktLen: UInt32 = UInt32(8 + payload.count)
        var pktType: UInt32 = 1 // Init_Command_Request

        var pkt = Data()
        pkt.append(Data(bytes: &pktLen, count: 4))
        pkt.append(Data(bytes: &pktType, count: 4))
        pkt.append(payload)

        _ = pkt.withUnsafeBytes { send(cmdSocket, $0.baseAddress!, $0.count, 0) }

        // 3. Receive Init_Command_Ack (Type 2)
        var headerBuf = [UInt8](repeating: 0, count: 8)
        let n = recv(cmdSocket, &headerBuf, 8, 0)
        guard n == 8 else {
            disconnect()
            return false
        }

        let respLen = headerBuf.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        let respType = headerBuf.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }

        guard respType == 2, respLen >= 12 else {
            disconnect()
            return false
        }

        var bodyBuf = [UInt8](repeating: 0, count: Int(respLen - 8))
        let bn = recv(cmdSocket, &bodyBuf, bodyBuf.count, 0)
        guard bn == bodyBuf.count else {
            disconnect()
            return false
        }

        let connNumber = bodyBuf.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }

        // 4. Connect Event Socket & Send Init_Event_Request (Type 3)
        evtSocket = createSocket(timeoutSec: 3)
        guard evtSocket >= 0 else {
            disconnect()
            return false
        }

        let evtRes = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(evtSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard evtRes == 0 else {
            disconnect()
            return false
        }

        var evtPktLen: UInt32 = 12
        var evtPktType: UInt32 = 3 // Init_Event_Request
        var connNum = connNumber

        var evtPkt = Data()
        evtPkt.append(Data(bytes: &evtPktLen, count: 4))
        evtPkt.append(Data(bytes: &evtPktType, count: 4))
        evtPkt.append(Data(bytes: &connNum, count: 4))

        _ = evtPkt.withUnsafeBytes { send(evtSocket, $0.baseAddress!, $0.count, 0) }

        // Receive Init_Event_Ack (Type 4)
        var evtAckBuf = [UInt8](repeating: 0, count: 8)
        let en = recv(evtSocket, &evtAckBuf, 8, 0)
        guard en == 8 else {
            disconnect()
            return false
        }

        let evtAckType = evtAckBuf.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        guard evtAckType == 4 else {
            disconnect()
            return false
        }

        // Session Established!
        return true
    }

    public func disconnect() {
        if cmdSocket >= 0 {
            close(cmdSocket)
            cmdSocket = -1
        }
        if evtSocket >= 0 {
            close(evtSocket)
            evtSocket = -1
        }
    }

    private func createSocket(timeoutSec: Int) -> Int32 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return -1 }

        var tv = timeval(tv_sec: timeoutSec, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var noSigPipe: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return sock
    }
}
