import NetdeckCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            Sidebar()
            mainColumn
                .padding(.leading, 4).padding(.trailing, 14).padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.frame)
        .background(TrialClock())
        .ignoresSafeArea()
        .id(model.localeVersion)
        // Arabic and Hebrew text still runs right to left inside labels; the layout (faceplates,
        // callouts, tables) stays left to right like the hardware it draws.
        .environment(\.layoutDirection, .leftToRight)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.windowHeight = $0 }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case let .addDevice(location): AddDeviceSheet(location: location).environment(model)
            case let .review(id):
                if let s = model.session(for: id) {
                    ReviewSheet(session: s, isSample: model.isSample(id), timer: model.defaultTimerMinutes)
                }
            case let .rollback(id, index):
                if let s = model.session(for: id) {
                    ReviewSheet(session: s, isSample: model.isSample(id), timer: model.defaultTimerMinutes, mode: .rollback(index: index))
                }
            case let .discardForeign(id):
                if let s = model.session(for: id) {
                    ReviewSheet(session: s, isSample: model.isSample(id), timer: model.defaultTimerMinutes, mode: .discardForeign)
                }
            }
        }
    }

    @ViewBuilder
    private var mainColumn: some View {
        switch model.selection {
        case .overview:
            if model.devices.isEmpty { FirstRunView() } else { OverviewScreen() }
        case let .device(id, section):
            if let d = model.device(id), let s = model.session(for: id) {
                DeviceScreen(device: d, session: s, section: section)
            } else {
                OverviewScreen()
            }
        }
    }
}

/// Hook for part 2: VLANs, Connected devices, History, basic-support Overview.
struct SectionPlaceholder: View {
    var section: DeviceSection
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.dashed").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.text4)
            Text(section.title).font(Typo.cardTitle).foregroundStyle(Theme.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }
}
