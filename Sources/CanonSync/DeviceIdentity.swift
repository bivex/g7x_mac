import Foundation

public struct DeviceIdentity: Codable, Sendable {
    public let clientGUID: UUID
    public let friendlyName: String

    public static let configDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/canonsync", isDirectory: true)
    }()

    public static let fileURL: URL = {
        return configDir.appendingPathComponent("identity.json")
    }()

    public static func getOrCreate() -> DeviceIdentity {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        
        if let data = try? Data(contentsOf: fileURL),
           let identity = try? JSONDecoder().decode(DeviceIdentity.self, from: data) {
            return identity
        }

        let hwUUID = getHardwareUUID()
        let name = Host.current().localizedName ?? "MacBook-Pro"
        let identity = DeviceIdentity(clientGUID: hwUUID, friendlyName: name)

        if let encoded = try? JSONEncoder().encode(identity) {
            try? encoded.write(to: fileURL)
        }
        return identity
    }

    private static func getHardwareUUID() -> UUID {
        let dev = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if dev != 0 {
            if let prop = IORegistryEntryCreateCFProperty(dev, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                IOObjectRelease(dev)
                if let u = UUID(uuidString: prop) {
                    return u
                }
            }
            IOObjectRelease(dev)
        }
        return UUID(uuidString: "15F34B97-1FF7-559E-BF9D-721D8DD51014")!
    }
}
