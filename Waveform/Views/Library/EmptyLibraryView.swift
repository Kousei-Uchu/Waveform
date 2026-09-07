import SwiftUI

/// Shown when the library has nothing in it yet. Unlike the old
/// `.cmf`-era version there's nothing to "add" here anymore — content
/// only arrives via the Search & Download screen's Download action
/// (§2 "empty library at first launch", §8 "everything arrives through
/// Acquire") — so this just points there instead of offering an import
/// flow.
struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No music yet")
                .font(.title3.weight(.semibold))
            Text("Find something on the Search tab and tap Download to add it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
