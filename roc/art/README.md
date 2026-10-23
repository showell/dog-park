# The critters' art, for the game on roc-ray

The page draws each critter as an emoji in the browser's own emoji font
(`solo/scene.js`: `dog_looks` by breed, and each kind's `emoji` in
`roc/World.roc`). raylib, which roc-ray draws with, cannot draw a colour
emoji font, so `roc/native.roc` draws these images of the same emoji
instead, compiled into the program (`Assets.texture_from_bytes!`).

| file | emoji | drawn for |
|---|---|---|
| `1f415.png` | 🐕 | a dog of breed 0 |
| `1f429.png` | 🐩 | breed 1 |
| `1f9ae.png` | 🦮 | breed 2 |
| `1f415-200d-1f9ba.png` | 🐕‍🦺 | breed 3 |
| `1f404.png` | 🐄 | a cow |
| `1f413.png` | 🐓 | a chicken |
| `1f410.png` | 🐐 | a goat |

They are [Twemoji](https://github.com/jdecked/twemoji) 15.1.0, the 72 by 72
PNGs, unchanged: Copyright 2019 Twitter, Inc and other contributors, and
2024 onward the jdecked/twemoji contributors, licensed under
[CC-BY 4.0](https://creativecommons.org/licenses/by/4.0/). Fetched from
`https://cdn.jsdelivr.net/gh/jdecked/twemoji@15.1.0/assets/72x72/<name>.png`.
