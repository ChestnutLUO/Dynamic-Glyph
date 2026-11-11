# Notice

Required Notice: Copyright (c) 2026 ChestnutLUO (https://github.com/ChestnutLUO)

The code in this repository is available under the
[PolyForm Noncommercial License 1.0.0](LICENSE). That licence covers the code and its
documentation. It does not cover the things below.

## The Dynamic Glyph name and icons

The name "Dynamic Glyph" and the app's icons are reserved by ChestnutLUO and
are not licensed, under the PolyForm Noncommercial License or otherwise. A
copy or changed version you share must use its own name and icon, so that
nobody mistakes it for this app. That covers every variant of the icon in this
repository:

- `Apps/DynamicGlyph/DynamicGlyph.icon/Assets/DynamicGlyph-Box.svg`
- `Apps/DynamicGlyph/DynamicGlyph.icon/Assets/DynamicGlyph-Cover.svg`
- `Apps/DynamicGlyph/Widget/AppMark.xcassets/AppMark.imageset/AppMark@2x.png`
- `Apps/DynamicGlyph/Widget/AppMark.xcassets/AppMark.imageset/AppMark@3x.png`
- `Apps/DynamicGlyph/Widget/AppMark.xcassets/AppMark.imageset/AppMark-dark@2x.png`
- `Apps/DynamicGlyph/Widget/AppMark.xcassets/AppMark.imageset/AppMark-dark@3x.png`
- `Apps/DynamicGlyph/Widget/ControlSymbols.xcassets/dynamicglyph.control.symbolset/user-control-symbol.svg`

## The game

Ingress is a trademark of Niantic Spatial, Inc. This project is not affiliated
with or endorsed by Niantic Spatial. The game's name is used here only to say
which game the app works with.

The game's imagery, text and other trademarks belong to their owners and are
not licensed here. Screenshots of the game are not included in this
repository. The game's interface text in `Docs/GAME_TEXT_TRANSLATIONS*.csv`
and in the recognition code is quoted only so that the app can recognise it.

## Portal key counting

The portal key counting in `Packages/GlyphRecognition` is a port of
[CountIngressKeys](https://github.com/Choujingress/CountIngressKeys) by
chouj, used under the MIT License:

> Copyright (c) 2018 chouj — MIT License. Permission is hereby granted, free
> of charge, to any person obtaining a copy of this software and associated
> documentation files (the "Software"), to deal in the Software without
> restriction, including without limitation the rights to use, copy, modify,
> merge, publish, distribute, sublicense, and/or sell copies of the Software,
> subject to including the above copyright notice and this permission notice
> in all copies or substantial portions of the Software. THE SOFTWARE IS
> PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.

The port rewrites the original MATLAB for Swift and Vision; its algorithm,
thresholds and measured layout fractions carry this notice.

## Reference tables

The Glyph and sequence reference tables some tests use are third-party data
and are not distributed here. See their
[provenance](Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures/PROVENANCE.md).
