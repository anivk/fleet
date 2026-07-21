package tray

import _ "embed"

// Menubar icon: a koala. Idle it's a clean black-and-white koala — a macOS
// template, so it auto-inverts (white on a dark bar, black on a light one). When
// a session needs your attention it turns vermillion. The template +
// regular pair feeds SetTemplateIcon (mac auto light/dark; regular used on Linux);
// the vermillion alert is a colored icon set via SetIcon.

//go:embed assets/koala-template.png
var iconKoalaTemplate []byte

//go:embed assets/koala-regular.png
var iconKoalaRegular []byte

//go:embed assets/koala-alert.png
var iconKoalaAlert []byte
