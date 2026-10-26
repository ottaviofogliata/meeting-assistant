import SwiftUI
import AppKit

@main struct MeetingAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()
    var body: some Scene {
        WindowGroup("Meeting Assistant", id: "main") {
            MainView().environmentObject(state).frame(minWidth: 1000, minHeight: 680)
                .tint(Color(red: 0.82, green: 0.22, blue: 0.19))
                .onAppear { delegate.state = state; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) { Button("Nuova riunione") { Task { await state.select(nil) } }.keyboardShortcut("n").disabled(state.isRecording) }
            CommandMenu("Registrazione") {
                Button("Avvia registrazione") { state.start() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!state.canStart)
                Button(state.active?.state == .paused ? "Riprendi" : "Pausa") { state.pauseResume() }.disabled(!state.isRecording)
                Button("Stop") { state.stop() }.keyboardShortcut(".", modifiers: [.command]).disabled(!state.isRecording)
            }
        }
        Settings { SettingsView().environmentObject(state) }
        MenuBarExtra {
            MenuControls().environmentObject(state)
        } label: {
            HStack(spacing: 5) { Image(systemName: state.isRecording ? "record.circle.fill" : "waveform"); if state.isRecording { Text(MeetingCore.Timestamp.format(state.elapsed)).monospacedDigit() } }
        }
    }
}

import MeetingCore
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        if state.isRecording {
            let alert = NSAlert(); alert.messageText = "Salvare la registrazione e uscire?"; alert.informativeText = "Audio e immagini acquisiti saranno conservati. Potrai completare l'elaborazione locale riaprendo la riunione."
            alert.addButton(withTitle: "Salva ed esci"); alert.addButton(withTitle: "Annulla")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Task { await state.prepareToQuit(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
private struct MenuControls: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Text(state.isRecording ? "\(state.active?.state.title ?? "") · \(Timestamp.format(state.elapsed))" : "Meeting Assistant")
        Button("Apri Meeting Assistant") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        if state.isRecording {
            Button(state.active?.state == .paused ? "Riprendi" : "Pausa") { state.pauseResume() }.disabled(state.busy)
            Button("Stop e salva") { state.stop() }.disabled(state.busy)
            Toggle("Trascrizione realtime", isOn: Binding(get: { state.active?.options.transcription == .realtime }, set: { state.setTranscription($0 ? .realtime : .background) }))
        } else { Button("Avvia riunione") { state.start() }.disabled(!state.canStart) }
        Divider(); Text(state.status); Divider(); SettingsLink { Text("Impostazioni…") }
        Button("Esci") { NSApp.terminate(nil) }
    }
}
