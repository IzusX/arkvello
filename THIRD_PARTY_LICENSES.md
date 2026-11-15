# Third-Party Licenses & Notices

Arkvello is an independent macOS application with a SwiftUI/AppKit interface. It dynamically links against `libsevenzip.dylib`, built from **7-Zip 26.06** sources in `Vendor/7zip` and the LGPL-2.1-or-later bridge in `Bridge/sevenzip_bridge.cpp`. Arkvello is not an official version of 7-Zip and is not affiliated with or endorsed by Igor Pavlov or the 7-Zip project.

Official 7-Zip website: https://www.7-zip.org/
Upstream source repository: https://github.com/ip7z/7zip
Arkvello source repository: https://github.com/IzusX/arkvello

## License scope

The root `LICENSE` grants MIT terms for original Arkvello application code, documentation and build scripts, Copyright (c) 2026 IzusX, subject to its stated exclusions. It does not relicense `Vendor/7zip`, upstream material, or the bridge compiled into the LGPL engine. The complete application bundle is **not solely MIT-licensed**.

The bridge compiled into `libsevenzip.dylib` is licensed under GNU LGPL version 2.1 or later, as stated in its source headers. The engine's upstream files retain their respective LGPL, BSD, public-domain notices and unRAR restriction described below.

## Complete license texts shipped with the project

Preserve these upstream files verbatim, together with applicable source-file notices:

- `Vendor/7zip/DOC/License.txt`: upstream license allocation, LGPL notice, complete BSD notices and unRAR restriction.
- `Vendor/7zip/DOC/copying.txt`: complete GNU Lesser General Public License, version 2.1.
- `Vendor/7zip/DOC/unRarLicense.txt`: complete upstream unRAR license notice.

Binary distributions must include those full texts together with this notice and the root `LICENSE`; a summary or website link does not replace them. The upstream BSD notices and unRAR notice are also reproduced below.

## 7-Zip license allocation and LGPL notice

7-Zip Copyright (C) 1999-2026 Igor Pavlov.

As specified by upstream `License.txt`:

- `CPP/7zip/Compress/Rar*` files: GNU LGPL with the unRAR license restriction; both sets of rules apply.
- `CPP/7zip/Compress/LzfseDecoder.cpp` and `C/ZstdDec.c`: BSD 3-Clause License.
- `C/Xxh64.c`: BSD 2-Clause License.
- Some files are public domain where stated in their sources.
- All other files: GNU LGPL; a file without separate license information is under GNU LGPL.

> This library is free software; you can redistribute it and/or
> modify it under the terms of the GNU Lesser General Public
> License as published by the Free Software Foundation; either
> version 2.1 of the License, or (at your option) any later version.
>
> This library is distributed in the hope that it will be useful,
> but WITHOUT ANY WARRANTY; without even the implied warranty of
> MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
> Lesser General Public License for more details.
>
> You should have received a copy of the GNU Lesser General Public
> License along with this library; if not,
> you can get a copy of the GNU Lesser General Public License from
> http://www.gnu.org/

## BSD 3-Clause notice: LZFSE and ZSTD decompression

The LZFSE decompression code was derived from Apple's LZFSE compression library. The ZSTD decompression code was developed using the original Facebook zstd decoder as reference code.

```text
Copyright (c) 2015-2016, Apple Inc. All rights reserved.
Copyright (c) Facebook, Inc. All rights reserved.
Copyright (c) 2023-2026 Igor Pavlov.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may
   be used to endorse or promote products derived from this software without
   specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## BSD 2-Clause notice: XXH64

The XXH64 code in 7-Zip was derived from the original XXH64 code developed by Yann Collet.

```text
Copyright (c) 2012-2021 Yann Collet.
Copyright (c) 2023-2026 Igor Pavlov.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## unRAR license restriction

The decompression engine for RAR archives was developed using source code of the unRAR program. All copyrights to original unRAR code are owned by Alexander Roshal. In addition to GNU LGPL, the upstream restriction states:

```text
The unRAR sources cannot be used to re-create the RAR compression algorithm,
which is proprietary. Distribution of modified unRAR sources in separate form
or as a part of other software is permitted, provided that it is clearly
stated in the documentation and source comments that the code may
not be used to develop a RAR (WinRAR) compatible archiver.
```

Arkvello uses this code for RAR decompression, not RAR compression. The full accompanying `unRarLicense.txt` notice is reproduced here:

```text
 ******    *****   ******   unRAR - free utility for RAR archives
 **   **  **   **  **   **  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 ******   *******  ******    License for use and distribution of
 **   **  **   **  **   **   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
 **   **  **   **  **   **         FREE portable version
                                   ~~~~~~~~~~~~~~~~~~~~~

      The source code of unRAR utility is freeware. This means:

   1. All copyrights to RAR and the utility unRAR are exclusively
      owned by the author - Alexander Roshal.

   2. The unRAR sources may be used in any software to handle RAR
      archives without limitations free of charge, but cannot be used
      to re-create the RAR compression algorithm, which is proprietary.
      Distribution of modified unRAR sources in separate form or as a
      part of other software is permitted, provided that it is clearly
      stated in the documentation and source comments that the code may
      not be used to develop a RAR (WinRAR) compatible archiver.

   3. The unRAR utility may be freely distributed. No person or company
      may charge a fee for the distribution of unRAR without written
      permission from the copyright holder.

   4. THE RAR ARCHIVER AND THE UNRAR UTILITY ARE DISTRIBUTED "AS IS".
      NO WARRANTY OF ANY KIND IS EXPRESSED OR IMPLIED. YOU USE AT
      YOUR OWN RISK. THE AUTHOR WILL NOT BE LIABLE FOR DATA LOSS,
      DAMAGES, LOSS OF PROFITS OR ANY OTHER KIND OF LOSS WHILE USING
      OR MISUSING THIS SOFTWARE.

   5. Installing and using the unRAR utility signifies acceptance of
      these terms and conditions of the license.

   6. If you don't agree with terms of the license you must remove
      unRAR files from your storage devices and cease to use the
      utility.

      Thank you for your interest in RAR and unRAR.

                                            Alexander L. Roshal
```

## Source availability and replacing the LGPL library

Each public binary release must supply `Arkvello-VERSION-source.tar.gz` alongside `Arkvello-VERSION-universal.dmg`. Obtain both from the matching version at https://github.com/IzusX/arkvello/releases. The source archive must contain the actual corresponding project tree, including `Vendor/7zip`, bridge source and modifications, build scripts and all license texts; a moving upstream link is not a substitute.

`libsevenzip.dylib` is a separate dynamically linked library (`@rpath/libsevenzip.dylib`), not code statically incorporated into the SwiftUI/AppKit executable. Recipients may modify its sources and rebuild a replacement:

1. Unpack the source archive matching the binary release and install the build prerequisites in `docs/DISTRIBUTION.md`.
2. Modify `Vendor/7zip` and/or `Bridge/sevenzip_bridge.cpp` as needed, preserving the applicable notices.
3. From the source root run `ARCHS='arm64 x86_64' bash Scripts/build-7zip.sh`.
4. In a writable copy of `Arkvello.app`, replace `Contents/Frameworks/libsevenzip.dylib` with the rebuilt `Vendor/lib/libsevenzip.dylib`.
5. Re-sign and verify the modified local bundle as described in `docs/DISTRIBUTION.md`. Changing a signed bundle invalidates its old signature; local ad-hoc signing is not Apple notarization.

The library must remain interface-compatible with the app. See the full LGPL, especially §6, for applicable recipient rights and distributor obligations, including modification and reverse engineering for debugging those modifications. The project does not impose a restriction on exercising those LGPL rights. Keep the corresponding source assets and notices available to recipients as required by the applicable licenses.
