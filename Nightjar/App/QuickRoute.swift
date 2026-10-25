import SwiftUI
@MainActor final class NightjarQuickRoute: ObservableObject {
    static let shared = NightjarQuickRoute()
    @Published var route: Route?
    @Published var showTimeline: UUID?
}
