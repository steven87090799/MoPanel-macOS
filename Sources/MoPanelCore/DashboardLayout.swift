// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct DashboardLayout: Equatable, Sendable {
    public enum Group: String, CaseIterable, Sendable { case sections, summary, trends }
    public static let defaults: [Group: [String]] = [
        .sections: ["summary", "trends", "resources", "applications", "cpu", "memory", "disk", "network", "thermal", "processes", "hardware", "system"],
        .summary: ["cpu", "gpu", "memory"],
        .trends: ["cpu", "memory", "disk", "network"]
    ]
    private var orders: [Group: [String]]
    public init(orders: [Group: [String]] = [:]) {
        self.orders = [:]
        for group in Group.allCases {
            let allowed = Self.defaults[group]!
            var seen = Set<String>()
            let saved = (orders[group] ?? []).filter { allowed.contains($0) && seen.insert($0).inserted }
            self.orders[group] = saved + allowed.filter { !seen.contains($0) }
        }
    }
    public init(defaults: UserDefaults) {
        self.init(orders: Dictionary(uniqueKeysWithValues: Group.allCases.map {
            ($0, defaults.stringArray(forKey: "dashboardLayout." + $0.rawValue) ?? [])
        }))
    }
    public func items(in group: Group) -> [String] { orders[group] ?? [] }
    public func save(to defaults: UserDefaults) {
        for group in Group.allCases { defaults.set(items(in: group), forKey: "dashboardLayout." + group.rawValue) }
    }
    public mutating func move(_ item: String, before target: String, in group: Group) {
        var order = items(in: group)
        guard item != target, let index = order.firstIndex(of: item), order.contains(target) else { return }
        order.remove(at: index)
        order.insert(item, at: order.firstIndex(of: target)!)
        orders[group] = order
    }
    public mutating func move(_ item: String, by offset: Int, in group: Group) {
        var order = items(in: group)
        guard let index = order.firstIndex(of: item), (-order.count...order.count).contains(offset), order.indices.contains(index + offset) else { return }
        order.remove(at: index)
        order.insert(item, at: index + offset)
        orders[group] = order
    }
}
