import SwiftUI
import MoPanelCore

struct DashboardDragTarget: Hashable {
    let group: DashboardLayout.Group
    let item: String
}
struct DashboardFramePreference: PreferenceKey {
    static var defaultValue: [DashboardDragTarget: CGRect] { [:] }
    static func reduce(value: inout [DashboardDragTarget: CGRect], nextValue: () -> [DashboardDragTarget: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
struct DashboardTargetFrame: ViewModifier {
    let target: DashboardDragTarget
    let enabled: Bool
    func body(content: Content) -> some View {
        content.background {
            if enabled {
                GeometryReader { geometry in
                    Color.clear.preference(key: DashboardFramePreference.self,
                        value: [target: geometry.frame(in: .named("dashboardLayout"))])
                }
            }
        }
    }
}
