import Foundation

enum MenuBarStatusItemDefaultsRepair {
    static let didRepairKey = "hasRepairedHiddenStatusItemVisibilityDefaults"
    private static let visibilityPrefix = "NSStatusItem VisibleCC "
    private static let legacyAutosavePrefix = "codexbar-"

    static func repairHiddenVisibilityDefaultsIfNeeded(defaults: UserDefaults) -> [String] {
        let didRepair = defaults.bool(forKey: self.didRepairKey)
        let repairedKeys = defaults.dictionaryRepresentation().keys
            .filter { key in
                self.shouldRepair(key: key, value: defaults.object(forKey: key), didRepair: didRepair)
            }
            .sorted()

        for key in repairedKeys {
            defaults.removeObject(forKey: key)
        }
        if !defaults.bool(forKey: self.didRepairKey) {
            defaults.set(true, forKey: self.didRepairKey)
        }
        return repairedKeys
    }

    static func shouldRepair(key: String, value: Any?, didRepair: Bool = false) -> Bool {
        guard key.hasPrefix(self.visibilityPrefix), self.isFalse(value) else { return false }
        let itemName = String(key.dropFirst(self.visibilityPrefix.count))
        if self.isDefaultStatusItemName(itemName) { return true }
        return !didRepair && itemName.hasPrefix(self.legacyAutosavePrefix)
    }

    private static func isDefaultStatusItemName(_ itemName: String) -> Bool {
        guard itemName.hasPrefix("Item-") else { return false }
        return itemName.dropFirst("Item-".count).allSatisfy(\.isNumber)
    }

    private static func isFalse(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber:
            !number.boolValue
        case let bool as Bool:
            !bool
        default:
            false
        }
    }
}
