import SwiftUI

/// Compatibility type retained so existing navigation code does not need to
/// migrate in the same commit. The implementation is the corrected Noiro
/// device-generated pairing flow, not the retired Noiro account handoff.
struct NoiroAccountJoinerView: View {
    var onSignedIn: () -> Void

    var body: some View {
        NoiroPairingView(autoStart: true, onPaired: onSignedIn)
            .frame(maxWidth: 860)
    }
}
