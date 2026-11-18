import FlotsamBase
import SwiftUI

extension Color {
    /// The colour a colour item's `ColorChannels` draws as (the Library preview's swatch and the Shelf card's).
    init(_ value: ColorChannels) {
        self.init(red: Double(value.red) / 255, green: Double(value.green) / 255, blue: Double(value.blue) / 255)
    }
}
