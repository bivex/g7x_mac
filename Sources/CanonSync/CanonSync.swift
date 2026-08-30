import Foundation

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
        📸 CanonSync — Автосинхронизация фото Canon по Wi-Fi (PTP-IP) и USB
        
        Использование:
          swift run CanonSync [опции]

        Опции:
          -d, --dir <путь>     Папка для сохранения (по умолчанию: ~/Pictures/Canon_G7X)
          --ip <адрес>         Прямой IP камеры (например, --ip 192.168.223.242)
          --no-date            Не разбивать файлы по подпапкам с датами (YYYY-MM-DD)
          --once               Завершить работу после первой синхронизации
          -l, --list           Только показать список обнаруженных файлов
          --raw                Скачивать только RAW (.CR2, .CR3, .RAW)
          --jpg, --jpeg        Скачивать только JPEG (.JPG, .JPEG)
          --delete-after       Удалять файлы с камеры после скачивания
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

// MARK: - App

final class App: @unchecked Sendable {
    private let config: SyncConfig
    private var isSyncing = false
    private var timer: Timer?
    private var targetIP: String = "192.168.223.242"

    init(config: SyncConfig) {
        self.config = config
        if let directIP = config.manualIP {
            self.targetIP = directIP
        }
    }

    func run() {
        setbuf(stdout, nil)
        Log.info("📸 CanonSync запущен")
        Log.info("📁 Папка сохранения: \(config.destinationURL.path)")
        Log.info("🎯 IP камеры: \(targetIP)")
        try? FileManager.default.createDirectory(at: config.destinationURL, withIntermediateDirectories: true)

        Log.info("🔍 Мониторинг сети... Включите Wi-Fi на камере Canon.")
        Log.info("Для выхода нажмите Ctrl+C\n")

        startPoller()
    }

    private func startPoller() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.isSyncing else { return }
            self.checkAndSync()
        }
        checkAndSync()
    }

    private func checkAndSync() {
        guard !isSyncing else { return }

        // Fast ping to see if camera is online without touching TCP port 15740
        let pingProcess = Process()
        pingProcess.executableURL = URL(fileURLWithPath: "/sbin/ping")
        pingProcess.arguments = ["-c", "1", "-W", "300", targetIP]
        pingProcess.standardOutput = FileHandle.nullDevice
        pingProcess.standardError = FileHandle.nullDevice

        do {
            try pingProcess.run()
            pingProcess.waitUntilExit()
            if pingProcess.terminationStatus == 0 {
                Log.camera("Камера активна в сети (\(targetIP))! Запуск передачи фото...")
                syncWithCamera(ip: targetIP)
            }
        } catch {
            // ping error, ignore
        }
    }

    private func syncWithCamera(ip: String) {
        isSyncing = true

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
                Log.warn("Сессия завершена (код: \(process.terminationStatus))")
            }
        } catch {
            Log.error("Ошибка запуска: \(error.localizedDescription)")
        }

        print(String(repeating: "─", count: 50) + "\n")
        
        // Cooldown so we don't immediately re-trigger while camera is shutting down Wi-Fi
        Thread.sleep(forTimeInterval: 3.0)
        isSyncing = false

        if !config.watchMode {
            exit(0)
        } else {
            Log.info("Ожидание следующего подключения камеры...")
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
