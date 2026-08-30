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
    var streamPort: Int = 8080
    var launchPlayer: Bool = true

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
            case "--port":
                if i + 1 < args.count, let p = Int(args[i + 1]) {
                    config.streamPort = p
                    i += 1
                }
            case "--no-player":
                config.launchPlayer = false
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
        print("""
        📸 CanonSync — Синхронизация и Live-трансляция с камеры Canon (PTP-IP / Wi-Fi)
        
        Использование:
          swift run CanonSync [опции]

        Режимы:
          -s, --stream         Запустить видеотрансляцию (LiveView) в реальном времени
          -l, --list           Показать список файлов на камере
          (по умолчанию)       Автоматическое скачивание новых фото

        Опции трансляции:
          --port <номер>       Порт локального веб-сервера (по умолчанию: 8080)
          --no-player          Не открывать плеер ffplay (только веб-трансляция)

        Общие опции:
          -d, --dir <путь>     Папка для сохранения фото (по умолчанию: ~/Pictures/Canon_G7X)
          --ip <адрес>         Прямой IP камеры (например, --ip 192.168.223.242)
          --no-date            Не разбивать файлы по подпапкам с датами (YYYY-MM-DD)
          --raw                Скачивать только RAW (.CR2, .CR3, .RAW)
          --jpg, --jpeg        Скачивать только JPEG (.JPG, .JPEG)
          -h, --help           Показать эту справку
        """)
    }
}

// MARK: - Logger

enum Log {
    static func info(_ message: String) { print("ℹ️  \(message)") }
    static func success(_ message: String) { print("✅ \(message)") }
    static func warn(_ message: String) { print("⚠️  \(message)") }
    static func error(_ message: String) { print("❌ \(message)") }
    static func camera(_ message: String) { print("📷 \(message)") }
    static func stream(_ message: String) { print("🔴 \(message)") }
}

// MARK: - Safe IP Storage

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
                        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
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
        _ = group.wait(timeout: .now() + 1.2)
        return result.get()
    }
}

// MARK: - Live Stream Server & Manager

final class LiveStreamManager: @unchecked Sendable {
    private let config: SyncConfig
    private var isStreaming = false
    private var gphotoProcess: Process?
    private var playerProcess: Process?

    init(config: SyncConfig) {
        self.config = config
    }

    func startStreaming(ip: String) {
        guard !isStreaming else { return }
        isStreaming = true

        Log.stream("Запуск видеотрансляции с камеры Canon G7 X (\(ip))...")
        Log.info("🎥 Для просмотра можно использовать:")
        Log.info("  1. Окно видеоплеера с минимальной задержкой (ffplay)")
        Log.info("  2. OBS Studio: Источник мультимедиа -> pipe / поток\n")

        let gphoto = Process()
        gphoto.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/gphoto2")
        gphoto.arguments = [
            "--port", "ptpip:\(ip)",
            "--capture-movie",
            "--stdout"
        ]

        let pipe = Pipe()
        gphoto.standardOutput = pipe
        gphoto.standardError = FileHandle.nullDevice

        self.gphotoProcess = gphoto

        if config.launchPlayer {
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffplay")
            player.arguments = [
                "-hide_banner",
                "-loglevel", "error",
                "-fflags", "nobuffer+flush_packets",
                "-flags", "low_delay",
                "-framedrop",
                "-window_title", "Canon G7 X Mark II — LiveView",
                "-i", "pipe:0"
            ]
            player.standardInput = pipe
            self.playerProcess = player

            do {
                try player.run()
                try gphoto.run()
                Log.success("🔴 Трансляция запущена! Окно видеоплеера открыто.")
                
                player.waitUntilExit()
                gphoto.terminate()
            } catch {
                Log.error("Ошибка запуска видеопотока: \(error.localizedDescription)")
            }
        } else {
            do {
                try gphoto.run()
                Log.success("🔴 Трансляция запущена в stdout.")
                gphoto.waitUntilExit()
            } catch {
                Log.error("Ошибка запуска трансляции: \(error.localizedDescription)")
            }
        }

        isStreaming = false
        Log.info("Трансляция завершена.")
    }

    func stop() {
        playerProcess?.terminate()
        gphotoProcess?.terminate()
        isStreaming = false
    }
}

// MARK: - Main Application

final class App: @unchecked Sendable {
    private let config: SyncConfig
    private var isSyncing = false
    private var timer: Timer?
    private let streamManager: LiveStreamManager

    init(config: SyncConfig) {
        self.config = config
        self.streamManager = LiveStreamManager(config: config)
    }

    func run() {
        setbuf(stdout, nil)
        
        if config.liveStream {
            Log.stream("Режим видеотрансляции (LiveView) активен.")
        } else {
            Log.info("📸 Режим автосинхронизации фото активен.")
            Log.info("Папка сохранения: \(config.destinationURL.path)")
            try? FileManager.default.createDirectory(at: config.destinationURL, withIntermediateDirectories: true)
        }

        if let directIP = config.manualIP {
            Log.info("Прямое подключение к IP: \(directIP)")
            if config.liveStream {
                streamManager.startStreaming(ip: directIP)
            } else {
                syncWithCamera(ip: directIP)
            }
            if !config.watchMode { exit(0) }
        }

        Log.info("🔍 Поиск камеры в локальной сети (Wi-Fi PTP-IP)...")
        if config.watchMode {
            Log.info("📡 Ожидание подключения камеры. Включите Wi-Fi на Canon G7X.")
            Log.info("Для выхода нажмите Ctrl+C\n")
        }

        startPoller()
    }

    private func startPoller() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.isSyncing else { return }
            self.checkForCamera()
        }
        checkForCamera()
    }

    private func checkForCamera() {
        guard !isSyncing else { return }
        let subnets = NetworkScanner.getLocalIPv4Subnets()
        if let foundIP = NetworkScanner.scanForCamera(subnets: subnets) {
            Log.camera("Найдена камера Canon по адресу: \(foundIP):15740!")
            if config.liveStream {
                isSyncing = true
                streamManager.startStreaming(ip: foundIP)
                isSyncing = false
            } else {
                syncWithCamera(ip: foundIP)
            }
        }
    }

    private func syncWithCamera(ip: String) {
        isSyncing = true
        Log.info("Открытие PTP-IP сессии с \(ip)...")

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
                Log.success("Синхронизация с камерой успешно завершена!")
            } else {
                Log.warn("Процесс завершился с кодом \(process.terminationStatus)")
            }
        } catch {
            Log.error("Не удалось запустить процесс: \(error.localizedDescription)")
        }

        print(String(repeating: "─", count: 50) + "\n")
        isSyncing = false

        if !config.watchMode {
            exit(0)
        } else {
            Log.info("Ожидание следующего подключения камеры...")
        }
    }

    func stop() {
        streamManager.stop()
    }
}

// MARK: - Entry Point

let config = SyncConfig.parse()
let app = App(config: config)

signal(SIGINT) { _ in
    print("\n\nПрерывание работы (Ctrl+C)...")
    app.stop()
    exit(0)
}
signal(SIGTERM) { _ in
    app.stop()
    exit(0)
}

app.run()
RunLoop.main.run()
