import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct JetBrainsQuotaInfo: Sendable, Equatable {
    public let type: String?
    public let used: Double
    public let maximum: Double
    public let available: Double
    public let until: Date?

    public init(type: String?, used: Double, maximum: Double, available: Double?, until: Date?) {
        self.type = type
        self.used = used
        self.maximum = maximum
        // Use available if provided, otherwise calculate from maximum - used
        self.available = available ?? max(0, maximum - used)
        self.until = until
    }

    /// Percentage of quota that has been used (0-100)
    public var usedPercent: Double {
        guard self.maximum > 0 else { return 0 }
        return min(100, max(0, (self.used / self.maximum) * 100))
    }

    /// Percentage of quota remaining (0-100), based on available value
    public var remainingPercent: Double {
        guard self.maximum > 0 else { return 100 }
        return min(100, max(0, (self.available / self.maximum) * 100))
    }
}

public struct JetBrainsRefillInfo: Sendable, Equatable {
    public let type: String?
    public let next: Date?
    public let amount: Double?
    public let duration: String?

    public init(type: String?, next: Date?, amount: Double?, duration: String?) {
        self.type = type
        self.next = next
        self.amount = amount
        self.duration = duration
    }
}

public struct JetBrainsStatusSnapshot: Sendable {
    public let quotaInfo: JetBrainsQuotaInfo
    public let refillInfo: JetBrainsRefillInfo?
    public let detectedIDE: JetBrainsIDEInfo?

    public init(quotaInfo: JetBrainsQuotaInfo, refillInfo: JetBrainsRefillInfo?, detectedIDE: JetBrainsIDEInfo?) {
        self.quotaInfo = quotaInfo
        self.refillInfo = refillInfo
        self.detectedIDE = detectedIDE
    }

    public func toUsageSnapshot() throws -> UsageSnapshot {
        // Primary shows monthly credits usage with next refill date
        // IDE displays: "今月のクレジット残り X / Y" with "Z月D日に更新されます"
        let refillDate = self.refillInfo?.next
        let primary = RateWindow(
            usedPercent: self.quotaInfo.usedPercent,
            windowMinutes: nil,
            resetsAt: refillDate,
            resetDescription: Self.formatResetDescription(refillDate))

        let identity = ProviderIdentitySnapshot(
            providerID: .jetbrains,
            accountEmail: nil,
            accountOrganization: self.detectedIDE?.displayName,
            loginMethod: self.quotaInfo.type)

        return UsageSnapshot(
            primary: primary,
            secondary: nil,
            tertiary: nil,
            updatedAt: Date(),
            identity: identity)
    }

    private static func formatResetDescription(_ date: Date?) -> String? {
        guard let date else { return nil }
        let now = Date()
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "Expired" }

        let hours = Int(interval / 3600)
        let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours > 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "Resets in \(days)d \(remainingHours)h"
        } else if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(minutes)m"
        }
    }
}

public enum JetBrainsStatusProbeError: LocalizedError, Sendable, Equatable {
    case noIDEDetected
    case quotaFileNotFound(String)
    case parseError(String)
    case noQuotaInfo

    public var errorDescription: String? {
        switch self {
        case .noIDEDetected:
            "No JetBrains IDE with AI Assistant detected. Install a JetBrains IDE and enable AI Assistant."
        case let .quotaFileNotFound(path):
            "JetBrains AI quota file not found at \(path). Enable AI Assistant in your IDE."
        case let .parseError(message):
            "Could not parse JetBrains AI quota: \(message)"
        case .noQuotaInfo:
            "No quota information found in the JetBrains AI configuration."
        }
    }
}

public struct JetBrainsStatusProbe: Sendable {
    private let settings: ProviderSettingsSnapshot?

    public init(settings: ProviderSettingsSnapshot? = nil) {
        self.settings = settings
    }

    public func fetch() async throws -> JetBrainsStatusSnapshot {
        let (quotaFilePath, detectedIDE) = try self.resolveQuotaFilePath()
        return try Self.parseQuotaFile(at: quotaFilePath, detectedIDE: detectedIDE)
    }

    private func resolveQuotaFilePath() throws -> (String, JetBrainsIDEInfo?) {
        if let customPath = self.settings?.jetbrainsIDEBasePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customPath.isEmpty
        {
            let expandedBasePath = (customPath as NSString).expandingTildeInPath
            let quotaPath = JetBrainsIDEDetector.quotaFilePath(for: expandedBasePath)
            return (quotaPath, nil)
        }

        guard let detectedIDE = JetBrainsIDEDetector.detectLatestIDE() else {
            throw JetBrainsStatusProbeError.noIDEDetected
        }
        return (detectedIDE.quotaFilePath, detectedIDE)
    }

    public static func parseQuotaFile(
        at path: String,
        detectedIDE: JetBrainsIDEInfo?) throws -> JetBrainsStatusSnapshot
    {
        guard FileManager.default.fileExists(atPath: path) else {
            throw JetBrainsStatusProbeError.quotaFileNotFound(path)
        }

        let xmlData: Data
        do {
            xmlData = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw JetBrainsStatusProbeError.parseError("Failed to read file: \(error.localizedDescription)")
        }

        return try Self.parseXMLData(xmlData, detectedIDE: detectedIDE)
    }

    public static func parseXMLData(_ data: Data, detectedIDE: JetBrainsIDEInfo?) throws -> JetBrainsStatusSnapshot {
        #if os(macOS)
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data)
        } catch {
            throw JetBrainsStatusProbeError.parseError("Invalid XML: \(error.localizedDescription)")
        }

        let quotaInfoRaw = try? document
            .nodes(forXPath: "//component[@name='AIAssistantQuotaManager2']/option[@name='quotaInfo']/@value")
            .first?
            .stringValue
        let nextRefillRaw = try? document
            .nodes(forXPath: "//component[@name='AIAssistantQuotaManager2']/option[@name='nextRefill']/@value")
            .first?
            .stringValue
        #else
        let parseResult = JetBrainsXMLParser.parse(data: data)
        let quotaInfoRaw = parseResult.quotaInfo
        let nextRefillRaw = parseResult.nextRefill
        #endif

        guard let quotaInfoRaw, !quotaInfoRaw.isEmpty else {
            throw JetBrainsStatusProbeError.noQuotaInfo
        }

        let quotaInfoDecoded = Self.decodeHTMLEntities(quotaInfoRaw)
        let quotaInfo = try Self.parseQuotaInfoJSON(quotaInfoDecoded)

        var refillInfo: JetBrainsRefillInfo?
        if let nextRefillRaw, !nextRefillRaw.isEmpty {
            let nextRefillDecoded = Self.decodeHTMLEntities(nextRefillRaw)
            refillInfo = try? Self.parseRefillInfoJSON(nextRefillDecoded)
        }

        return JetBrainsStatusSnapshot(
            quotaInfo: quotaInfo,
            refillInfo: refillInfo,
            detectedIDE: detectedIDE)
    }

    private static func decodeHTMLEntities(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private static func parseQuotaInfoJSON(_ jsonString: String) throws -> JetBrainsQuotaInfo {
        guard let data = jsonString.data(using: .utf8) else {
            throw JetBrainsStatusProbeError.parseError("Invalid JSON encoding")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JetBrainsStatusProbeError.parseError("Invalid JSON format")
        }

        let type = json["type"] as? String
        let currentStr = json["current"] as? String
        let maximumStr = json["maximum"] as? String
        let untilStr = json["until"] as? String

        // tariffQuota contains the actual available credits
        let tariffQuota = json["tariffQuota"] as? [String: Any]
        let availableStr = tariffQuota?["available"] as? String

        let used = currentStr.flatMap { Double($0) } ?? 0
        let maximum = maximumStr.flatMap { Double($0) } ?? 0
        let available = availableStr.flatMap { Double($0) }
        let until = untilStr.flatMap { Self.parseDate($0) }

        return JetBrainsQuotaInfo(type: type, used: used, maximum: maximum, available: available, until: until)
    }

    private static func parseRefillInfoJSON(_ jsonString: String) throws -> JetBrainsRefillInfo {
        guard let data = jsonString.data(using: .utf8) else {
            throw JetBrainsStatusProbeError.parseError("Invalid JSON encoding")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JetBrainsStatusProbeError.parseError("Invalid JSON format")
        }

        let type = json["type"] as? String
        let nextStr = json["next"] as? String
        let amountStr = json["amount"] as? String
        let duration = json["duration"] as? String

        let next = nextStr.flatMap { Self.parseDate($0) }
        let amount = amountStr.flatMap { Double($0) }

        let tariff = json["tariff"] as? [String: Any]
        let tariffAmountStr = tariff?["amount"] as? String
        let tariffDuration = tariff?["duration"] as? String
        let finalAmount = amount ?? tariffAmountStr.flatMap { Double($0) }
        let finalDuration = duration ?? tariffDuration

        return JetBrainsRefillInfo(type: type, next: next, amount: finalAmount, duration: finalDuration)
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

#if !os(macOS)
/// Lightweight XML scanner to avoid libxml2 dependency on Linux.
/// Parses only the component/option attributes needed for JetBrains AI quota info.
private enum JetBrainsXMLParser {
    struct ParseResult {
        let quotaInfo: String?
        let nextRefill: String?
    }

    static func parse(data: Data) -> ParseResult {
        guard let content = String(data: data, encoding: .utf8) else {
            return ParseResult(quotaInfo: nil, nextRefill: nil)
        }

        var scanner = XMLScanner(content: content)
        var quotaInfo: String?
        var nextRefill: String?
        var inComponent = false
        var componentDepth = 0

        while let tag = scanner.nextTag() {
            if tag.name == "component" {
                if tag.isEnd {
                    if inComponent {
                        componentDepth -= 1
                        if componentDepth <= 0 {
                            inComponent = false
                            componentDepth = 0
                        }
                    }
                    continue
                }

                if inComponent {
                    componentDepth += 1
                } else if tag.attributes["name"] == "AIAssistantQuotaManager2" {
                    inComponent = true
                    componentDepth = 1
                }

                continue
            }

            guard inComponent, !tag.isEnd, tag.name == "option" else { continue }
            switch tag.attributes["name"] {
            case "quotaInfo":
                quotaInfo = tag.attributes["value"]
            case "nextRefill":
                nextRefill = tag.attributes["value"]
            default:
                break
            }
        }

        return ParseResult(quotaInfo: quotaInfo, nextRefill: nextRefill)
    }

    private struct Tag {
        let name: String
        let isEnd: Bool
        let isSelfClosing: Bool
        let attributes: [String: String]
    }

    private struct XMLScanner {
        private let content: String
        private var index: String.Index

        init(content: String) {
            self.content = content
            self.index = content.startIndex
        }

        mutating func nextTag() -> Tag? {
            while let ltIndex = self.content[self.index...].firstIndex(of: "<") {
                self.index = self.content.index(after: ltIndex)
                if self.index >= self.content.endIndex { return nil }

                let current = self.content[self.index]
                if current == "!" {
                    if self.consume(prefix: "!--") {
                        self.skip(until: "-->")
                    } else if self.consume(prefix: "![CDATA[") {
                        self.skip(until: "]]>")
                    } else {
                        self.skip(until: ">")
                    }
                    continue
                }

                if current == "?" {
                    self.skip(until: "?>")
                    continue
                }

                if current == "/" {
                    self.index = self.content.index(after: self.index)
                    self.skipWhitespace()
                    let name = self.parseName()
                    self.skip(until: ">")
                    return Tag(name: name, isEnd: true, isSelfClosing: false, attributes: [:])
                }

                self.skipWhitespace()
                let name = self.parseName()
                var attributes: [String: String] = [:]
                var isSelfClosing = false

                while self.index < self.content.endIndex {
                    self.skipWhitespace()
                    if self.index >= self.content.endIndex { break }

                    if self.content[self.index] == "/" {
                        let nextIndex = self.content.index(after: self.index)
                        if nextIndex < self.content.endIndex, self.content[nextIndex] == ">" {
                            isSelfClosing = true
                            self.index = self.content.index(after: nextIndex)
                            break
                        }
                    }

                    if self.content[self.index] == ">" {
                        self.index = self.content.index(after: self.index)
                        break
                    }

                    let attributeName = self.parseName()
                    if attributeName.isEmpty {
                        self.skip(until: ">")
                        break
                    }

                    self.skipWhitespace()
                    var value: String?
                    if self.index < self.content.endIndex, self.content[self.index] == "=" {
                        self.index = self.content.index(after: self.index)
                        self.skipWhitespace()
                        value = self.parseAttributeValue()
                    }

                    if let value {
                        attributes[attributeName] = value
                    }
                }

                if !name.isEmpty {
                    return Tag(name: name, isEnd: false, isSelfClosing: isSelfClosing, attributes: attributes)
                }
            }

            return nil
        }

        private mutating func skipWhitespace() {
            while self.index < self.content.endIndex, self.content[self.index].isWhitespace {
                self.index = self.content.index(after: self.index)
            }
        }

        private mutating func parseName() -> String {
            let start = self.index
            while self.index < self.content.endIndex, self.isNameChar(self.content[self.index]) {
                self.index = self.content.index(after: self.index)
            }
            return String(self.content[start..<self.index])
        }

        private mutating func parseAttributeValue() -> String? {
            guard self.index < self.content.endIndex else { return nil }
            let quote = self.content[self.index]
            if quote == "\"" || quote == "'" {
                self.index = self.content.index(after: self.index)
                let start = self.index
                while self.index < self.content.endIndex, self.content[self.index] != quote {
                    self.index = self.content.index(after: self.index)
                }
                let value = String(self.content[start..<self.index])
                if self.index < self.content.endIndex {
                    self.index = self.content.index(after: self.index)
                }
                return value
            }

            let start = self.index
            while self.index < self.content.endIndex,
                  !self.content[self.index].isWhitespace,
                  self.content[self.index] != ">",
                  self.content[self.index] != "/"
            {
                self.index = self.content.index(after: self.index)
            }
            return String(self.content[start..<self.index])
        }

        private mutating func consume(prefix: String) -> Bool {
            let range = self.content[self.index...]
            if range.hasPrefix(prefix) {
                self.index = self.content.index(self.index, offsetBy: prefix.count, limitedBy: self.content.endIndex)
                    ?? self.content.endIndex
                return true
            }
            return false
        }

        private mutating func skip(until terminator: String) {
            if let range = self.content[self.index...].range(of: terminator) {
                self.index = range.upperBound
            } else {
                self.index = self.content.endIndex
            }
        }

        private func isNameChar(_ character: Character) -> Bool {
            character.isLetter
                || character.isNumber
                || character == "_"
                || character == "-"
                || character == ":"
                || character == "."
        }
    }
}
#endif
