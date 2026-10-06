import SwiftUI
import UniformTypeIdentifiers

/// This view provides a simple interface for text-to-speech generation.
struct ContentView: View {
  /// The view model that manages the TTS engine and audio playback
  @ObservedObject var viewModel: KokoroTTSModel

  /// Tracks whether the text editor is focused
  @FocusState private var isTextEditorFocused: Bool

  /// Tracks whether user wants to edit text (clicked into text area while paused)
  @State private var isEditingText: Bool = false

  /// Event monitor for spacebar play/pause
  @State private var eventMonitor: Any?

  /// Tracks which star is being hovered (0 = none)
  @State private var hoveredStar: Int = 0

  /// Height of the scroll view's visible frame, used for auto-scroll threshold
  @State private var scrollViewHeight: CGFloat = 0

  /// Prevents re-triggering auto-scroll during an ongoing scroll animation
  @State private var recentlyScrolled = false

  /// Size of the text area and controls (Small / Medium / Large), remembered across launches
  @AppStorage(TextSize.storageKey) private var textSize: TextSize = TextSize.defaultValue

  /// Returns the flag emoji for a voice based on its two-letter language/gender code prefix.
  /// Format: first letter = language (a=American, b=British), second letter = gender (f=female, m=male)
  private func flagForVoice(_ voice: String) -> String {
    guard voice.count >= 2 else { return "🌐" }
    let langCode = voice.first
    switch langCode {
    case "a": return "🇺🇸"  // American English
    case "b": return "🇬🇧"  // British English
    case "e": return "🇪🇸"  // Spanish
    case "f": return "🇫🇷"  // French
    case "h": return "🇮🇳"  // Hindi
    case "i": return "🇮🇹"  // Italian
    case "j": return "🇯🇵"  // Japanese
    case "p": return "🇧🇷"  // Portuguese (Brazilian)
    case "z": return "🇨🇳"  // Chinese
    default: return "🌐"
    }
  }

  /// Returns a gender icon based on the second letter of the voice code.
  private func genderIconForVoice(_ voice: String) -> String {
    guard voice.count >= 2 else { return "" }
    let genderCode = voice[voice.index(voice.startIndex, offsetBy: 1)]
    switch genderCode {
    case "f": return "👩‍🦰"
    case "m": return "👨🏻‍🦰"
    default: return ""
    }
  }

  /// Extracts the display name from a voice identifier (e.g., "af_bella" -> "Bella").
  private func displayNameForVoice(_ voice: String) -> String {
    // Split by underscore and take the part after it
    if let underscoreIndex = voice.firstIndex(of: "_") {
      let nameStart = voice.index(after: underscoreIndex)
      let name = String(voice[nameStart...])
      // Capitalize the first letter
      return name.prefix(1).uppercased() + name.dropFirst()
    }
    return voice
  }

  /// Returns a string of star characters representing the rating for a voice.
  private func ratingString(for voice: String) -> String {
    let rating = viewModel.rating(for: voice)
    if rating > 0 {
      return " " + String(repeating: "★", count: rating)
    }
    return ""
  }

  /// Formats a time value in seconds to MM:SS format.
  private func formatTime(_ time: Double) -> String {
    let totalSeconds = Int(time)
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%d:%02d", minutes, seconds)
  }

  /// Caches the parsed and rendered Markdown so playback ticks do not re-parse it.
  final class MarkdownCache {
    private var markdown: String?
    private var document: MarkdownDocument?
    private var scale: CGFloat = 0
    private var cached: MarkdownDocument.Rendered?

    func rendered(for markdown: String, speech: String, scale: CGFloat) -> MarkdownDocument.Rendered? {
      if markdown != self.markdown {
        self.markdown = markdown
        document = MarkdownDocument(markdown: markdown)
        cached = nil
      }
      // The Markdown only applies while the text box still holds its speech text;
      // any edit, paste or plain Service request switches back to plain text.
      guard let document, document.speech == speech else { return nil }
      if cached == nil || scale != self.scale {
        self.scale = scale
        cached = document.rendered(scale: scale)
      }
      return cached
    }
  }

  @State private var markdownCache = MarkdownCache()

  /// The text shown during playback: rendered Markdown when the text came from kokoro-speak
  /// with Markdown, otherwise the plain input text with no excluded ranges.
  private func displayDocument() -> MarkdownDocument.Rendered {
    if let markdown = viewModel.inputMarkdown,
       let rendered = markdownCache.rendered(for: markdown, speech: viewModel.inputText, scale: textSize.scale) {
      return rendered
    }
    let text = viewModel.inputText
    return MarkdownDocument.Rendered(text: AttributedString(text), string: text, excluded: [], captions: [])
  }

  /// Builds an AttributedString with the current word highlighted, preserving original formatting.
  ///
  /// Tokens are matched by `TokenMatcher`. Characters between spoken tokens (like parentheses)
  /// are filled in as spoken via gap-filling. Excluded ranges (code, tables, list markers)
  /// keep their own color and are never filled.
  private func highlightedText() -> AttributedString {
    let document = displayDocument()
    var result = document.text

    // Default everything to dimmed (not yet spoken)
    result.foregroundColor = Color(nsColor: .tertiaryLabelColor)

    let matches = TokenMatcher.match(
      viewModel.allTokens.map { $0.text }, in: document.string, excluding: document.excluded.map { $0.range })

    /// Colors a range as spoken; captions stay dimmer than body text.
    func markSpoken(_ range: Range<String.Index>) {
      if let attrRange = Range<AttributedString.Index>(range, in: result) {
        result[attrRange].foregroundColor = Color(nsColor: .labelColor)
      }
      for caption in document.captions where caption.overlaps(range) {
        let overlap = max(caption.lowerBound, range.lowerBound)..<min(caption.upperBound, range.upperBound)
        if let attrRange = Range<AttributedString.Index>(overlap, in: result) {
          result[attrRange].foregroundColor = Color(nsColor: .secondaryLabelColor)
        }
      }
    }

    // Track end of last spoken region for gap filling
    var lastSpokenOrigEnd: String.Index?

    for (index, token) in viewModel.allTokens.enumerated() {
      guard let origRange = matches[index] else { continue }

      let isCurrent = index == viewModel.currentTokenIndex
      let isSpoken = token.start_ts.map { $0 <= viewModel.currentTime } ?? false

      if isCurrent || isSpoken {
        // Fill gap: color characters between last spoken position and this token as spoken.
        // This handles parentheses, preprocessing artifacts, and any skipped characters.
        if let lastEnd = lastSpokenOrigEnd, lastEnd < origRange.lowerBound {
          markSpoken(lastEnd..<origRange.lowerBound)
        }
        lastSpokenOrigEnd = origRange.upperBound
      }

      if isCurrent {
        // Highlight the current word
        if let attrRange = Range<AttributedString.Index>(origRange, in: result) {
          result[attrRange].backgroundColor = Color.accentColor
          result[attrRange].foregroundColor = Color.white
        }
      } else if isSpoken {
        // Already spoken - normal color
        markSpoken(origRange)
      }
    }

    // Excluded ranges are never spoken; gap-filling must not recolor them.
    for excluded in document.excluded {
      if let attrRange = Range<AttributedString.Index>(excluded.range, in: result) {
        result[attrRange].foregroundColor = excluded.color
      }
    }

    return result
  }

  /// Returns the displayed text up to and including the current token, for measuring
  /// the highlight's vertical position within the scroll view. Keeps the rendered fonts
  /// so headings measure at their real height.
  private func textUpToCurrentToken() -> AttributedString {
    guard viewModel.currentTokenIndex >= 0,
          viewModel.currentTokenIndex < viewModel.allTokens.count else {
      return AttributedString()
    }
    let document = displayDocument()
    let matches = TokenMatcher.match(
      viewModel.allTokens.map { $0.text }, in: document.string, excluding: document.excluded.map { $0.range })

    for index in viewModel.currentTokenIndex..<matches.count {
      if let range = matches[index],
         let attrRange = Range<AttributedString.Index>(document.string.startIndex..<range.upperBound, in: document.text) {
        return AttributedString(document.text[attrRange])
      }
    }
    return document.text
  }

  /// Removes focus from the text editor so spacebar can control playback.
  private func unfocusTextEditor() {
    isTextEditorFocused = false
    NSApp.keyWindow?.makeFirstResponder(nil)
  }

  /// Shows a save panel and saves the audio to the selected location.
  private func saveAudio() {
    let savePanel = NSSavePanel()
    savePanel.title = String(localized: "Save Audio")
    savePanel.message = String(localized: "Choose a location to save the audio file")
    savePanel.allowedContentTypes = [.wav]
    savePanel.nameFieldStringValue = "kokoro_speech.wav"

    // Create format picker accessory view
    let formatPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 150, height: 24), pullsDown: false)
    formatPicker.addItems(withTitles: [String(localized: "WAV (Uncompressed)"), String(localized: "M4A (AAC)")])
    formatPicker.selectItem(at: 0)

    let label = NSTextField(labelWithString: String(localized: "Format:"))
    label.frame = NSRect(x: 0, y: 0, width: 50, height: 24)

    let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
    label.frame.origin = NSPoint(x: 0, y: 6)
    formatPicker.frame.origin = NSPoint(x: 55, y: 8)
    accessoryView.addSubview(label)
    accessoryView.addSubview(formatPicker)

    savePanel.accessoryView = accessoryView

    // Handle format changes - only update allowedContentTypes, let the system handle extension
    class FormatPickerTarget: NSObject {
      let savePanel: NSSavePanel

      init(savePanel: NSSavePanel) {
        self.savePanel = savePanel
      }

      @objc func formatChanged(_ sender: NSPopUpButton) {
        let exportFormat: KokoroTTSModel.AudioExportFormat = sender.indexOfSelectedItem == 0 ? .wav : .m4a
        savePanel.allowedContentTypes = exportFormat == .wav ? [.wav] : [.mpeg4Audio]

        // Strip any known audio extension (not just the literal last component) so
        // the base name is recovered reliably regardless of the current suffix.
        let knownExtensions: Set<String> = ["wav", "m4a", "mp4", "aac"]
        let current = savePanel.nameFieldStringValue as NSString
        let baseName = knownExtensions.contains(current.pathExtension.lowercased())
          ? current.deletingPathExtension
          : savePanel.nameFieldStringValue

        // Defer the rename to the next run loop turn: changing allowedContentTypes
        // triggers the panel's own asynchronous extension rewrite, which would
        // otherwise clobber a synchronous update here.
        DispatchQueue.main.async {
          self.savePanel.nameFieldStringValue = "\(baseName).\(exportFormat.fileExtension)"
        }
      }
    }

    let target = FormatPickerTarget(savePanel: savePanel)
    formatPicker.target = target
    formatPicker.action = #selector(FormatPickerTarget.formatChanged(_:))

    savePanel.begin { response in
      // Keep target alive until panel closes
      _ = target

      if response == .OK, let url = savePanel.url {
        // Drive the codec choice from the picker, not the filename. The save
        // panel may leave a stale extension in place when the format is switched,
        // so we also normalize the extension to match the chosen container.
        let exportFormat: KokoroTTSModel.AudioExportFormat = formatPicker.indexOfSelectedItem == 0 ? .wav : .m4a
        let outputURL = url.pathExtension.lowercased() == exportFormat.fileExtension
          ? url
          : url.deletingPathExtension().appendingPathExtension(exportFormat.fileExtension)
        do {
          try viewModel.saveAudio(to: outputURL, as: exportFormat)
        } catch {
          // Show error alert
          let alert = NSAlert()
          alert.messageText = String(localized: "Failed to save audio")
          alert.informativeText = error.localizedDescription
          alert.alertStyle = .warning
          alert.runModal()
        }
      }
    }
  }

  var body: some View {
    VStack(spacing: 16) {
      // Text input field / highlighted playback view
      Group {
        if viewModel.hasAudio && !viewModel.allTokens.isEmpty && !isEditingText {
          // Show highlighted text during playback or when paused (until user clicks to edit)
          ScrollViewReader { proxy in
            ScrollView {
              ZStack(alignment: .topLeading) {
                Text(highlightedText())
                  .font(textSize.bodyFont)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 5)

                // Invisible copy of text up to the current token, used only
                // to position the scroll anchor at the current highlight
                Text(textUpToCurrentToken())
                  .font(textSize.bodyFont)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 5)
                  .hidden()
                  .overlay(alignment: .bottomLeading) {
                    Color.clear
                      .frame(width: 1, height: 1)
                      .id("highlightAnchor")
                      .onGeometryChange(for: CGFloat.self) { geo in
                        geo.frame(in: .named("playbackScroll")).maxY
                      } action: { y in
                        if !recentlyScrolled && scrollViewHeight > 0 && y > scrollViewHeight * 0.75 {
                          recentlyScrolled = true
                          withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo("highlightAnchor", anchor: UnitPoint(x: 0.5, y: 0.1))
                          }
                          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            recentlyScrolled = false
                          }
                        }
                      }
                  }
              }
            }
            .coordinateSpace(name: "playbackScroll")
            .onGeometryChange(for: CGFloat.self) { geo in
              geo.size.height
            } action: { height in
              scrollViewHeight = height
            }
          }
          .padding(8)
          .background(Color(nsColor: .textBackgroundColor))
          .cornerRadius(8)
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
          )
          .onTapGesture {
            // Allow editing when tapping the text area (only when not playing)
            if !viewModel.isPlaying {
              isEditingText = true
              isTextEditorFocused = true
            }
          }
        } else {
          // Show editable text editor
          TextEditor(text: $viewModel.inputText)
            .font(textSize.bodyFont)
            .padding(8)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
            .focused($isTextEditorFocused)
            .overlay(
              RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
              if viewModel.inputText.isEmpty {
                Text("Type something to say...")
                  .font(textSize.bodyFont)
                  .foregroundColor(Color(nsColor: .placeholderTextColor))
                  .padding(.horizontal, 13)
                  .padding(.vertical, 8)
                  .allowsHitTesting(false)
              }
            }
            .onChange(of: viewModel.inputText) {
              // Clear audio when text is edited so play button regenerates
              // But not if audio is currently being generated (e.g., from service)
              if viewModel.hasAudio && !viewModel.isGeneratingAudio {
                viewModel.clearAudio()
              }
            }
        }
      }
      .frame(minHeight: 100)

      // Voice selection picker and rating
      HStack {
        Text("Voice:")
          .font(textSize.controlFont)
          .foregroundColor(Color(nsColor: .labelColor))
        Picker("", selection: $viewModel.selectedVoice) {
          ForEach(viewModel.voiceNames, id: \.self) { voice in
            Text("\(flagForVoice(voice)) \(genderIconForVoice(voice)) \(displayNameForVoice(voice))\(ratingString(for: voice))")
              .tag(voice)
          }
        }
        .pickerStyle(.menu)
        .controlSize(textSize.controlSize)
        .frame(minWidth: 150)

        Spacer()

        // Star rating for selected voice
        HStack(spacing: 4) {
          Text("Rating:")
            .font(textSize.controlFont)
            .foregroundColor(Color(nsColor: .labelColor))
          HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
              let isHighlighted = hoveredStar > 0 && star <= hoveredStar
              Button {
                // Toggle: clicking same rating clears it, otherwise set new rating
                if viewModel.rating(for: viewModel.selectedVoice) == star {
                  viewModel.setRating(0, for: viewModel.selectedVoice)
                } else {
                  viewModel.setRating(star, for: viewModel.selectedVoice)
                }
              } label: {
                Image(systemName: isHighlighted ? "star.fill" : "star")
                  .font(textSize.controlFont)
                  .foregroundColor(isHighlighted ? .yellow : Color(nsColor: .tertiaryLabelColor))
              }
              .buttonStyle(.plain)
              .onHover { hovering in
                if hovering {
                  hoveredStar = star
                }
              }
            }
          }
          .onHover { hovering in
            if !hovering {
              hoveredStar = 0
            }
          }
        }
      }

      // Speed control
      HStack {
        Text("Speed:")
          .font(textSize.controlFont)
          .foregroundColor(Color(nsColor: .labelColor))
        Slider(value: Binding(
          get: { Double(viewModel.speechSpeed) },
          set: { viewModel.speechSpeed = Float($0) }
        ), in: 0.5...2.0, step: 0.1)
        .controlSize(textSize.controlSize)
        .frame(width: 150)
        Text(String(format: "%.1fx", viewModel.speechSpeed))
          .font(textSize.controlFont)
          .foregroundColor(Color(nsColor: .secondaryLabelColor))
          .monospacedDigit()
          .frame(width: 40 * textSize.controlScale)
        Spacer()
      }

      // Text size control
      HStack {
        Text("Text size:")
          .font(textSize.controlFont)
          .foregroundColor(Color(nsColor: .labelColor))
        Picker("", selection: $textSize) {
          ForEach(TextSize.allCases) { size in
            Text(size.label).tag(size)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(textSize.controlSize)
        .fixedSize()
        Spacer()
      }

      // Player controls - always visible
      VStack(spacing: 8) {
        // Seek slider
        HStack(spacing: 12) {
          Text(formatTime(viewModel.currentTime))
            .font(.system(size: NSFont.smallSystemFontSize * textSize.controlScale))
            .monospacedDigit()
            .foregroundColor(Color(nsColor: .secondaryLabelColor))
            .frame(width: 45 * textSize.controlScale, alignment: .trailing)

          Slider(
            value: Binding(
              get: { viewModel.currentTime },
              set: {
                unfocusTextEditor()
                if viewModel.hasAudio {
                  viewModel.seek(to: $0)
                }
              }
            ),
            in: 0...max(viewModel.totalDuration, 0.01)
          )
          .controlSize(textSize.controlSize)
          .disabled(!viewModel.hasAudio)

          Text(formatTime(viewModel.totalDuration))
            .font(.system(size: NSFont.smallSystemFontSize * textSize.controlScale))
            .monospacedDigit()
            .foregroundColor(Color(nsColor: .secondaryLabelColor))
            .frame(width: 45 * textSize.controlScale, alignment: .leading)
        }

        // Playback buttons
        HStack {
          Spacer()

          HStack(spacing: 20) {
            // Back to start button
            Button {
              unfocusTextEditor()
              viewModel.pause()
              viewModel.seek(to: 0)
            } label: {
              Image(systemName: "backward.end.fill")
                .font(.system(size: 17 * textSize.controlScale))
                .help("Back to start")
            }
            .buttonStyle(.plain)
            .foregroundColor(viewModel.hasAudio ? Color(nsColor: .labelColor) : Color(nsColor: .tertiaryLabelColor))
            .disabled(!viewModel.hasAudio)

            // Play/Pause button - starts speaking if no audio, otherwise toggles
            Button {
              unfocusTextEditor()
              if viewModel.hasAudio {
                // Only exit edit mode when resuming, not when pausing
                if !viewModel.isPlaying {
                  isEditingText = false
                }
                viewModel.togglePlayPause()
              } else if !viewModel.inputText.isEmpty {
                isEditingText = false
                viewModel.say(viewModel.inputText)
              }
            } label: {
              Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 26 * textSize.controlScale))
                .help(viewModel.hasAudio ? (viewModel.isPlaying ? "Pause" : "Play") : "Generate and play audio")
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            // Cancel generation button - only shown while generating
            if viewModel.isGeneratingAudio {
              Button {
                unfocusTextEditor()
                viewModel.cancelGeneration()
              } label: {
                Image(systemName: "hand.raised.fill")
                  .font(.system(size: 17 * textSize.controlScale))
                  .help("Stop generating audio")
              }
              .buttonStyle(.plain)
              .foregroundColor(Color(nsColor: .secondaryLabelColor))
            }
          }

          Spacer()

          // Save button - only enabled when audio exists and generation is complete
          Button {
            unfocusTextEditor()
            saveAudio()
          } label: {
            Image(systemName: "square.and.arrow.down")
              .font(.system(size: 17 * textSize.controlScale))
              .help(!viewModel.hasAudio ? "Generate audio before saving to file" : (viewModel.isGeneratingAudio ? "Wait for audio generation to complete" : "Save audio to file"))
          }
          .buttonStyle(.plain)
          .foregroundColor(!viewModel.hasAudio || viewModel.isGeneratingAudio ? Color(nsColor: .tertiaryLabelColor) : Color(nsColor: .labelColor))
          .disabled(!viewModel.hasAudio || viewModel.isGeneratingAudio)
        }
      }
      .padding(.vertical, 8)

    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear {
      // Set up event monitor for spacebar play/pause and Escape to unfocus
      eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        // Check for Cmd+V — detect headline formatting from RTF on the clipboard
        // and insert empty lines after headlines for proper TTS pauses.
        // Only intercepts when headlines are detected; normal paste passes through.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "v",
           let firstResponder = NSApp.keyWindow?.firstResponder,
           firstResponder is NSTextView,
           let processedText = PasteboardHelper.extractTextPreservingHeadlines(from: .general) {
          viewModel.inputText = processedText
          return nil
        }

        // Check for Escape key (keyCode 53) - unfocus text editor
        if event.keyCode == 53 {
          isTextEditorFocused = false
          NSApp.keyWindow?.makeFirstResponder(nil)
          return nil
        }

        // Check for spacebar (keyCode 49)
        if event.keyCode == 49 {
          // Check if a text view has focus - if so, let spacebar through for typing
          if let firstResponder = NSApp.keyWindow?.firstResponder,
             firstResponder is NSTextView {
            return event  // Let text view handle the space
          }
          // Toggle play/pause if audio exists, otherwise start speaking
          if viewModel.hasAudio {
            // Only exit edit mode when resuming, not when pausing
            if !viewModel.isPlaying {
              isEditingText = false
            }
            viewModel.togglePlayPause()
          } else if !viewModel.inputText.isEmpty {
            isEditingText = false
            viewModel.say(viewModel.inputText)
          }
          return nil  // Consume the event
        }
        return event  // Pass through other events
      }
    }
    .onDisappear {
      // Clean up event monitor
      if let monitor = eventMonitor {
        NSEvent.removeMonitor(monitor)
        eventMonitor = nil
      }
    }
    .onChange(of: viewModel.selectedVoice) {
      // Clear audio when voice changes so play button regenerates
      if viewModel.hasAudio {
        viewModel.clearAudio()
      }
    }
    .onChange(of: viewModel.speechSpeed) {
      // Clear audio when speed changes so play button regenerates
      if viewModel.hasAudio {
        viewModel.clearAudio()
      }
    }
    .onChange(of: viewModel.isPlaying) { oldValue, newValue in
      // Reset editing mode when playback starts (including from service)
      if newValue && !oldValue {
        isEditingText = false
      }
    }
  }
}

#Preview {
  ContentView(viewModel: KokoroTTSModel())
}
