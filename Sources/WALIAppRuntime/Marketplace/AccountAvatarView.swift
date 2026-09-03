import SwiftUI

/// Circular monogram used by the Account page and sidebar, matching the
/// System Settings Apple ID treatment without requesting a contact photo.
struct WALIAccountAvatarView: View {
    let displayName: String?
    var size: CGFloat = 72

    var body: some View {
        let initials = WALIAccountAvatar.initials(from: displayName ?? "")
        ZStack {
            Circle()
                .fill(.quaternary)
            if initials.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Circle()
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}
