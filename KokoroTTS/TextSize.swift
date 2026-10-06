import AppKit
import SwiftUI

/// User-selectable size for the text area and playback controls.
/// Stored in UserDefaults under `storageKey`; defaults to `.large`.
enum TextSize: Int, CaseIterable, Identifiable {
  case small = 0
  case medium = 1
  case large = 2

  static let storageKey = "textSize"
  static let defaultValue: TextSize = .large

  var id: Int { rawValue }

  /// Multiplier applied to the standard macOS body font size (13 pt).
  var scale: CGFloat {
    switch self {
    case .small: return 1.0
    case .medium: return 1.5
    case .large: return 2.0
    }
  }

  var label: String {
    switch self {
    case .small: return String(localized: "Small")
    case .medium: return String(localized: "Medium")
    case .large: return String(localized: "Large")
    }
  }

  /// Font for the text editor and the highlighted playback text.
  var bodyFont: Font {
    .system(size: NSFont.systemFontSize * scale)
  }

  /// Scale for labels and icons in the control rows. Grows more slowly than the
  /// text itself so the controls stay on one line at the default window width.
  var controlScale: CGFloat {
    switch self {
    case .small: return 1.0
    case .medium: return 1.2
    case .large: return 1.4
    }
  }

  /// Font for control labels ("Voice:", "Speed:", time labels).
  var controlFont: Font {
    .system(size: NSFont.systemFontSize * controlScale)
  }

  /// Native control size for pickers and sliders.
  var controlSize: ControlSize {
    self == .small ? .regular : .large
  }

  var larger: TextSize? { TextSize(rawValue: rawValue + 1) }
  var smaller: TextSize? { TextSize(rawValue: rawValue - 1) }
}
