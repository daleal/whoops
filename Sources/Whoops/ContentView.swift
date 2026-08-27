import Foundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    powerControl
                    if let error = model.errorMessage {
                        errorBanner(error)
                    }
                    requestsSection
                    routesSection
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 430, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(model.filterState == .on ? Color.orange : Color.secondary.opacity(0.16))
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(model.filterState == .on ? .black : .secondary)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("WHOOPS")
                    .font(.system(.headline, design: .monospaced, weight: .black))
                Text("LOCAL REQUEST ROUTER")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .tracking(1.4)
            }
            Spacer()
            if !model.pending.isEmpty {
                Text("\(model.pending.count) WAITING")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.orange, in: Capsule())
                    .foregroundStyle(.black)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    private var powerControl: some View {
        Button {
            model.setEnabled(model.filterState == .off)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(statusTitle)
                        .font(.system(size: 24, weight: .black, design: .rounded))
                    Text(statusSubtitle)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(model.filterState == .on ? Color.black.opacity(0.62) : .secondary)
                }
                Spacer()
                ZStack(alignment: model.filterState == .on ? .trailing : .leading) {
                    Capsule()
                        .fill(model.filterState == .on ? Color.black.opacity(0.20) : Color.primary.opacity(0.10))
                        .frame(width: 76, height: 42)
                    Circle()
                        .fill(model.filterState == .on ? Color.black : Color.secondary)
                        .frame(width: 34, height: 34)
                        .padding(4)
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(model.filterState == .on ? Color.orange : Color.primary.opacity(0.055))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(model.filterState == .on ? Color.black.opacity(0.14) : Color.primary.opacity(0.10))
                    }
            )
        }
        .buttonStyle(.plain)
        .disabled(model.filterState.isBusy)
    }

    @ViewBuilder
    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("INTERCEPTS", count: model.pending.count)

            if model.pending.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: model.filterState == .on ? "dot.radiowaves.left.and.right" : "pause.fill")
                        .foregroundStyle(model.filterState == .on ? Color.orange : .secondary)
                    Text(model.filterState == .on ? "Listening for localhost HTTP" : "Router is disarmed")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(14)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach(model.pending) { request in
                    requestCard(request)
                }
            }
        }
    }

    private func requestCard(_ request: InterceptedRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(request.method)
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.black)
                        Text(verbatim: "\(request.host):\(String(request.port))")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                    }
                    Text(request.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            Button("Passthrough") {
                model.passthrough(request)
            }
            .buttonStyle(RouteButtonStyle(prominent: true))

            ForEach(model.targets) { target in
                if target.parsedURL != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(target.url)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                        HStack(spacing: 7) {
                            Button("Same :\(String(request.port))") {
                                model.redirect(request, to: target, samePort: true)
                            }
                            .buttonStyle(RouteButtonStyle())
                            Button("Default :\(String(target.defaultPort))") {
                                model.redirect(request, to: target, samePort: false)
                            }
                            .buttonStyle(RouteButtonStyle())
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.orange)
                .frame(width: 4)
                .padding(.vertical, 10)
        }
    }

    private var routesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("ROUTES", count: model.targets.count)
            ForEach($model.targets) { $target in
                HStack(spacing: 8) {
                    Image(systemName: target.parsedURL == nil ? "exclamationmark.triangle.fill" : "globe")
                        .foregroundStyle(target.parsedURL == nil ? Color.red : .secondary)
                    TextField("https://remote.dev", text: $target.url)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    Button {
                        model.removeTarget(id: target.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 11)
                .frame(height: 38)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            }
            Button {
                model.addTarget()
            } label: {
                Label("Add route", systemImage: "plus")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.orange)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.octagon.fill")
            Text(message)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
        }
        .foregroundStyle(Color.red)
        .padding(11)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack {
            Circle()
                .fill(model.filterState == .on ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text("127.0.0.1 + ::1")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            updateControl
            Button("Quit") { model.quit() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    @ViewBuilder
    private var updateControl: some View {
        switch updater.status {
        case .available(let version):
            Button("UPDATE \u{2192} v\(version)") { updater.update() }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(Color.orange)
        case .updating:
            Text("UPDATING...")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.orange)
        case .failed(let message):
            Button("UPDATE FAILED") { updater.update() }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.red)
                .help(message)
        case .idle, .checking:
            Text("v\(updater.currentVersion)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var statusTitle: String {
        switch model.filterState {
        case .off: "DISARMED"
        case .enabling: "ARMING..."
        case .on: "INTERCEPTING"
        case .disabling: "DISARMING..."
        }
    }

    private var statusSubtitle: String {
        switch model.filterState {
        case .off: "LOCAL TRAFFIC FLOWS NORMALLY"
        case .enabling: "ADMIN APPROVAL REQUIRED"
        case .on: "REQUESTS WAIT FOR YOUR ROUTE"
        case .disabling: "RESTORING LOCAL TRAFFIC"
        }
    }
}

private struct RouteButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .foregroundStyle(prominent ? Color.black : Color.primary)
            .background(
                prominent ? Color.orange.opacity(configuration.isPressed ? 0.70 : 1) : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.075),
                in: RoundedRectangle(cornerRadius: 7)
            )
    }
}
