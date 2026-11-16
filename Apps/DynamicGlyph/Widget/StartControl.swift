import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center switch: On, in the app's blue, while the screen is
/// actually being read; Off otherwise, including while the system's
/// screen-sharing confirmation is open. Turning it on opens the app to start
/// as Home's Start does; turning it off stops without opening the app. One
/// symbol in both states, the app's own `dynamicglyph.control` from
/// ControlSymbols.xcassets; the system draws the rest.
///
/// The type and kind keep their start-only names, so a control already
/// placed in Control Center stays.
struct StartControl: ControlWidget {
    static let kind = ControlChannel.kind

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: CaptureValueProvider()) { isOn in
            Self.toggle(isOn: isOn)
        }
        .displayName(LocalizedStringResource("Dynamic Glyph",
                                              comment: "The Control Center switch's name, the same in every language."))
        .description(LocalizedStringResource("Start or stop Dynamic Glyph. Starting requires screen-sharing confirmation.",
                                             comment: "Description of the Control Center switch in the controls gallery."))
    }

    /// One control, so a placed switch stays, with the action chosen by
    /// version: from iOS 18.2 the one that stops without opening the app;
    /// on 18.0 and 18.1 the one that can open it at all. The template builder
    /// takes no `if`, so the choice is made here, where an opaque result may
    /// differ by availability.
    private static func toggle(isOn: Bool) -> some ControlWidgetTemplate {
        if #available(iOS 18.2, *) {
            return toggle(isOn: isOn, action: ToggleGlyphIntent())
        } else {
            return toggle(isOn: isOn, action: LegacyToggleGlyphIntent())
        }
    }

    private static func toggle<Action: SetValueIntent>(isOn: Bool, action: Action) -> some ControlWidgetTemplate
    where Action.ValueType == Bool {
        ControlWidgetToggle(isOn: isOn, action: action) {
            Text("Dynamic Glyph", comment: "The Control Center switch's name, the same in every language.")
        } valueLabel: { isOn in
            if isOn {
                Label {
                    Text("On", comment: "The Control Center switch's state while the screen is being read.")
                } icon: {
                    Image("dynamicglyph.control")
                }
                .controlWidgetActionHint(Text("Stop Dynamic Glyph",
                                              comment: "The Control Center switch's action while it is on: stops reading the screen without opening the app."))
            } else {
                Label {
                    Text("Off", comment: "The Control Center switch's state while the screen is not being read.")
                } icon: {
                    Image("dynamicglyph.control")
                }
                .controlWidgetActionHint(Text("Start Dynamic Glyph",
                                              comment: "The Control Center switch's action while it is off: opens the app to start reading the screen."))
            }
        }
        // The chosen theme's tint; the app's blue by default.
        .tint(AppTheme.mirrored.controlTint)
    }
}

/// On while the app or the broadcast extension reports a capture with a
/// fresh heartbeat. A process that crashed stops reporting, and its last
/// report goes stale.
struct CaptureValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        ControlCaptureStore.appGroup?.isOn() ?? false
    }
}
