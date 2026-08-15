# Window chrome — sidebars, toolbars, traffic lights

**Every fact here is verified against the AppKit headers in the installed SDK**, not recalled. Where a header sentence settles the point it is quoted, because this is the area where plausible-but-wrong recall is most expensive: the code compiles, runs, and silently does nothing.

Header path, if you need to check something not covered:

```
/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Headers/
```

---

## The full-height sidebar (the Safari pattern)

A sidebar that runs top to bottom with the traffic lights sitting over it, and the toolbar content aligned to the right of the split divider. This is Safari, Finder, Mail, Notes — it is the standard macOS shape, not a custom one, and it is built from parts the system supplies.

**The system item that does it:**

```swift
NSToolbarItem.Identifier.sidebarTrackingSeparator   // macOS 11+
NSToolbarItem.Identifier.inspectorTrackingSeparator // macOS 14+
```

The header on the first:

> Creates a new `NSTrackingSeparatorToolbarItem` and automatically configures it to track the divider of the sidebar if one is discovered.
> **Only applies to windows with `NSWindowStyleMaskFullSizeContentView` applied.**

Two things follow, and both are load-bearing:

1. **You do not construct the separator yourself for the sidebar case.** Put `.sidebarTrackingSeparator` in the toolbar's item identifiers and the system builds and configures it. Minting your own `NSToolbarItem.Identifier("MyTrackingSeparator")` and hand-feeding it a split view reinvents this, and loses the automatic divider discovery.
2. **It silently does nothing without `.fullSizeContentView`** on the window's style mask. No warning, no crash — the separator just never aligns. If the sidebar is not going full height, check the style mask before anything else.

**`.trackingSeparator` does not exist.** Reaching for it produces:

```
error: type 'NSToolbarItem.Identifier' has no member 'trackingSeparator'
```

The correct spelling is `.sidebarTrackingSeparator`. This is worth stating because the wrong name is the plausible one.

**When you genuinely need a manual separator** — a non-sidebar divider, or a second one — the factory is:

```swift
NSTrackingSeparatorToolbarItem(
    identifier: myIdentifier, splitView: splitView, dividerIndex: 0)
```

Header constraints on it: the split view must be in the same window as the toolbar by the time the toolbar is shown, and **only vertical split views are supported.**

---

## `toggleSidebar(_:)` no-ops without a sidebar item

From `NSSplitViewController.h`, verbatim:

> Collapses or expands the first sidebar in the split view controller using an animation.
> **If the split view controller doesn't contain a sidebar, calling this method does nothing.**

"Contains a sidebar" means a split view item whose `behavior` is `.sidebar`. So:

```swift
let sidebarItem = NSSplitViewItem(sidebarWithViewController: vc)  // behavior == .sidebar
```

**The failure mode is silent.** Build the split view with a plain `NSSplitViewItem`, wire up a `.toggleSidebar` toolbar button, and you get a button that looks correct, validates, and does nothing when clicked. There is no error to search for. If a sidebar toggle is inert, check `behavior` first.

`NSSplitViewController` also validates items with an action of `toggleSidebar:` to reflect the sidebar item's state, which is why the standard `.toggleSidebar` toolbar item gets its enabled/disabled behaviour for free — another reason to use it rather than a custom button.

**Overriding it** is legitimate when the item you want toggled is not the first sidebar, but say why in a comment, because the override defeats the built-in validation:

```swift
override func toggleSidebar(_ sender: Any?) {
    sidebarItem.animator().isCollapsed.toggle()
}
```

---

## Traffic lights and the toolbar band

The window controls sit at a fixed position in the window's top-left. Making a sidebar run underneath them is a matter of the sidebar's frame reaching the top, not of moving the buttons.

- `.fullSizeContentView` in the style mask lets content extend under the titlebar.
- `titlebarAppearsTransparent` and `titleVisibility = .hidden` remove the visible band.
- **Removing the toolbar entirely is a real option**, and sometimes the only one. A single toolbar item is enough to make the system draw the titlebar band back across the top — in SwiftUI, the automatic sidebar toggle is a toolbar item, so `.toolbar(removing: .sidebarToggle)` may be required to get a genuinely full-height sidebar.
- **Do not hardcode the band height or the button rects.** Derive them: `NSWindow.frameRect(forContentRect:styleMask:)` for the band, and `window.standardWindowButton(_:)?.frame` for the buttons. These change with OS version and with the style mask, and a hardcoded 28 or 32 is wrong on some configuration you have not tested.

---

## Checklist for any window-chrome work

- [ ] `.fullSizeContentView` set, if anything is meant to extend under the titlebar
- [ ] Sidebar item created with `NSSplitViewItem(sidebarWithViewController:)`, so its `behavior` is `.sidebar`
- [ ] Sidebar tracking separator is the **system** `.sidebarTrackingSeparator`, not a minted identifier
- [ ] Band heights and button positions are **derived**, never literal
- [ ] Toggle actually toggles — clicked and observed, not assumed from the code reading correctly
- [ ] Screenshotted and looked at, both sidebar-open and sidebar-collapsed
