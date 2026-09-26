import SwiftUI

@main
struct CitsToGoApp: App {
    @State private var model = BridgeModel()
    @State private var location = LocationProvider()
    @State private var screen = ScreenAwake()
    @State private var sender = CamSender()
    @State private var notifier = WarningNotifier()
    @State private var assistant = AssistantModel()
    @State private var liveActivity = LiveActivityManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(location)
                .environment(screen)
                .environment(sender)
                .environment(notifier)
                .environment(assistant)
                .environment(liveActivity)
                .onAppear {
                    sender.attach(model: model, location: location)
                    notifier.location = location
                    assistant.attach(model: model, location: location)
                    liveActivity.attach(model: model, assistant: assistant)
                    model.onNewWarning = { [notifier] in notifier.handleNew($0) }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-test-warning") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            notifier.handleNew(DenmInfo(originatingStationId: 1234, sequenceNumber: 1, detectionTime: Date(),
                                                        referenceTime: Date(), terminated: false, latitude: nil, longitude: nil,
                                                        validitySeconds: 600, stationType: .passengerCar, causeCode: 27,
                                                        subCauseCode: 1, informationQuality: 3))
                        }
                    }
                    #endif
                }
                .onChange(of: model.linkState) { _, s in screen.setReceiverConnected(s.isStreaming) }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { model.flushRecording(); sender.stop(reason: "gestoppt (App im Hintergrund)") } else { screen.update() }
                }
        }
    }
}

struct RootView: View {
    // `-tab <n>` launch argument selects the initial tab (used for screenshots/tests).
    @State private var tab: Int = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-tab"), i + 1 < args.count else { return 0 }
        return Int(args[i + 1]) ?? 0
    }()

    var body: some View {
        TabView(selection: $tab) {
            LiveView().tabItem { Label("Live", systemImage: "dot.radiowaves.left.and.right") }.tag(0)
            IntersectionsView().tabItem { Label("Kreuzungen", systemImage: "light.beacon.max") }.tag(1)
            StationMapView().tabItem { Label("Karte", systemImage: "map") }.tag(2)
            CapturesView().tabItem { Label("Aufnahmen", systemImage: "externaldrive") }.tag(3)
            SettingsView().tabItem { Label("Einstellungen", systemImage: "gearshape") }.tag(4)
        }
    }
}
