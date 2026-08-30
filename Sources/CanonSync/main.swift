import Foundation
import ImageCaptureCore

// MARK: - Configuration & CLI Arguments

struct SyncConfig: Sendable {
    var destinationURL: URL = {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        return pictures.appendingPathComponent("Canon_G7X", isDirectory: true)
    }()
    var organizeByDate: Bool = true
    var watchMode: Bool = true
    var listOnly: Bool = false
    var deleteAfterDownload: Bool = false
    var rawOnly: Bool = false
    var jpegOnly: Bool = false
    var manualIP: String? = nil
    var liveStream: Bool = false
    var installService: Bool = false
    var uninstallService: Bool = false
    var verbose: Bool = false

    static func parse() -> SyncConfig {
        var config = SyncConfig()
        let args = CommandLine.arguments

        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-d", "--dir", "--destination":
                if i + 1 < args.count {
                    let path = (args[i + 1] as NSString).expandingTildeInPath
                    config.destinationURL = URL(fileURLWithPath: path, isDirectory: true)
                    i += 1
                }
            case "--ip":
                if i + 1 < args.count {
                    config.manualIP = args[i + 1]
                    i += 1
                }
            case "-s", "--stream", "--live":
                config.liveStream = true
            case "-v", "--verbose", "--debug":
                config.verbose = true
            case "--install-daemon", "--install-service":
                config.installService = true
            case "--uninstall-daemon", "--uninstall-service":
                config.uninstallService = true
            case "--no-date":
                config.organizeByDate = false
            case "--once":
                config.watchMode = false
            case "-l", "--list":
                config.listOnly = true
            case "--delete-after":
                config.deleteAfterDownload = true
            case "--raw":
                config.rawOnly = true
            case "--jpg", "--jpeg":
                config.jpegOnly = true
            case "-h", "--help":
                printUsage()
                exit(0)
            default:
                print("⚠️ Неизвестный аргумент: \(arg)")
                printUsage()
                exit(1)
            }
            i += 1
        }
        return config
    }

    static func printUsage() {
        let identity = DeviceIdentity.getOrCreate()
        print("""
        📸 CanonSync — Фоновый автоконнект и синхронизация фото с Canon G7 X (PTP-IP / Wi-Fi)
        
        Идентификатор Mac (Постоянный GUID): \(identity.clientGUID.uuidString)
        Имя устройства: \(identity.friendlyName)

        Использование:
          swift run CanonSync [опции]

        Режимы:
          (по умолчанию)       Непрерывный автоконнект с постоянным ключом сопряжения
          -s, --stream         Запустить видеотрансляцию (LiveView)
          -l, --list           Только показать список файлов на камере
          --install-service    Установить как фоновую системную службу macOS (автозапуск при входе)
          --uninstall-service  Удалить фоновую службу

        Опции:
          -d, --dir <путь>     Папка для сохранения (по умолчанию: ~/Pictures/Canon_G7X)
          --ip <адрес>         Прямой IP камеры (например, --ip 192.168.223.242)
          -v, --verbose        Подробный вывод и расширенные логи сбоев
          --no-date            Не разбивать файлы по подпапкам с датами (YYYY-MM-DD)
          --raw                Скачивать только RAW (.CR2, .CR3, .RAW)
          --jpg, --jpeg        Скачивать только JPEG (.JPG, .JPEG)
          -h, --help           Показать эту справку
        """)
    }
}

// MARK: - Logger & System Notifications

enum Log {
    static var failureLogURL: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        return pictures.appendingPathComponent("Canon_G7X/connection_failures.log")
    }

    static func info(_ message: String) { print("ℹ️  \(message)") }
    static func success(_ message: String) { print("✅ \(message)") }
    static func warn(_ message: String) { print("⚠️  \(message)") }
    static func error(_ message: String) { print("❌ \(message)") }
    static func camera(_ message: String) { print("📷 \(message)") }
    static func stream(_ message: String) { print("🔴 \(message)") }

    static func failure(stage: String, error: String, hint: String? = nil) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())

        var logEntry = "[\(timestamp)] [FAILED] [\(stage)] \(error)"
        if let hint = hint {
            logEntry += " | Подсказка: \(hint)"
        }

        print("🚨 " + logEntry)

        // Append to connection_failures.log
        try? FileManager.default.createDirectory(at: failureLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: failureLogURL) {
            handle.seekToEndOfFile()
            if let data = (logEntry + "\n").data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        } else {
            try? (logEntry + "\n").write(to: failureLogURL, atomically: true, encoding: .utf8)
        }
    }

    static func notify(title: String, body: String) {
        let script = "display notification \"\(body)\" with title \"\(title)\" sound name \"default\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}

// MARK: - Safe Storage

final class SafeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ val: String) {
        lock.lock()
        if value == nil {
            value = val
        }
        lock.unlock()
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - Network Scanner for PTP-IP (Port 15740)

final class NetworkScanner: @unchecked Sendable {
    static func getLocalIPv4Subnets() -> [String] {
        var subnets: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            let interface = ptr!.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("ap") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, 0, NI_NUMERICHOST)
                    let ip = hostname.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                    if !ip.starts(with: "127.") {
                        let parts = ip.split(separator: ".")
                        if parts.count == 4 {
                            let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
                            if !subnets.contains(prefix) {
                                subnets.append(prefix)
                            }
                        }
                    }
                }
            }
        }
        return subnets
    }

    static func scanForCamera(subnets: [String]) -> String? {
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "scanner", attributes: .concurrent)
        let result = SafeResult()

        for subnet in subnets {
            for i in 1...254 {
                let ip = "\(subnet).\(i)"
                group.enter()
                queue.async {
                    defer { group.leave() }
                    var sin = sockaddr_in()
                    sin.sin_family = sa_family_t(AF_INET)
                    sin.sin_port = UInt16(15740).bigEndian
                    inet_pton(AF_INET, ip, &sin.sin_addr)

                    let sock = socket(AF_INET, SOCK_STREAM, 0)
                    if sock >= 0 {
                        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
                        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                        let res = withUnsafePointer(to: &sin) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                        if res == 0 {
                            result.set(ip)
                        }
                        close(sock)
                    }
                }
            }
        }
        _ = group.wait(timeout: .now() + 1.0)
        return result.get()
    }
}

// MARK: - Main Application

final class App: @unchecked Sendable {
    private let config: SyncConfig
    private let identity: DeviceIdentity
    private var isSyncing = false
    private var timer: Timer?
    private var lastKnownIP: String? = "192.168.223.242"

    init(config: SyncConfig) {
        self.config = config
        self.identity = DeviceIdentity.getOrCreate()
    }

    func run() {
        setbuf(stdout, nil)

        Log.info("📸 CanonSync: Автоконнект активен")
        Log.info("🔑 Постоянный GUID Mac: \(identity.clientGUID.uuidString)")
        Log.info("💻 Имя устройства: \(identity.friendlyName)")
        Log.info("📁 Папка сохранения: \(config.destinationURL.path)")
        Log.info("📝 Лог сбоев подключения: \(Log.failureLogURL.path)")
        try? FileManager.default.createDirectory(at: config.destinationURL, withIntermediateDirectories: true)

        if let directIP = config.manualIP {
            lastKnownIP = directIP
        }

        Log.info("🔍 Мониторинг сети... Включите Wi-Fi на камере Canon G7 X.")
        Log.info("Для выхода нажмите Ctrl+C\n")

        startAutoConnectLoop()
    }

    private func startAutoConnectLoop() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self, !self.isSyncing else { return }
            self.checkAndAutoConnect()
        }
        checkAndAutoConnect()
    }

    private func checkAndAutoConnect() {
        guard !isSyncing else { return }

        var targetIP: String? = nil

        if let ip = lastKnownIP, isPortOpen(ip: ip) {
            targetIP = ip
        } else {
            let subnets = NetworkScanner.getLocalIPv4Subnets()
            if let found = NetworkScanner.scanForCamera(subnets: subnets) {
                targetIP = found
                lastKnownIP = found
            }
        }

        guard let ip = targetIP else { return }

        Log.camera("Обнаружена камера на \(ip):15740! Запуск сопряжения...")
        syncWithCamera(ip: ip)
    }

    private func isPortOpen(ip: String) -> Bool {
        var sin = sockaddr_in()
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = UInt16(15740).bigEndian
        inet_pton(AF_INET, ip, &sin.sin_addr)

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let res = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return res == 0
    }

    private func syncWithCamera(ip: String) {
        isSyncing = true
        Log.info("Проверка PTP-IP рукопожатия с \(ip)...")

        let ptpSession = PTPIPSession(
            host: ip,
            port: 15740,
            clientGUID: identity.clientGUID,
            clientName: identity.friendlyName
        )
        
        let diagResult = ptpSession.connectAndOpen()
        switch diagResult {
        case .success(let num, let name):
            Log.success("✅ Согласовано с \(name) (Connection #\(num))!")
            ptpSession.disconnect()
        case .handshakeTimedOut(let stage, let hint):
            Log.failure(stage: "PTP Handshake: \(stage)", error: "Таймаут ожидания ответа камеры", hint: hint)
            ptpSession.disconnect()
        case .handshakeRejected(let code, let desc):
            Log.failure(stage: "PTP Authorization", error: "Отказ камеры (код \(String(format: "0x%08X", code)))", hint: desc)
            ptpSession.disconnect()
        case .socketConnectFailed(let err, let desc):
            Log.failure(stage: "TCP Socket Connect", error: "Ошибка \(err): \(desc)", hint: "Проверьте стабильность Wi-Fi сигнала")
            ptpSession.disconnect()
        case .connectionResetByCamera(let stage):
            Log.failure(stage: stage, error: "Камера разорвала соединение (Reset by peer)", hint: "Возможно, камера перешла в спящий режим")
            ptpSession.disconnect()
        case .eventSocketFailed(let err, let desc):
            Log.failure(stage: "Event Socket", error: "Ошибка \(err): \(desc)")
            ptpSession.disconnect()
        case .protocolError(let desc):
            Log.failure(stage: "Protocol", error: desc)
            ptpSession.disconnect()
        }

        // Start file transfer
        Log.info("Запуск загрузки файлов...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/gphoto2")
        
        var args = ["--port", "ptpip:\(ip)"]

        if config.listOnly {
            args.append("--list-files")
        } else {
            args.append("--get-all-files")
            args.append("--skip-existing")
            if config.organizeByDate {
                let targetPattern = config.destinationURL.path + "/%Y-%m-%d/%f.%C"
                args.append(contentsOf: ["--filename", targetPattern])
            } else {
                let targetPattern = config.destinationURL.path + "/%f.%C"
                args.append(contentsOf: ["--filename", targetPattern])
            }
        }

        process.arguments = args
        process.currentDirectoryURL = config.destinationURL

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            
            let fileHandle = pipe.fileHandleForReading
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    print(str, terminator: "")
                }
            }

            process.waitUntilExit()
            fileHandle.readabilityHandler = nil

            if process.terminationStatus == 0 {
                Log.success("Синхронизация успешно завершена!")
                Log.notify(title: "Canon G7 X Sync", body: "Синхронизация завершена! Фото сохранены в ~/Pictures/Canon_G7X")
            } else {
                Log.failure(stage: "gphoto2 transfer", error: "Код завершения: \(process.terminationStatus)", hint: "Камера закрыла сессию или ожидается выбор на экране")
            }
        } catch {
            Log.failure(stage: "Process launch", error: error.localizedDescription)
        }

        print(String(repeating: "─", count: 50) + "\n")
        
        Thread.sleep(forTimeInterval: 2.0)
        isSyncing = false

        if !config.watchMode {
            exit(0)
        } else {
            Log.info("📡 Ожидание следующего подключения камеры...")
        }
    }
}

// MARK: - Entry Point

let config = SyncConfig.parse()
let app = App(config: config)

signal(SIGINT) { _ in
    print("\n\nПрерывание работы (Ctrl+C)...")
    exit(0)
}
signal(SIGTERM) { _ in
    exit(0)
}

app.run()
RunLoop.main.run()
