# Third-Party Notices

Wuji S1 embeds the ARM64 iSH executor core from the user-designated local source
`references/sources/ish-arm64-master`. The public repository gitlink is the
content-addressed reproducible identity proven byte-for-byte identical to that
local snapshot; it does not make OpenMinis Runtime or its host integration part
of Wuji.

- iSH source: `https://github.com/OpenMinis/ish-arm64.git` at
  `de124dd66124a15239cea1465164f74980ada245`.
- libarchive source: `https://github.com/libarchive/libarchive.git` at
  `fc6563f5130d8a7ee1fc27c0e55baef35119f26c`.
- Alpine minirootfs is a verified build/test input and is not committed or
  uploaded as an artifact.

iSH licensing and iOS additional terms are reproduced in `Licenses/`. The
complete GPLv3 and GPLv2 texts and libarchive `COPYING` are also included there.
See `MODIFICATIONS.md` for the Wuji-owned integration boundary.
