import Foundation

public enum PTPConnectionResult: Sendable {
    case success(connNumber: UInt32, cameraName: String)
    case socketConnectFailed(errno: Int32, description: String)
    case handshakeTimedOut(stage: String, hint: String)
    case handshakeRejected(reasonCode: UInt32, description: String)
    case eventSocketFailed(errno: Int32, description: String)
    case connectionResetByCamera(stage: String)
    case protocolError(description: String)

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    public var diagnosticMessage: String {
        switch self {
        case .success(let num, let name):
            return "✅ Успешное сопряжение с '\(name)' (Соединение #\(num))"
        case .socketConnectFailed(let err, let desc):
            return "❌ Ошибка сокета TCP (\(err)): \(desc)"
        case .handshakeTimedOut(let stage, let hint):
            return "⏳ Таймаут на этапе '\(stage)'. Подсказка: \(hint)"
        case .handshakeRejected(let code, let desc):
            return "⛔ Камера отклонила сопряжение (код: \(String(format: "0x%08X", code))): \(desc)"
        case .eventSocketFailed(let err, let desc):
            return "❌ Ошибка канала событий Event Socket (\(err)): \(desc)"
        case .connectionResetByCamera(let stage):
            return "🔌 Камера разорвала соединение (Reset by peer) на этапе '\(stage)'"
        case .protocolError(let desc):
            return "⚠️ Ошибка протокола PTP-IP: \(desc)"
        }
    }
}

public final class PTPIPSession: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let clientGUID: UUID
    private let clientName: String

    private var cmdSocket: Int32 = -1
    private var evtSocket: Int32 = -1

    public init(host: String, port: UInt16 = 15740, clientGUID: UUID, clientName: String) {
        self.host = host
        self.port = port
        self.clientGUID = clientGUID
        self.clientName = clientName
    }

    public func connectAndOpen() -> PTPConnectionResult {
        // 1. Connect Command Socket
        cmdSocket = createSocket(timeoutSec: 3)
        guard cmdSocket >= 0 else {
            return .socketConnectFailed(errno: errno, description: String(cString: strerror(errno)))
        }

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
            let err = errno
            let desc = String(cString: strerror(err))
            disconnect()
            return .socketConnectFailed(errno: err, description: desc)
        }

        // 2. Send Init_Command_Request (Type 1)
        let guidBytes = withUnsafeBytes(of: clientGUID.uuid) { Array($0) }
        var nameBytes = Array(clientName.utf16)
        nameBytes.append(0)
        let nameData = nameBytes.withUnsafeBufferPointer { Data(buffer: $0) }
        var ver: UInt32 = 0x00010000

        var payload = Data()
        payload.append(contentsOf: guidBytes)
        payload.append(nameData)
        payload.append(Data(bytes: &ver, count: 4))

        var pktLen: UInt32 = UInt32(8 + payload.count)
        var pktType: UInt32 = 1

        var pkt = Data()
        pkt.append(Data(bytes: &pktLen, count: 4))
        pkt.append(Data(bytes: &pktType, count: 4))
        pkt.append(payload)

        let sent = pkt.withUnsafeBytes { send(cmdSocket, $0.baseAddress!, $0.count, 0) }
        guard sent == pkt.count else {
            disconnect()
            return .connectionResetByCamera(stage: "Отправка Init_Command_Request")
        }

        // 3. Receive Init_Command_Ack (Type 2) or Init_Fail (Type 5)
        var headerBuf = [UInt8](repeating: 0, count: 8)
        let n = recv(cmdSocket, &headerBuf, 8, 0)
        if n == 0 {
            disconnect()
            return .connectionResetByCamera(stage: "Ожидание ответа на Init_Command_Request")
        }
        if n < 0 {
            let err = errno
            disconnect()
            if err == EAGAIN || err == EWOULDBLOCK || err == ETIMEDOUT {
                return .handshakeTimedOut(
                    stage: "Init_Command_Ack",
                    hint: "Камера ждет выбора устройства или нажатия кнопки [SET / OK] на экране камеры"
                )
            }
            return .socketConnectFailed(errno: err, description: String(cString: strerror(err)))
        }
        guard n == 8 else {
            disconnect()
            return .protocolError(description: "Получен неполный заголовок (\(n) байт вместо 8)")
        }

        let respLen = headerBuf.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        let respType = headerBuf.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }

        if respType == 5 { // Init_Fail
            var failBuf = [UInt8](repeating: 0, count: 4)
            _ = recv(cmdSocket, &failBuf, 4, 0)
            let failCode = failBuf.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
            disconnect()
            let hint: String
            switch failCode {
            case 0x00000001: hint = "Камера занята другим соединением (Device Busy)"
            case 0x00000002: hint = "Неверный GUID или отказ в авторизации (Authentication Failed)"
            default: hint = "Неизвестная причина отказа"
            }
            return .handshakeRejected(reasonCode: failCode, description: hint)
        }

        guard respType == 2, respLen >= 12 else {
            disconnect()
            return .protocolError(description: "Неожиданный тип пакета: \(respType), длина: \(respLen)")
        }

        var bodyBuf = [UInt8](repeating: 0, count: Int(respLen - 8))
        let bn = recv(cmdSocket, &bodyBuf, bodyBuf.count, 0)
        guard bn == bodyBuf.count else {
            disconnect()
            return .protocolError(description: "Не удалось прочитать тело пакета Init_Command_Ack")
        }

        let connNumber = bodyBuf.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        var cameraName = "Canon Camera"
        if bodyBuf.count > 20 {
            let nameData = Data(bodyBuf[20...])
            if let decoded = String(data: nameData, encoding: .utf16LittleEndian) {
                cameraName = decoded.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespaces)
            }
        }

        // 4. Connect Event Socket
        evtSocket = createSocket(timeoutSec: 3)
        guard evtSocket >= 0 else {
            disconnect()
            return .eventSocketFailed(errno: errno, description: String(cString: strerror(errno)))
        }

        let evtRes = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(evtSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard evtRes == 0 else {
            let err = errno
            let desc = String(cString: strerror(err))
            disconnect()
            return .eventSocketFailed(errno: err, description: desc)
        }

        // Send Init_Event_Request (Type 3)
        var evtPktLen: UInt32 = 12
        var evtPktType: UInt32 = 3
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
            return .eventSocketFailed(errno: errno, description: "Не получен Init_Event_Ack")
        }

        let evtAckType = evtAckBuf.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        guard evtAckType == 4 else {
            disconnect()
            return .protocolError(description: "Ожидался Init_Event_Ack (4), получен тип \(evtAckType)")
        }

        return .success(connNumber: connNumber, cameraName: cameraName)
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
