// osascript -l JavaScript; no clipboard or application activation.
function run() {
    "use strict";
    try {
        var events = Application("System Events");
        var front = "";
        // The Script Command may briefly leave Raycast as the foreground app.
        for (var i = 0; i < 6; i++) {
            var processes = events.applicationProcesses.whose({frontmost: true})();
            if (!processes.length) throw new Error("frontmost unavailable");
            front = processes[0].name();
            if (front !== "Raycast") break;
            delay(0.1);
        }
        if (front === "Notion") throw new Error("Notion desktop requires local capability verification");
        if (front !== "Arc") throw new Error("unsupported foreground application");

        var arc = Application("Arc");
        var windows = arc.windows();
        if (!windows.length) throw new Error("no Arc window");
        var window = arc.windows[0];
        var windowId = window.id();
        var tab = window.activeTab;
        var tabId = tab.id();
        var title = tab.title();
        var url = tab.url();
        // Detect tab or window changes while reading both fields.
        if (arc.windows[0].id() !== windowId ||
            arc.windows[0].activeTab.id() !== tabId ||
            arc.windows[0].activeTab.title() !== title ||
            arc.windows[0].activeTab.url() !== url) {
            throw new Error("active page changed");
        }
        if (typeof title !== "string" || typeof url !== "string") throw new Error("missing fields");
        return JSON.stringify({title: title, url: url});
    } catch (_) {
        // Never expose private page titles or URLs in diagnostics.
        throw new Error("現在表示しているページの取得に失敗しました");
    }
}
