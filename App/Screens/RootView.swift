import SwiftUI
import HHTCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("onboarded") private var onboarded = false
    @State private var tab = UserDefaults.standard.integer(forKey: "hhtTab")

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { DayView() }
                .tabItem { Label("Today", systemImage: "calendar.day.timeline.left") }.tag(0)
            NavigationStack { HistoryView() }
                .tabItem { Label("Timeline", systemImage: "list.bullet.below.rectangle") }.tag(1)
            NavigationStack { ExploreMapView() }
                .tabItem { Label("Map", systemImage: "map") }.tag(2)
            NavigationStack { StatsView() }
                .tabItem { Label("Stats", systemImage: "chart.bar.xaxis") }.tag(3)
            NavigationStack { PlacesView() }
                .tabItem { Label("Places", systemImage: "mappin.and.ellipse") }.tag(4)
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil },
                                                          set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: Binding(get: { !onboarded }, set: { if !$0 { onboarded = true } })) {
            OnboardingView { onboarded = true }
                .interactiveDismissDisabled()
        }
    }
}

/// Wraps an ID so it can drive `.sheet(item:)`.
struct IDBox: Identifiable, Hashable { let id: String }

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    var done: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("A private travel diary").font(.largeTitle.bold())
                    Text("HHT records where you go, reconstructs your day into visits and trips (like a household travel survey for one), and lets you correct it in a couple of taps.")
                    Label("Everything stays on this iPhone in a local SQLite database. No account, no server.", systemImage: "lock.shield")
                    Label("Location “Always” lets it log trips in the background. It uses GPS only while you're moving.", systemImage: "location")
                    Label("Motion & Fitness activity helps tell walking, cycling and vehicles apart.", systemImage: "figure.walk.motion")
                    Label("Export CSV / JSON / GeoJSON / SQLite any time from Settings — for R, Python, QGIS.", systemImage: "square.and.arrow.up")
                    Text("After allowing “While Using”, iOS will later ask to upgrade to “Always”. Choose “Change to Always Allow”.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        model.collector.start()
                        model.motion.requestPermission()
                        done()
                    } label: {
                        Text("Allow location & start").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button("Not now") { done() }.frame(maxWidth: .infinity)
                }
                .padding()
            }
        }
    }
}
