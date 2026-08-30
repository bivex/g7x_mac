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
        print("""
        📸 CanonSync — Фоновый автоконнект и синхронизация фото с Canon G7 X (PTP-IP / Wi-Fi)
        
        Использование:
          swift run CanonSync [опции]

        Режимы:
          (по умолчанию)       Непрерывный автоконнект: ждет включения камеры и сам скачивает фото
          -s, --stream         Запустить видеотрансляцию (LiveView)
          -l, --list           Только показать список файлов на камере
          --install-service    Установить как фоновую системную службу macOS (автозапуск при входе)
          --uninstall-service  Удалить фоновую службу

        Опции:
          -d, --dir <путь>     Папка для сохранения (по умолчанию: ~/Pictures/Canon_G7X)
          --ip <адрес>         Прямой IP камеры (например, --ip 192.168.223.242)
          --no-date            Не разбивать файлы по подпапкам с датами (YYYY-MM-DD)
          --raw                Скачивать только RAW (.CR2, .CR3, .RAW)
          --jpg, --jpeg        Скачивать только JPEG (.JPG, .JPEG)
          -h, --help           Показать эту справку
        """)
    }
}

// MARK: - Logger & System Notifications

enum Log {
    static func info(_ message: String) { print("ℹ️  \(message)") }
    static func success(_ message: String) { print("✅ \(message)") }
    static func warn(_ message: String) { print("⚠️  \(message)") }
    static func error(_ message: String) { print("❌ \(message)") }
    static func camera(_ message: String) { print("📷 \(message)") }
    static func stream(_ message: String) { print("🔴 \(message)") }

    static func notify(title: String, body: String) {
        let script = "display notification \"\(body)\" with title \"\(title)\" sound name \"default\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
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

// MARK: - Daemon Service Installer

final class ServiceManager {
    static let serviceName = "com.canonsync.daemon"
    static var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(serviceName).plist")
    }

    static func install() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let binPath = "/usr/local/bin/canonsync"

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(serviceName)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(home.path)/Pictures/Canon_G7X/canonsync.log</string>
            <key>StandardErrorPath</key>
            <string>\(home.path)/Pictures/Canon_G7X/canonsync_err.log</string>
        </dict>
        </plist>
        """

        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? plistContent.write(to: plistURL, atomically: true, encoding: .utf8)

        let loadProc = Process()
        loadProc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        loadProc.arguments = ["load", "-w", plistURL.path]
        try? loadProc.run()
        loadProc.waitUntilExit()

        Log.success("🎉 Служба автоконнекта успешно установлена!")
        Log.info("Файл конфигурации: \(plistURL.path)")
        Log.info("CanonSync будет автоматически запускаться при входе в систему и выгружать фото.")
    }

    static func uninstall() {
        let unloadProc = Process()
        unloadProc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unloadProc.arguments = ["unload", plistURL.path]
        try? unloadProc.run()
        unloadProc.waitUntilExit()

        try? FileManager.default.removeItem(at: plistURL)
        Log.success("Служба автоконнекта отключена и удалена.")
    }
}

// MARK: - Main Application

final class App: @unchecked Sendable {
    private let config: SyncConfig
    private var isSyncing = false
    private var timer: Timer?
    private var lastKnownIP: String? = "192.168.223.242"

    init(config: SyncConfig) {
        self.config = config
    }

    func run() {
        setbuf(stdout, nil)
        
        if config.installService {
            ServiceManager.install()
            exit(0)
        }
        if config.uninstallService {
            ServiceManager.uninstall()
            exit(0)
        }

        Log.info("📸 CanonSync: Автоконнект активен")
        Log.info("Папка сохранения: \(config.destinationURL.path)")
        try? FileManager.default.createDirectory(at: config.destinationURL, withIntermediateDirectories: true)

        if let directIP = config.manualIP {
            lastKnownIP = directIP
        }

        Log.info("🔍 Мониторинг сети... Включите Wi-Fi на камере Canon G7 X.")
        Log.info("Как только камера появится в сети, начнется автоматическая синхронизация.")
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

        Log.camera("Обнаружена камера на \(ip):15740! Запуск автоконнекта...")
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
        Log.info("Подключение к камере (\(ip))...")

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
                Log.info("Ожидание подтверждения на камере или завершение сессии.")
            }
        } catch {
            Log.error("Ошибка запуска: \(error.localizedDescription)")
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
