import Foundation
import ImageCaptureCore

// MARK: - Configuration & CLI Arguments

struct SyncConfig {
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
        📸 CanonSync — Утилита автосинхронизации фото по Wi-Fi / USB (PTP-IP / Bonjour)
        
        Использование:
          swift run CanonSync [опции]

        Опции:
          -d, --dir <путь>     Папка для сохранения (по умолчанию: ~/Pictures/Canon_G7X)
          --no-date            Не разбивать файлы по подпапкам с датами (YYYY-MM-DD)
          --once               Завершить работу после первой синхронизации (без ожидания повторного подключения)
          -l, --list           Только показать список обнаруженных камер и файлов (без скачивания)
          --raw                Скачивать только RAW-файлы (.CR2, .CR3, .RAW)
          --jpg, --jpeg        Скачивать только JPEG-файлы (.JPG, .JPEG)
          --delete-after       Удалять файлы с камеры после успешного скачивания (ОСТОРОЖНО!)
          -h, --help           Показать эту справку
        """)
    }
}

// MARK: - Logger

enum Log {
    static func info(_ message: String) {
        print("ℹ️  \(message)")
    }
    static func success(_ message: String) {
        print("✅ \(message)")
    }
    static func warn(_ message: String) {
        print("⚠️  \(message)")
    }
    static func error(_ message: String) {
        print("❌ \(message)")
    }
    static func camera(_ message: String) {
        print("📷 \(message)")
    }
}

// MARK: - Camera Sync Manager

final class CameraSyncManager: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    private let config: SyncConfig
    private let browser = ICDeviceBrowser()
    private var connectedCameras: [ICCameraDevice] = []
    private var activeCamera: ICCameraDevice?
    private var isBusy: Bool = false

    // Download queue tracking
    private var downloadQueue: [ICCameraFile] = []
    private var currentDownloadIndex: Int = 0
    private var downloadedCount: Int = 0
    private var skippedCount: Int = 0
    private var failedCount: Int = 0
    private var currentTargetFolder: URL?

    init(config: SyncConfig) {
        self.config = config
        super.init()
        setupBrowser()
    }

    private func setupBrowser() {
        browser.delegate = self
        // Listen for Bonjour (Wi-Fi PTP-IP), Local (USB), and Shared cameras
        let rawMask = ICDeviceTypeMask.camera.rawValue |
                      ICDeviceLocationTypeMask.local.rawValue |
                      ICDeviceLocationTypeMask.bonjour.rawValue |
                      ICDeviceLocationTypeMask.shared.rawValue
        if let mask = ICDeviceTypeMask(rawValue: rawMask) {
            browser.browsedDeviceTypeMask = mask
        }
    }

    func start() {
        Log.info("Запуск поиска камер Canon по Wi-Fi (Bonjour/PTP-IP) и USB...")
        Log.info("Папка назначения: \(config.destinationURL.path)")
        if config.watchMode {
            Log.info("Режим мониторинга: ожидание подключения камеры. (Нажмите Ctrl+C для выхода)\n")
        }

        // Create base directory if needed
        try? FileManager.default.createDirectory(at: config.destinationURL, withIntermediateDirectories: true)

        browser.start()
    }

    func stop() {
        browser.stop()
        if let camera = activeCamera {
            Log.camera("Закрытие сессии с камерой \(camera.name ?? "Camera")...")
            camera.requestCloseSession()
        }
    }

    // MARK: - ICDeviceBrowserDelegate

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        
        let transport = device.transportType ?? ""
        let isWifi = device.isRemote || transport == ICTransportTypeTCPIP
        let connType = isWifi ? "Wi-Fi (PTP-IP)" : (transport == ICTransportTypeUSB ? "USB" : transport)
        Log.camera("Обнаружена камера: \(camera.name ?? "Canon Camera") [\(connType)]")

        if !connectedCameras.contains(where: { $0 === camera }) {
            connectedCameras.append(camera)
        }

        if !isBusy && activeCamera == nil {
            connectTo(camera: camera)
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        Log.warn("Камера отключена: \(camera.name ?? "Camera")")
        connectedCameras.removeAll(where: { $0 === camera })

        if activeCamera === camera {
            activeCamera = nil
            isBusy = false
            if !config.watchMode {
                exit(0)
            }
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, deviceDidChangeName device: ICDevice) {}
    func deviceBrowser(_ browser: ICDeviceBrowser, deviceDidChangeSharingState device: ICDevice) {}

    // MARK: - Connection & Session Management

    private func connectTo(camera: ICCameraDevice) {
        activeCamera = camera
        isBusy = true
        camera.delegate = self
        Log.camera("Подключение к \(camera.name ?? "камере")...")
        camera.requestOpenSession()
    }

    // MARK: - ICDeviceDelegate

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error = error {
            Log.error("Ошибка открытия сессии с камерой: \(error.localizedDescription)")
            isBusy = false
            activeCamera = nil
            if !config.watchMode {
                exit(1)
            }
            return
        }
        Log.success("Сессия успешно открыта! Чтение каталога файлов...")
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        if let error = error {
            Log.warn("Сессия закрыта с сообщением: \(error.localizedDescription)")
        } else {
            Log.info("Сессия с камерой закрыта.")
        }
        activeCamera = nil
        isBusy = false

        if !config.watchMode {
            Log.success("Синхронизация завершена.")
            exit(0)
        } else {
            Log.info("Ожидание следующего подключения камеры...\n")
        }
    }

    func didRemove(_ device: ICDevice) {}
    func deviceDidChangeName(_ device: ICDevice) {}
    func deviceDidBecomeReady(_ device: ICDevice) {}
    func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus : Any]) {}
    func device(_ device: ICDevice, didEncounterError error: Error?) {
        if let error = error {
            Log.error("Ошибка устройства: \(error.localizedDescription)")
        }
    }

    // MARK: - ICCameraDeviceDelegate

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Log.success("Каталог файлов камеры полностью загружен. Всего объектов: \(device.mediaFiles?.count ?? 0)")
        processMediaFiles(device: device)
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable : Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: Error?) {}

    // MARK: - Processing & Downloading

    private func processMediaFiles(device: ICCameraDevice) {
        guard let allItems = device.mediaFiles, !allItems.isEmpty else {
            Log.warn("На камере нет доступных медиафайлов.")
            finishCurrentSession()
            return
        }

        let files = allItems.compactMap { $0 as? ICCameraFile }

        let filteredFiles = files.filter { file in
            guard let name = file.name?.uppercased() else { return false }
            if config.rawOnly {
                return name.hasSuffix(".CR2") || name.hasSuffix(".CR3") || name.hasSuffix(".RAW")
            }
            if config.jpegOnly {
                return name.hasSuffix(".JPG") || name.hasSuffix(".JPEG")
            }
            return true
        }

        if config.listOnly {
            print("\n📋 Список файлов на \(device.name ?? "камере") (\(filteredFiles.count) шт.):")
            for (idx, file) in filteredFiles.enumerated() {
                let sizeMB = Double(file.fileSize) / (1024 * 1024)
                let dateStr = file.creationDate?.formatted(date: .numeric, time: .shortened) ?? "нет даты"
                print(String(format: "  [%3d] %@ (%.2f МБ) — %@", idx + 1, file.name ?? "Без имени", sizeMB, dateStr))
            }
            print("")
            finishCurrentSession()
            return
        }

        self.downloadQueue = filteredFiles
        self.currentDownloadIndex = 0
        self.downloadedCount = 0
        self.skippedCount = 0
        self.failedCount = 0

        Log.info("Найдено файлов для обработки: \(filteredFiles.count)")
        downloadNextFile()
    }

    private func downloadNextFile() {
        guard let camera = activeCamera else { return }

        if currentDownloadIndex >= downloadQueue.count {
            printSummary()
            finishCurrentSession()
            return
        }

        let file = downloadQueue[currentDownloadIndex]
        currentDownloadIndex += 1

        let fileName = file.name ?? "IMG_\(currentDownloadIndex).JPG"
        let fileSize = file.fileSize
        let sizeMB = Double(fileSize) / (1024 * 1024)

        // Determine destination directory
        var targetDir = config.destinationURL
        if config.organizeByDate {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let folderName = dateFormatter.string(from: file.creationDate ?? Date())
            targetDir = targetDir.appendingPathComponent(folderName, isDirectory: true)
        }

        try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        self.currentTargetFolder = targetDir

        let destFileURL = targetDir.appendingPathComponent(fileName)

        // Check if file already exists and size matches
        if FileManager.default.fileExists(atPath: destFileURL.path) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: destFileURL.path),
               let existingSize = attrs[.size] as? Int64,
               existingSize == fileSize {
                print("⏩ [\(currentDownloadIndex)/\(downloadQueue.count)] Пропуск (уже скачан): \(fileName)")
                skippedCount += 1
                downloadNextFile()
                return
            }
        }

        print(String(format: "📥 [%d/%d] Скачивание: %@ (%.2f МБ)...", currentDownloadIndex, downloadQueue.count, fileName, sizeMB))

        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: targetDir,
            .saveAsFilename: fileName,
            .overwrite: true
        ]

        camera.requestDownloadFile(
            file,
            options: options,
            downloadDelegate: self,
            didDownloadSelector: #selector(didDownloadFile(_:error:options:contextInfo:)),
            contextInfo: nil
        )
    }

    // MARK: - ICCameraDeviceDownloadDelegate

    @objc func didDownloadFile(_ file: ICCameraFile, error: Error?, options: [String: Any], contextInfo: UnsafeMutableRawPointer?) {
        let fileName = file.name ?? "файл"
        if let error = error {
            Log.error("Ошибка при скачивании \(fileName): \(error.localizedDescription)")
            failedCount += 1
        } else {
            downloadedCount += 1
            if config.deleteAfterDownload, let camera = activeCamera {
                Log.warn("Удаление \(fileName) с камеры...")
                camera.requestDeleteFiles([file])
            }
        }

        // Process next item
        downloadNextFile()
    }

    private func printSummary() {
        print("\n" + String(repeating: "─", count: 50))
        Log.success("Итоги синхронизации:")
        print("  • Скачано новых:   \(downloadedCount)")
        print("  • Пропущено (были): \(skippedCount)")
        if failedCount > 0 {
            print("  • Ошибок:          \(failedCount)")
        }
        print("  • Папка:           \(config.destinationURL.path)")
        print(String(repeating: "─", count: 50) + "\n")
    }

    private func finishCurrentSession() {
        if let camera = activeCamera {
            camera.requestCloseSession()
        }
    }
}

// MARK: - Main Entry Point

let config = SyncConfig.parse()
let manager = CameraSyncManager(config: config)

// Handle graceful termination (Ctrl+C)
signal(SIGINT) { _ in
    print("\n\nПрерывание работы (Ctrl+C)...")
    manager.stop()
    exit(0)
}
signal(SIGTERM) { _ in
    manager.stop()
    exit(0)
}

manager.start()

// Run the NSRunLoop to process ImageCaptureCore events
RunLoop.main.run()
