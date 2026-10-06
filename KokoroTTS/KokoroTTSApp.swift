import SwiftUI

/// The main application entry point for the Kokoro TTS app.
@main
struct KokoroTestApp: App {
  /// The app delegate that handles macOS Services integration and owns the model
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    Window("Kokoro TTS", id: "main") {
      ContentView(viewModel: appDelegate.model)
        .frame(minWidth: 350, minHeight: 300)
    }
    .defaultSize(width: 550, height: 550)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button(String(localized: "About Kokoro TTS")) {
          NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationIcon: NSApp.applicationIconImage as Any,
            .applicationName: "Kokoro TTS",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            .credits: NSAttributedString(
              string: "GitHub: https://github.com/kjyv/KokoroTTS" + buildLabel,
              attributes: [
                .link: URL(string: "https://github.com/kjyv/KokoroTTS")!,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
              ]
            )
          ])
        }
      }
      CommandGroup(replacing: .help) {
        HelpMenuButton()
      }
      CommandGroup(before: .toolbar) {
        TextSizeMenu()
      }
    }

    Window("Kokoro TTS Help", id: "help") {
      HelpView()
    }
    .windowResizability(.contentSize)
  }
}

/// A button that opens the help window using the SwiftUI environment.
struct HelpMenuButton: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button(String(localized: "Kokoro TTS Help")) {
      openWindow(id: "help")
    }
    .keyboardShortcut("?", modifiers: .command)
  }
}

/// View menu items for the text size: Small / Medium / Large, plus bigger and smaller shortcuts.
struct TextSizeMenu: View {
  @AppStorage(TextSize.storageKey) private var textSize: TextSize = TextSize.defaultValue

  var body: some View {
    Picker(String(localized: "Text Size"), selection: $textSize) {
      ForEach(TextSize.allCases) { size in
        Text(size.label).tag(size)
      }
    }
    .pickerStyle(.inline)

    Button(String(localized: "Bigger Text")) {
      if let larger = textSize.larger { textSize = larger }
    }
    .keyboardShortcut("+", modifiers: .command)
    .disabled(textSize.larger == nil)

    Button(String(localized: "Smaller Text")) {
      if let smaller = textSize.smaller { textSize = smaller }
    }
    .keyboardShortcut("-", modifiers: .command)
    .disabled(textSize.smaller == nil)

    Divider()
  }
}

/// Branch and commit stamped into Info.plist by the CI build (KokoroBuildBranch,
/// KokoroBuildCommit), shown in the About panel so the installed test build is identifiable.
/// Empty for builds that were not stamped.
private var buildLabel: String {
  let info = Bundle.main.infoDictionary ?? [:]
  guard let branch = info["KokoroBuildBranch"] as? String,
        let commit = info["KokoroBuildCommit"] as? String else { return "" }
  return "\nFork: https://github.com/petebrag/KokoroTTS\nBuild: \(branch) @ \(commit)"
}
