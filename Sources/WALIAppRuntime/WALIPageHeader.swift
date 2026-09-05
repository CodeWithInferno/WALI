import SwiftUI

/// Page titles and actions share spacing while the window titlebar stays still.
struct WALIPageHeader<Actions: View>: View {
    let title: String
    private let actions: Actions

    init(_ title: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            actions
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}
