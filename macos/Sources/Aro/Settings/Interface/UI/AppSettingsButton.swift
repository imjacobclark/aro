import AroCommon

import SwiftUI

struct AppSettingsButton: View {
    var body: some View {
        SettingsLink {
            Image(systemName: "gearshape")
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .frame(width: 40, height: 40)
        .help("Playback Settings")
        .accessibilityLabel("Playback Settings")
    }
}
