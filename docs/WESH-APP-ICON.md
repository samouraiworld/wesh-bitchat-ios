# Wesh app icon

The app icon uses the existing geometric W on an opaque `#000000` canvas.
Its polished-silver stroke uses neutral RGB stops `#B6B6B6`, `#FFFFFF`,
`#CFCFCF`, `#F5F5F5`, and `#B6B6B6`, running from the upper left to the
lower right. This retains a clear silhouette at small launcher sizes and the
default silver-on-black direction. No green or blue field is used.

The editable vector is [WeshAppIcon.svg](../design/WeshAppIcon.svg). The
[native Swift renderer](../scripts/render-wesh-app-icon.swift) implements the
same geometry, gradient coordinates, and stops without third-party dependencies.
From the checkout root, regenerate all named Debug and Release asset slots with:

```sh
swift -module-cache-path .validation/icon-module-cache scripts/render-wesh-app-icon.swift
```

Both asset sets deliberately have the same artwork. The renderer follows each
asset catalog's `Contents.json` sizes and scales. It writes opaque PNGs, leaving
iOS to apply its launcher mask. Existing macOS slots receive the same square
artwork; this change does not qualify a macOS release or add a macOS icon mask.

This is an app-resource change, so its candidate is **RC5, version 0.1.0 (6)**.
The RC4 archive and simulator package retain their original build number, source,
and inherited blue icon. Do not replace their files or attribute the new artwork
to those artifacts. RC5 build/test/signing evidence is recorded separately under
ignored `.validation/`; changing the icon does not establish VoiceOver, radio,
or Distribution-signing qualification.
