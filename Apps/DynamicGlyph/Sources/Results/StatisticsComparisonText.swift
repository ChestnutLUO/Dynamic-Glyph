import SwiftUI

/// A comparison sentence with only its number coloured: the words stay
/// secondary, so the colour is never the only sign of which way it went.
func comparisonText(_ sentence: AttributedString, color: Color?) -> Text {
    Text(styledComparison(sentence, color: color))
}

/// Style the template's emphasized delta, not matching digits in its prose.
/// Markdown emphasis survives reordered translations and plural expansion.
func styledComparison(_ sentence: AttributedString, color: Color?) -> AttributedString {
    var text = sentence
    if let color {
        for run in sentence.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            text[run.range][AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = color
            text[run.range][AttributeScopes.SwiftUIAttributes.FontAttribute.self] = Font.footnote.weight(.semibold)
        }
    }
    return text
}
