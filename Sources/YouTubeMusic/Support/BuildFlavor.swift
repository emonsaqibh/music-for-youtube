import SwiftUI

/// Which of the two builds this is. The dev build (`./build.sh`) runs alongside the
/// installed beta, so it marks itself — its own log folder, a blue icon, and a badge on
/// Home — to make it obvious which one is in front.
enum BuildFlavor {
    static let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true

    /// Matches the dev icon's gradient (`build.sh`).
    static let devColor = Color(red: 0.16, green: 0.42, blue: 0.95)
}
