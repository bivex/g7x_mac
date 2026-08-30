import Foundation

// MARK: - PTP-IP Packet Types
private enum PTPPacketType: UInt32 {
    case initCommandRequest = 1
    case initCommandAck     = 2
    case initEventRequest   = 3
    case initEventAck       = 4
    case initFail           = 5
    case cmdRequest         = 6
    case cmdResponse        = 7
    case event              = 8
    case startDataPacket    = 9
    case dataPacket         = 10
    case cancelTransaction  = 11
    case endDataPacket      = 12
    case pingRequest        = 13  // Probe/Ping — keeps camera session alive
    case pingResponse       = 14  // Probe/Pong
}

// MARK: - PTP-IP Operation Codes (Canon EOS)
public enum PTPOpCode: UInt16 {
    case openSession    = 0x1002
    case closeSession   = 0x1003
    case getDeviceInfo  = 0x1001
    case noOp           = 0x1000
}

// MARK: - Connection Result
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
            return "✅ Сопряжение с '\(name)' (Соединение #\(num))"
        case .socketConnectFailed(let err, let desc):
            return "❌ Ошибка сокета TCP (\(err)): \(desc)"
        case .handshakeTimedOut(let stage, let hint):
            return "⏳ Таймаут на этапе '\(stage)'. \(hint)"
        case .handshakeRejected(let code, let desc):
            return "⛔ Камера отклонила сопряжение (0x\(String(code, radix:16, uppercase:true))): \(desc)"
        case .eventSocketFailed(let err, let desc):
            return "❌ Ошибка Event Socket (\(err)): \(desc)"
        case .connectionResetByCamera(let stage):
            return "🔌 Камера сбросила соединение (RST) на этапе '\(stage)'"
        case .protocolError(let desc):
            return "⚠️ Ошибка протокола PTP-IP: \(desc)"
        }
    }
}

// MARK: - PTPIPSession
public final class PTPIPSession: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let clientGUID: UUID
    private let clientName: String

    private var cmdSocket: Int32 = -1
    private var evtSocket: Int32 = -1
    private var connectionNumber: UInt32 = 0
    private var transactionID: UInt32 = 1

    // Keepalive timer — sends PTP-IP Ping every 5 seconds so camera doesn't drop RST
    private var keepaliveTimer: DispatchSourceTimer?
    private let keepaliveQueue = DispatchQueue(label: "ptpip.keepalive")

    public var isConnected: Bool { cmdSocket >= 0 }

    public init(host: String, port: UInt16 = 15740, clientGUID: UUID, clientName: String) {
        self.host = host
        self.port = port
        self.clientGUID = clientGUID
        self.clientName = clientName
    }

    // MARK: - Connect & Open PTP Session
    public func connectAndOpen() -> PTPConnectionResult {
        // --- Step 1: TCP Command Socket ---
        cmdSocket = makeSocket()
        guard cmdSocket >= 0 else {
            return .socketConnectFailed(errno: errno, description: String(cString: strerror(errno)))
        }
        var sin = makeSockAddr(ip: host, port: port)
        guard tcpConnect(sock: cmdSocket, addr: &sin) else {
            let e = errno; disconnect()
            return .socketConnectFailed(errno: e, description: String(cString: strerror(e)))
        }

        // --- Step 2: Send Init_Command_Request ---
        var initPkt = Data()
        let guidBytes = withUnsafeBytes(of: clientGUID.uuid) { Array($0) }
        var nameWords = Array(clientName.utf16); nameWords.append(0)
        let nameData = nameWords.withUnsafeBufferPointer { Data(buffer: $0) }
        var ver: UInt32 = 0x00010000
        initPkt.append(contentsOf: guidBytes)
        initPkt.append(nameData)
        initPkt.append(Data(bytes: &ver, count: 4))
        guard sendPacket(sock: cmdSocket, type: .initCommandRequest, body: initPkt) else {
            disconnect(); return .connectionResetByCamera(stage: "Init_Command_Request отправка")
        }

        // --- Step 3: Receive Init_Command_Ack or Init_Fail ---
        guard let (ackType, ackBody) = recvPacket(sock: cmdSocket, timeoutSec: 6) else {
            disconnect()
            return .handshakeTimedOut(
                stage: "Init_Command_Ack",
                hint: "Камера ждёт нажатия OK/SET на дисплее для подтверждения соединения"
            )
        }

        if ackType == PTPPacketType.initFail.rawValue {
            let failCode = ackBody.count >= 4
                ? ackBody.withUnsafeBytes { $0.load(as: UInt32.self) }
                : 0xFFFFFFFF
            disconnect()
            let hint: String
            switch failCode {
            case 0x00000001: hint = "Камера занята другим устройством (Device Busy)"
            case 0x00000002: hint = "Неверный GUID — камера не знает этот Mac"
            case 0x00000003: hint = "Устаревший сессионный ключ — нужно переподключиться"
            default:         hint = "Неизвестная причина (код: 0x\(String(failCode, radix:16, uppercase:true)))"
            }
            return .handshakeRejected(reasonCode: failCode, description: hint)
        }

        guard ackType == PTPPacketType.initCommandAck.rawValue, ackBody.count >= 4 else {
            disconnect()
            return .protocolError(description: "Неожиданный тип пакета: \(ackType)")
        }

        connectionNumber = ackBody.withUnsafeBytes { $0.load(as: UInt32.self) }

        var cameraName = "Canon Camera"
        if ackBody.count > 20 {
            let nd = Data(ackBody[20...])
            if let s = String(data: nd, encoding: .utf16LittleEndian) {
                let clean = s.trimmingCharacters(in: .init(charactersIn: "\0")).trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty { cameraName = clean }
            }
        }

        // --- Step 4: Event Socket ---
        evtSocket = makeSocket()
        guard evtSocket >= 0, tcpConnect(sock: evtSocket, addr: &sin) else {
            let e = errno; disconnect()
            return .eventSocketFailed(errno: e, description: String(cString: strerror(e)))
        }

        var connNum = connectionNumber
        let evtBody = Data(bytes: &connNum, count: 4)
        guard sendPacket(sock: evtSocket, type: .initEventRequest, body: evtBody) else {
            disconnect(); return .eventSocketFailed(errno: errno, description: "Не удалось отправить Init_Event_Request")
        }
        guard let (evtAckType, _) = recvPacket(sock: evtSocket, timeoutSec: 4),
              evtAckType == PTPPacketType.initEventAck.rawValue else {
            disconnect()
            return .protocolError(description: "Init_Event_Ack не получен")
        }

        // --- Step 5: Open PTP Session (0x1002) ---
        // This is required to actually OPEN a session after PTP-IP handshake.
        // Without OpenSession, Canon drops the TCP connection after ~15 seconds.
        let _ = sendPTPOperation(opCode: .openSession, params: [1])

        // --- Step 6: Start Keepalive so camera never idles out ---
        startKeepalive()

        return .success(connNumber: connectionNumber, cameraName: cameraName)
    }

    // MARK: - Keepalive (PTP-IP Ping every 5 sec)
    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: keepaliveQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.cmdSocket >= 0 else { return }
            // PTP-IP Ping (type 13) — zero body
            let sent = self.sendPacket(sock: self.cmdSocket, type: .pingRequest, body: Data())
            if !sent {
                Log.warn("Keepalive: не удалось отправить Ping, соединение потеряно")
            }
        }
        timer.resume()
        keepaliveTimer = timer
    }

    private func stopKeepalive() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    // MARK: - PTP Operation Request
    @discardableResult
    public func sendPTPOperation(opCode: PTPOpCode, params: [UInt32] = []) -> Data? {
        transactionID += 1
        var body = Data()
        var dataPhase: UInt32 = 1  // No data phase
        var code: UInt16 = opCode.rawValue
        var txID = transactionID
        body.append(Data(bytes: &dataPhase, count: 4))
        body.append(Data(bytes: &code, count: 2))
        body.append(Data(repeating: 0, count: 2)) // reserved
        body.append(Data(bytes: &txID, count: 4))
        for var p in params {
            body.append(Data(bytes: &p, count: 4))
        }
        guard sendPacket(sock: cmdSocket, type: .cmdRequest, body: body) else { return nil }
        guard let (_, respBody) = recvPacket(sock: cmdSocket, timeoutSec: 4) else { return nil }
        return respBody
    }

    // MARK: - Disconnect
    public func disconnect() {
        stopKeepalive()
        if cmdSocket >= 0 { close(cmdSocket); cmdSocket = -1 }
        if evtSocket >= 0 { close(evtSocket); evtSocket = -1 }
    }

    // MARK: - Packet I/O helpers

    private func sendPacket(sock: Int32, type: PTPPacketType, body: Data) -> Bool {
        var pkt = Data()
        var len: UInt32 = UInt32(8 + body.count)
        var ptype: UInt32 = type.rawValue
        pkt.append(Data(bytes: &len, count: 4))
        pkt.append(Data(bytes: &ptype, count: 4))
        pkt.append(body)
        let n = pkt.withUnsafeBytes { send(sock, $0.baseAddress!, $0.count, 0) }
        return n == pkt.count
    }

    private func recvPacket(sock: Int32, timeoutSec: Int) -> (UInt32, Data)? {
        // Set per-call timeout
        var tv = timeval(tv_sec: timeoutSec, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var header = [UInt8](repeating: 0, count: 8)
        let n = recv(sock, &header, 8, MSG_WAITALL)
        guard n == 8 else { return nil }

        let pktLen = header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        let pktType = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }

        let bodyLen = Int(pktLen) - 8
        guard bodyLen >= 0 else { return (pktType, Data()) }

        var bodyBuf = [UInt8](repeating: 0, count: bodyLen)
        if bodyLen > 0 {
            let bn = recv(sock, &bodyBuf, bodyLen, MSG_WAITALL)
            guard bn == bodyLen else { return nil }
        }
        return (pktType, Data(bodyBuf))
    }

    // MARK: - Socket helpers

    private func makeSocket() -> Int32 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return -1 }

        // Keepalive at kernel level — OS sends TCP keepalive probes
        var ka: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, &ka, socklen_t(MemoryLayout<Int32>.size))

        // Keepalive idle: 10 sec before first probe
        var kaIdle: Int32 = 10
        setsockopt(sock, IPPROTO_TCP, TCP_KEEPALIVE, &kaIdle, socklen_t(MemoryLayout<Int32>.size))

        // No SIGPIPE on broken writes
        var noSig: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))

        return sock
    }

    private func makeSockAddr(ip: String, port: UInt16) -> sockaddr_in {
        var sin = sockaddr_in()
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &sin.sin_addr)
        return sin
    }

    private func tcpConnect(sock: Int32, addr: inout sockaddr_in) -> Bool {
        // Short connect timeout (2 sec)
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }
}
