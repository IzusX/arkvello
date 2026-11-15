import AppKit
import SwiftUI

/// Service launches share the browser's dialogs without showing the browser itself.
struct FinderOperationView: View {
    @ObservedObject var appVM: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let state = appVM.operationBanner
            Label(state?.title ?? "Arkvello", systemImage: state?.isError == true ? "exclamationmark.triangle" : "archivebox")
                .font(.headline)
            Text(state?.detail ?? "Параметры операции…")
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if state?.isRunning == true {
                if let fraction = state?.fraction {
                    ProgressView(value: fraction)
                    Text("\(Int(fraction * 100))%")
                        .monospacedDigit()
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            HStack {
                Spacer()
                if state?.isRunning == true {
                    Button("Отмена") { appVM.cancelRunningOperation() }
                } else {
                    Button("Закрыть") { NSApp.keyWindow?.performClose(nil) }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
