import SwiftUI

/// Decorative artwork resolved from the app that hosts this static UI module.
public struct WALIBrandMark: View {
    public init() {}

    public var body: some View {
        Image("WALIMark", bundle: .main)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}
