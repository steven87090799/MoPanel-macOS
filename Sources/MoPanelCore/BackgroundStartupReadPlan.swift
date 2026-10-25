// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One fixed, read-only request. No caller-supplied command, path, credential,
/// report content or identifier can become privileged script source.
public enum BackgroundStartupReadPlan {
    public static let authorizedTimeout: TimeInterval = 120
    public static let rootExecutionLimitSeconds = 12
    public static let outputLimit = 2 * 1024 * 1024
    // alarm survives exec: even if the GUI/authorization client disappears,
    // the root query cannot continue indefinitely. No files are written.
    public static let rootCommand = #"/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C LANG=C /usr/bin/perl -T -e '$ENV{PATH}="/usr/bin:/bin:/usr/sbin:/sbin"; alarm 12; exec {"/usr/bin/sfltool"} "/usr/bin/sfltool", "dumpbtm"; exit 127;'"#
    public static func authorizationScript(english: Bool) -> String {
        let prompt = english
            ? "MoPanel needs to read the complete login and background-item list. This read-only check does not change settings."
            : "MoPanel 需要讀取完整的登入與背景項目清單。這次只會讀取資料，不會變更任何設定。"
        return "do shell script " + literal(rootCommand) + " with administrator privileges with prompt " + literal(prompt) + " without altering line endings"
    }
    public static func authorizationWasCancelled(stderr: String) -> Bool {
        stderr.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("(-128)")
    }
    private static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
