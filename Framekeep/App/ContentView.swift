import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 160, ideal: 176, max: 220)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FKColor.graphite)
        }
        .environmentObject(app.settings)
        .environmentObject(app.queue)
        .environmentObject(app.library)
        .environmentObject(app.capture)
        .environmentObject(app.toolchain)
        .tint(FKColor.amber)
        .sheet(isPresented: $app.showingPicker) {
            QualityPickerView()
                .environmentObject(app)
                .environmentObject(app.queue)
        }
        .sheet(isPresented: $app.showingSetup) {
            SetupRequiredView()
                .environmentObject(app)
                .environmentObject(app.settings)
                .environmentObject(app.toolchain)
        }
        .task {
            await app.bootstrap()
        }
    }

    private var sidebar: some View {
        List(SidebarDestination.allCases, selection: Binding(
            get: { Optional(app.selected) },
            set: { newValue in
                guard let newValue, newValue != app.selected else { return }
                app.selected = newValue
            }
        )) { item in
            Label(item.title, systemImage: item.symbol)
                .tag(item)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, alignment: .leading) {
            HStack(spacing: 8) {
                Circle()
                    .fill(FKColor.amber)
                    .frame(width: 8, height: 8)
                Text("Framekeep")
                    .font(FKFont.display(15, weight: .semibold))
                    .foregroundStyle(FKColor.paper)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(FKColor.graphite)
    }

    @ViewBuilder
    private var detail: some View {
        switch app.selected {
        case .home:
            HomeView()
        case .queue:
            QueueView()
        case .library:
            LibraryView()
        case .capture:
            CaptureView()
        case .settings:
            SettingsView()
        }
    }
}
