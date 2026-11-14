# Third-Party Licenses & Notices

This application links dynamically against `libsevenzip.dylib`, built from the official **7-Zip 26.06** source code (`https://www.7-zip.org/`, `https://github.com/ip7z/7zip`).

---

## 7-Zip License & Attribution

7-Zip Copyright (C) 1999–2026 Igor Pavlov.

- **Main license**: GNU Lesser General Public License (LGPL) version 2.1 or later.
- **LZFSE & ZSTD decompression code**: BSD 3-Clause License (Copyright (c) 2015–2016 Apple Inc.; Copyright (c) Facebook, Inc.; Copyright (c) 2023–2026 Igor Pavlov).
- **XXH64 code**: BSD 2-Clause License (Copyright (c) 2012–2021 Yann Collet; Copyright (c) 2023–2026 Igor Pavlov).
- **RAR decompression engine (`unRAR` restriction)**:
  - All copyrights to original unRAR code are owned by Alexander Roshal.
  - **Restriction notice**: The unRAR sources may be used in any software to handle RAR archives without limitations free of charge, **but may not be used to re-create the RAR compression algorithm, which is proprietary, nor to develop a RAR (WinRAR) compatible archiver**.

### Replacing or Relinking `libsevenzip.dylib` (LGPL-2.1 §6)
`libsevenzip.dylib` is built as a standalone dynamic library (`@rpath/libsevenzip.dylib`) from `Vendor/7zip` and `Bridge/sevenzip_bridge.cpp`. Users may modify those sources and rebuild a drop-in replacement `libsevenzip.dylib` using `Scripts/build-7zip.sh`, then place the resulting library in `Contents/Frameworks/libsevenzip.dylib` inside the application bundle.

Full upstream license texts are preserved in `Vendor/7zip/DOC/License.txt`, `Vendor/7zip/DOC/copying.txt`, and `Vendor/7zip/DOC/unRarLicense.txt`.
