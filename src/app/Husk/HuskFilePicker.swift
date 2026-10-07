// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system's file picker, presented from UIKit.
///
/// SwiftUI's `.fileImporter` is attached to a view, and it is known to go quiet -- the picker's Open button
/// does nothing -- when more than one is attached anywhere above or beside it, or when its host view is rebuilt
/// while it is up. This is presented from the topmost view controller instead, with nothing of the view tree
/// involved, and a failure is reported rather than dropped.
@MainActor
enum HuskFilePicker {
    private static var live: Coordinator?

    static func present(types: [UTType] = [.item], multiple: Bool = true,
                        onPick: @escaping ([URL]) -> Void, onFail: ((String) -> Void)? = nil) {
        guard live == nil else { return }
        // asCopy: true, deliberately, and it is not about wanting a copy.
        //
        // asCopy: false hands back a security-scoped URL for a file that still
        // belongs to whichever provider it came from, so iOS has to issue this
        // app a sandbox extension for it before it can be read. An install iOS
        // did not sign -- which is every TrollStore one -- cannot be given that
        // extension, and the failure carries no error to report: the picker's
        // Open button does nothing, the picker never dismisses, and no delegate
        // call ever arrives. That is the whole of "I picked the APK and nothing
        // happened". Asking for a copy has the picker put the file inside Husk's
        // own container first, where nothing needs to be extended to us; it is
        // also what makes a file that lives in iCloud work, because the copy is
        // what fetches it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = multiple
        let coordinator = Coordinator(onPick: onPick)
        picker.delegate = coordinator
        live = coordinator
        guard let top = topController() else {
            live = nil
            onFail?("There is no screen to show the file picker on.")
            return
        }
        HuskLog.log("ui", "file picker: presenting from \(type(of: top))")
        // On the next turn of the run loop, not inside the view update that asked
        // for it: a picker raised while its presenter is still settling comes up
        // and then never completes, which looks identical to the failure above.
        Task { @MainActor in top.present(picker, animated: true) }
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.flatMap { $0.windows }.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    private final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            HuskLog.log("ui", "file picker: \(urls.count) picked: " + urls.map(\.lastPathComponent).joined(separator: ", "))
            HuskFilePicker.live = nil
            if !urls.isEmpty { onPick(urls) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            HuskLog.log("ui", "file picker: cancelled")
            HuskFilePicker.live = nil
        }
    }
}

extension View {
    /// Present the file picker when `isPresented` turns true (and turn it back off), calling `onPick` with what was chosen.
    func huskFilePicker(isPresented: Binding<Bool>, types: [UTType] = [.item], multiple: Bool = true,
                        onPick: @escaping ([URL]) -> Void) -> some View {
        onChange(of: isPresented.wrappedValue) { shown in
            guard shown else { return }
            isPresented.wrappedValue = false
            HuskFilePicker.present(types: types, multiple: multiple, onPick: onPick)
        }
    }
}
