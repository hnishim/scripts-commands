// Single read-only source boundary for notion-textlint-current-page.sh.
// The Accessibility implementation is kept in Swift because JXA's
// System Events bridge is not consistent across the supported applications.

ObjC.import("Foundation");

function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'";
}

function run() {
    var current = Application.currentApplication();
    current.includeStandardAdditions = true;
    var environment = $.NSProcessInfo.processInfo.environment;
    var helper = environment.objectForKey("HIR282_SOURCE_HELPER");
    if (!helper) throw new Error("source helper unavailable");
    var helperPath = shellQuote(ObjC.unwrap(helper));
    var command = [
        "tmp_dir=$(mktemp -d \"${TMPDIR:-/tmp}/hir-282-ax.XXXXXX\") || exit 1",
        "trap 'rm -rf -- \"$tmp_dir\"' EXIT",
        "/usr/bin/swiftc " + helperPath + " -o \"$tmp_dir/helper\" >/dev/null 2>&1 || exit 1",
        "\"$tmp_dir/helper\"",
    ].join("; ");
    return current.doShellScript(command);
}

run();
