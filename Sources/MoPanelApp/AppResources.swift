import Foundation

enum AppResources {
    /// Packaged apps must resolve self-contained resources, never a developer's
    /// absolute .build path embedded by the SwiftPM-generated Bundle.module.
    static var bundle: Bundle? {
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let resources = Bundle.main.resourceURL else { return nil }
            return Bundle(url: resources.appendingPathComponent("MoPanel_MoPanelApp.bundle", isDirectory: true))
        }
        return Bundle.module
    }
}
