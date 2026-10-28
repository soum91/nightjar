import AppIntents
import Foundation
struct CameraEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Camera"
    static var defaultQuery = CameraQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}
struct CameraQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [CameraEntity] { try await suggestedEntities().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [CameraEntity] { (Snapshot.load()?.cameras ?? []).map { .init(id: $0.id, name: $0.name) } }
}
enum CameraQuickAction: String, AppEnum {
    case camera, live, latestEvent, timeline
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Camera action"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.camera: "Open camera", .live: "Go live", .latestEvent: "Latest event", .timeline: "Event timeline"]
}
struct CameraWidgetConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Camera"
    @Parameter(title: "Camera") var camera: CameraEntity?
}
@available(iOS 18.0, *) struct CameraControlConfig: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Camera action"
    @Parameter(title: "Camera") var camera: CameraEntity?
    @Parameter(title: "Action", default: .camera) var action: CameraQuickAction
}
struct OpenCameraIntent: AppIntent {
    #if WIDGET_EXTENSION
    // The widget extension cannot be launched to run intents on this iOS, so
    // Shortcuts must only see (and run) the copy inside the app.
    static let isDiscoverable = false
    #endif
    static var title: LocalizedStringResource = "Open Nightjar Camera"
    static var openAppWhenRun = true
    @Parameter(title: "Camera") var camera: CameraEntity?
    @Parameter(title: "Action") var action: CameraQuickAction
    init() { action = .camera }
    init(_ camera: CameraEntity?, _ action: CameraQuickAction) { self.camera = camera; self.action = action }
    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let snap = Snapshot.load()
        switch action {
        case .camera:
            guard let id = camera?.id ?? snap?.cameras.first?.id else { throw VicoError(message: "Open Nightjar and load your cameras first.") }
            NightjarQuickRoute.shared.route = .camera(id)
        case .live:
            guard let id = camera?.id ?? snap?.cameras.first?.id else { throw VicoError(message: "Open Nightjar and load your cameras first.") }
            NightjarQuickRoute.shared.route = .live(id)
        case .latestEvent:
            guard let event = snap?.events.first(where: { camera == nil || $0.serial == camera?.id }) else { throw VicoError(message: "No recorded event for this camera.") }
            NightjarQuickRoute.shared.route = .event(event)
        case .timeline: NightjarQuickRoute.shared.showTimeline = UUID()
        }
        #endif
        return .result()
    }
}
