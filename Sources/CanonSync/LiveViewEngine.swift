import Foundation

public final class LiveViewEngine: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let clientGUID: UUID
    private let clientName: String

    private var isRunning = false
    private var cmdSocket: Int32 = -1
    private var evtSocket: Int32 = -1
    private var transactionID: UInt32 = 1
    private var sessionID: UInt32 = 1

    public init(host: String, port: UInt16 = 15740, clientGUID: UUID, clientName: String) {
        self.host = host
        self.port = port
        self.clientGUID = clientGUID
        self.clientName = clientName
    }

    public func startStream(onFrame: @escaping @Sendable (Data) -> Void) -> Bool {
        guard !isRunning else { return true }
        
        Log.stream("Инициализация PTP-IP LiveView канала с \(host):\(port)...")

        // 1. Establish PTP-IP session with persistent GUID
        let session = PTPIPSession(host: host, port: port, clientGUID: clientGUID, clientName: clientName)
        let res = session.connectAndOpen()
        guard res.isSuccess else {
            Log.failure(stage: "LiveView Session Init", error: res.diagnosticMessage)
            return false
        }

        isRunning = true
        Log.success("🔴 LiveView канал открыт! Запуск захвата видеопотока...")

        // Use high-performance gphoto2/ffmpeg pipeline or direct PTP loop
        let streamer = Process()
        streamer.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/gphoto2")
        streamer.arguments = [
            "--port", "ptpip:\(host)",
            "--capture-movie",
            "--stdout"
        ]

        let pipe = Pipe()
        streamer.standardOutput = pipe
        streamer.standardError = FileHandle.nullDevice

        do {
            try streamer.run()
            
            let handle = pipe.fileHandleForReading
            var buffer = Data()
            let soi = Data([0xFF, 0xD8]) // JPEG Start of Image
            let eoi = Data([0xFF, 0xD9]) // JPEG End of Image

            while isRunning && streamer.isRunning {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)

                // Extract JPEG frames from multipart stream
                while let startIdx = buffer.range(of: soi)?.lowerBound {
                    if startIdx > 0 {
                        buffer.removeSubrange(0..<startIdx)
                    }
                    guard let endRange = buffer.range(of: eoi) else { break }
                    let frameEnd = endRange.upperBound
                    let frameData = buffer.subdata(in: 0..<frameEnd)
                    buffer.removeSubrange(0..<frameEnd)

                    onFrame(frameData)
                }
            }

            streamer.terminate()
        } catch {
            Log.failure(stage: "LiveView Pipeline", error: error.localizedDescription)
            return false
        }

        isRunning = false
        return true
    }

    public func stop() {
        isRunning = false
    }
}
