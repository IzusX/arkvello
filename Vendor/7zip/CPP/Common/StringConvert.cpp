// Common/StringConvert.cpp

#include "StdAfx.h"

#include "StringConvert.h"

#ifndef _WIN32
// #include <stdio.h>
#include <stdlib.h>
#endif

#if !defined(_WIN32) || defined(ENV_HAVE_LOCALE)
#include "UTFConvert.h"
#endif

#ifdef ENV_HAVE_LOCALE
#include <locale.h>
#endif

static const char k_DefultChar = '_';

#ifdef _WIN32

/*
MultiByteToWideChar(CodePage, DWORD dwFlags,
    LPCSTR lpMultiByteStr, int cbMultiByte,
    LPWSTR lpWideCharStr, int cchWideChar)

  if (cbMultiByte == 0)
    return: 0. ERR: ERROR_INVALID_PARAMETER

  if (cchWideChar == 0)
    return: the required buffer size in characters.

  if (supplied buffer size was not large enough)
    return: 0. ERR: ERROR_INSUFFICIENT_BUFFER
    The number of filled characters in lpWideCharStr can be smaller than cchWideChar (if last character is complex)

  If there are illegal characters:
    if MB_ERR_INVALID_CHARS is set in dwFlags:
      - the function stops conversion on illegal character.
      - Return: 0. ERR: ERROR_NO_UNICODE_TRANSLATION.
    
    if MB_ERR_INVALID_CHARS is NOT set in dwFlags:
      before Vista: illegal character is dropped (skipped). WinXP-64: GetLastError() returns 0.
      in Vista+:    illegal character is not dropped (MSDN). Undocumented: illegal
                    character is converted to U+FFFD, which is REPLACEMENT CHARACTER.
*/


void MultiByteToUnicodeString2(UString &dest, const AString &src, UINT codePage)
{
  dest.Empty();
  if (src.IsEmpty())
    return;
  {
    /*
    wchar_t *d = dest.GetBuf(src.Len());
    const char *s = (const char *)src;
    unsigned i;
    
    for (i = 0;;)
    {
      Byte c = (Byte)s[i];
      if (c >= 0x80 || c == 0)
        break;
      d[i++] = (wchar_t)c;
    }

    if (i != src.Len())
    {
      unsigned len = MultiByteToWideChar(codePage, 0, s + i,
          src.Len() - i, d + i,
          src.Len() + 1 - i);
      if (len == 0)
        throw 282228;
      i += len;
    }

    d[i] = 0;
    dest.ReleaseBuf_SetLen(i);
    */
    unsigned len = (unsigned)MultiByteToWideChar(codePage, 0, src, (int)src.Len(), NULL, 0);
    if (len == 0)
    {
      if (GetLastError() != 0)
        throw 282228;
    }
    else
    {
      len = (unsigned)MultiByteToWideChar(codePage, 0, src, (int)src.Len(), dest.GetBuf(len), (int)len);
      if (len == 0)
        throw 282228;
      dest.ReleaseBuf_SetEnd(len);
    }
  }
}

/*
  int WideCharToMultiByte(
      UINT CodePage, DWORD dwFlags,
      LPCWSTR lpWideCharStr, int cchWideChar,
      LPSTR lpMultiByteStr, int cbMultiByte,
      LPCSTR lpDefaultChar, LPBOOL lpUsedDefaultChar);

if (lpDefaultChar == NULL),
  - it uses system default value.

if (CodePage == CP_UTF7 || CodePage == CP_UTF8)
  if (lpDefaultChar != NULL || lpUsedDefaultChar != NULL)
    return: 0. ERR: ERROR_INVALID_PARAMETER.

The function operates most efficiently, if (lpDefaultChar == NULL && lpUsedDefaultChar == NULL)

*/

static void UnicodeStringToMultiByte2(AString &dest, const UString &src, UINT codePage, char defaultChar, bool &defaultCharWasUsed)
{
  dest.Empty();
  defaultCharWasUsed = false;
  if (src.IsEmpty())
    return;
  {
    /*
    unsigned numRequiredBytes = src.Len() * 2;
    char *d = dest.GetBuf(numRequiredBytes);
    const wchar_t *s = (const wchar_t *)src;
    unsigned i;
    
    for (i = 0;;)
    {
      wchar_t c = s[i];
      if (c >= 0x80 || c == 0)
        break;
      d[i++] = (char)c;
    }
    
    if (i != src.Len())
    {
      BOOL defUsed = FALSE;
      defaultChar = defaultChar;

      bool isUtf = (codePage == CP_UTF8 || codePage == CP_UTF7);
      unsigned len = WideCharToMultiByte(codePage, 0, s + i, src.Len() - i,
          d + i, numRequiredBytes + 1 - i,
          (isUtf ? NULL : &defaultChar),
          (isUtf ? NULL : &defUsed));
      defaultCharWasUsed = (defUsed != FALSE);
      if (len == 0)
        throw 282229;
      i += len;
    }

    d[i] = 0;
    dest.ReleaseBuf_SetLen(i);
    */

    /*
    if (codePage != CP_UTF7)
    {
      const wchar_t *s = (const wchar_t *)src;
      unsigned i;
      for (i = 0;; i++)
      {
        wchar_t c = s[i];
        if (c >= 0x80 || c == 0)
          break;
      }
      
      if (s[i] == 0)
      {
        char *d = dest.GetBuf(src.Len());
        for (i = 0;;)
        {
          wchar_t c = s[i];
          if (c == 0)
            break;
          d[i++] = (char)c;
        }
        d[i] = 0;
        dest.ReleaseBuf_SetLen(i);
        return;
      }
    }
    */

    unsigned len = (unsigned)WideCharToMultiByte(codePage, 0, src, (int)src.Len(), NULL, 0, NULL, NULL);
    if (len == 0)
    {
      if (GetLastError() != 0)
        throw 282228;
    }
    else
    {
      BOOL defUsed = FALSE;
      bool isUtf = (codePage == CP_UTF8 || codePage == CP_UTF7);
      // defaultChar = defaultChar;
      len = (unsigned)WideCharToMultiByte(codePage, 0, src, (int)src.Len(),
          dest.GetBuf(len), (int)len,
          (isUtf ? NULL : &defaultChar),
          (isUtf ? NULL : &defUsed)
          );
      if (!isUtf)
        defaultCharWasUsed = (defUsed != FALSE);
      if (len == 0)
        throw 282228;
      dest.ReleaseBuf_SetEnd(len);
    }
  }
}

/*
#ifndef UNDER_CE
AString SystemStringToOemString(const CSysString &src)
{
  AString dest;
  const unsigned len = src.Len() * 2;
  CharToOem(src, dest.GetBuf(len));
  dest.ReleaseBuf_CalcLen(len);
  return dest;
}
#endif
*/

#else // _WIN32

// #include <stdio.h>
/*
  if (wchar_t is 32-bit (#if WCHAR_MAX > 0xffff),
      and utf-8 string contains big unicode character > 0xffff),
  then we still use 16-bit surrogate pair in UString.
  It simplifies another code where utf-16 encoding is used.
  So we use surrogate-conversion code only in is file.
*/

/*
   mbstowcs() returns error if there is error in utf-8 stream,
   mbstowcs() returns error if there is single surrogates point (d800-dfff) in utf-8 stream
*/

/*
static void MultiByteToUnicodeString2_Native(UString &dest, const AString &src)
{
  dest.Empty();
  if (src.IsEmpty())
    return;

  const size_t limit = ((size_t)src.Len() + 1) * 2;
  wchar_t *d = dest.GetBuf((unsigned)limit);
  const size_t len = mbstowcs(d, src, limit);
  if (len != (size_t)-1)
  {
    dest.ReleaseBuf_SetEnd((unsigned)len);
    return;
  }
  dest.ReleaseBuf_SetEnd(0);
}
*/

bool g_ForceToUTF8 = true; // false;

static const UInt16 kTable_CP866[128] = {
  0x0410, 0x0411, 0x0412, 0x0413, 0x0414, 0x0415, 0x0416, 0x0417, 0x0418, 0x0419, 0x041A, 0x041B, 0x041C, 0x041D, 0x041E, 0x041F,
  0x0420, 0x0421, 0x0422, 0x0423, 0x0424, 0x0425, 0x0426, 0x0427, 0x0428, 0x0429, 0x042A, 0x042B, 0x042C, 0x042D, 0x042E, 0x042F,
  0x0430, 0x0431, 0x0432, 0x0433, 0x0434, 0x0435, 0x0436, 0x0437, 0x0438, 0x0439, 0x043A, 0x043B, 0x043C, 0x043D, 0x043E, 0x043F,
  0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556, 0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
  0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F, 0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
  0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B, 0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
  0x0440, 0x0441, 0x0442, 0x0443, 0x0444, 0x0445, 0x0446, 0x0447, 0x0448, 0x0449, 0x044A, 0x044B, 0x044C, 0x044D, 0x044E, 0x044F,
  0x0401, 0x0451, 0x0404, 0x0454, 0x0407, 0x0457, 0x040E, 0x045E, 0x00B0, 0x2219, 0x00B7, 0x221A, 0x2116, 0x00A4, 0x25A0, 0x00A0
};

static const UInt16 kTable_CP1251[128] = {
  0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, 0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
  0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x0098, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
  0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7, 0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
  0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7, 0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
  0x0410, 0x0411, 0x0412, 0x0413, 0x0414, 0x0415, 0x0416, 0x0417, 0x0418, 0x0419, 0x041A, 0x041B, 0x041C, 0x041D, 0x041E, 0x041F,
  0x0420, 0x0421, 0x0422, 0x0423, 0x0424, 0x0425, 0x0426, 0x0427, 0x0428, 0x0429, 0x042A, 0x042B, 0x042C, 0x042D, 0x042E, 0x042F,
  0x0430, 0x0431, 0x0432, 0x0433, 0x0434, 0x0435, 0x0436, 0x0437, 0x0438, 0x0439, 0x043A, 0x043B, 0x043C, 0x043D, 0x043E, 0x043F,
  0x0440, 0x0441, 0x0442, 0x0443, 0x0444, 0x0445, 0x0446, 0x0447, 0x0448, 0x0449, 0x044A, 0x044B, 0x044C, 0x044D, 0x044E, 0x044F
};

static const UInt16 kTable_CP1252[128] = {
  0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
  0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
  0x00A0, 0x00A1, 0x00A2, 0x00A3, 0x00A4, 0x00A5, 0x00A6, 0x00A7, 0x00A8, 0x00A9, 0x00AA, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x00AF,
  0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B6, 0x00B7, 0x00B8, 0x00B9, 0x00BA, 0x00BB, 0x00BC, 0x00BD, 0x00BE, 0x00BF,
  0x00C0, 0x00C1, 0x00C2, 0x00C3, 0x00C4, 0x00C5, 0x00C6, 0x00C7, 0x00C8, 0x00C9, 0x00CA, 0x00CB, 0x00CC, 0x00CD, 0x00CE, 0x00CF,
  0x00D0, 0x00D1, 0x00D2, 0x00D3, 0x00D4, 0x00D5, 0x00D6, 0x00D7, 0x00D8, 0x00D9, 0x00DA, 0x00DB, 0x00DC, 0x00DD, 0x00DE, 0x00DF,
  0x00E0, 0x00E1, 0x00E2, 0x00E3, 0x00E4, 0x00E5, 0x00E6, 0x00E7, 0x00E8, 0x00E9, 0x00EA, 0x00EB, 0x00EC, 0x00ED, 0x00EE, 0x00EF,
  0x00F0, 0x00F1, 0x00F2, 0x00F3, 0x00F4, 0x00F5, 0x00F6, 0x00F7, 0x00F8, 0x00F9, 0x00FA, 0x00FB, 0x00FC, 0x00FD, 0x00FE, 0x00FF
};

static const UInt16 kTable_CP437[128] = {
  0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7, 0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
  0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9, 0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
  0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA, 0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
  0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556, 0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
  0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F, 0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
  0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B, 0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
  0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4, 0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
  0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248, 0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0
};

static const UInt16 kTable_KOI8R[128] = {
  0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518, 0x251C, 0x2524, 0x252C, 0x2534, 0x253C, 0x2580, 0x2584, 0x2588, 0x258C, 0x2590,
  0x2591, 0x2592, 0x2593, 0x2320, 0x25A0, 0x2219, 0x221A, 0x2248, 0x2264, 0x2265, 0x00A0, 0x2321, 0x00B0, 0x00B2, 0x00B7, 0x00F7,
  0x2550, 0x2551, 0x2552, 0x0451, 0x2553, 0x2554, 0x2555, 0x2556, 0x2557, 0x2558, 0x2559, 0x255A, 0x255B, 0x255C, 0x255D, 0x255E,
  0x255F, 0x2560, 0x2561, 0x0401, 0x2562, 0x2563, 0x2564, 0x2565, 0x2566, 0x2567, 0x2568, 0x2569, 0x256A, 0x256B, 0x256C, 0x00A9,
  0x044E, 0x0430, 0x0431, 0x0446, 0x0434, 0x0435, 0x0444, 0x0433, 0x0445, 0x0438, 0x0439, 0x043A, 0x043B, 0x043C, 0x043D, 0x043E,
  0x043F, 0x044F, 0x0440, 0x0441, 0x0442, 0x0443, 0x0436, 0x0432, 0x044C, 0x044B, 0x0437, 0x0448, 0x044D, 0x0449, 0x0447, 0x044A,
  0x042E, 0x0410, 0x0411, 0x0426, 0x0414, 0x0415, 0x0424, 0x0413, 0x0425, 0x0418, 0x0419, 0x041A, 0x041B, 0x041C, 0x041D, 0x041E,
  0x041F, 0x042F, 0x0420, 0x0421, 0x0422, 0x0423, 0x0416, 0x0412, 0x042C, 0x042B, 0x0437, 0x0428, 0x042D, 0x0429, 0x0427, 0x042A
};

static const UInt16 *GetSingleByteTable(UINT codePage) throw()
{
  switch (codePage)
  {
    case 866: return kTable_CP866;
    case 1251: return kTable_CP1251;
    case 1252:
    case 28591: return kTable_CP1252;
    case 437:
    case 850: return kTable_CP437;
    case 20866: return kTable_KOI8R;
    default: return NULL;
  }
}

static UINT DetectLegacySingleByteCodePage(const AString &src) throw()
{
  int score866 = 0;
  int score1251 = 0;
  const unsigned len = src.Len();
  for (unsigned i = 0; i < len; i++)
  {
    const Byte b = (Byte)src[i];
    if (b < 0x80)
      continue;

    // CP866 scoring: 0x80..0xAF (А..п) and 0xE0..0xEF (р..я), 0xF0..0xF1 (Ё, ё);
    // 0xB0..0xDF are box-drawing characters never expected in file names.
    if (b >= 0x80 && b <= 0xAF)
      score866 += 3;
    else if (b >= 0xE0 && b <= 0xEF)
      score866 += 1;
    else if (b == 0xF0 || b == 0xF1)
      score866 += 2;
    else if (b >= 0xB0 && b <= 0xDF)
      score866 -= 4;
    else if (b >= 0xF2)
      score866 -= 3;

    // Windows-1251 scoring: 0xC0..0xDF (А..Я), 0xE0..0xFF (а..я), 0xA8/0xB8/0xB9 (Ё, ё, №)
    if (b >= 0xE0)
      score1251 += 3;
    else if (b >= 0xC0 && b <= 0xDF)
      score1251 += 2;
    else if (b == 0xA8 || b == 0xB8 || b == 0xB9)
      score1251 += 2;
    else
      score1251 -= 2;
  }

  if (score866 >= score1251 && score866 > 0)
    return 866;
  if (score1251 > 0)
    return 1251;
  return 1252;
}

static void DecodeWithSingleByteTable(UString &dest, const AString &src, const UInt16 *table)
{
  const unsigned len = src.Len();
  wchar_t *d = dest.GetBuf(len);
  for (unsigned i = 0; i < len; i++)
  {
    const Byte b = (Byte)src[i];
    d[i] = (b < 0x80) ? (wchar_t)b : (wchar_t)table[b - 0x80];
  }
  d[len] = 0;
  dest.ReleaseBuf_SetLen(len);
}

void MultiByteToUnicodeString2(UString &dest, const AString &src, UINT codePage)
{
  dest.Empty();
  if (src.IsEmpty())
    return;

  if (codePage == CP_UTF8)
  {
    ConvertUTF8ToUnicode(src, dest);
    return;
  }

  const UInt16 *explicitTable = GetSingleByteTable(codePage);
  if (explicitTable)
  {
    DecodeWithSingleByteTable(dest, src, explicitTable);
    return;
  }

  if (g_ForceToUTF8)
  {
    if (CheckUTF8_AString(src))
    {
      ConvertUTF8ToUnicode(src, dest);
      return;
    }
    const UINT detectedCp = DetectLegacySingleByteCodePage(src);
    const UInt16 *detectedTable = GetSingleByteTable(detectedCp);
    if (detectedTable)
    {
      DecodeWithSingleByteTable(dest, src, detectedTable);
      return;
    }
    ConvertUTF8ToUnicode(src, dest);
    return;
  }

  const size_t limit = ((size_t)src.Len() + 1) * 2;
  wchar_t *d = dest.GetBuf((unsigned)limit);
  const size_t len = mbstowcs(d, src, limit);
  if (len != (size_t)-1)
  {
    dest.ReleaseBuf_SetEnd((unsigned)len);

#if WCHAR_MAX > 0xffff
    d = dest.GetBuf();
    for (size_t i = 0;; i++)
    {
      wchar_t c = d[i];
      // printf("\ni=%2d c = %4x\n", (unsigned)i, (unsigned)c);
      if (c == 0)
        break;
      if (c >= 0x10000 && c < 0x110000)
      {
        UString tempString = d + i;
        const wchar_t *t = tempString.Ptr();

        for (;;)
        {
          wchar_t w = *t++;
          // printf("\nchar=%x\n", w);
          if (w == 0)
            break;
          if (i == limit)
            break; // unexpected error
          if (w >= 0x10000 && w < 0x110000)
          {
#if 1
            if (i + 1 == limit)
              break; // unexpected error
            w -= 0x10000;
            d[i++] = (unsigned)0xd800 + (((unsigned)w >> 10) & 0x3ff);
            w = 0xdc00 + (w & 0x3ff);
#else
            // w = '_'; // for debug
#endif
          }
          d[i++] = w;
        }
        dest.ReleaseBuf_SetEnd((unsigned)i);
        break;
      }
    }

#endif
 
    /*
    printf("\nMultiByteToUnicodeString2 (%d) %s\n", (int)src.Len(),  src.Ptr());
    printf("char:    ");
    for (unsigned i = 0; i < src.Len(); i++)
      printf (" %02x", (int)(Byte)src[i]);
    printf("\n");
    printf("\n-> (%d) %ls\n", (int)dest.Len(), dest.Ptr());
    printf("wchar_t: ");
    for (unsigned i = 0; i < dest.Len(); i++)
    {
      printf (" %02x", (int)dest[i]);
    }
    printf("\n");
    */

    return;
  }

  /* if there is mbstowcs() error, we have two ways:
     
     1) change 0x80+ characters to some character: '_'
        in that case we lose data, but we have correct UString()
        and that scheme can show errors to user in early stages,
        when file converted back to mbs() cannot be found

     2) transfer bad characters in some UTF-16 range.
        it can be non-original Unicode character.
        but later we still can restore original character.
  */

  
  // printf("\nmbstowcs  ERROR !!!!!! s=%s\n", src.Ptr());
  {
    unsigned i;
    const char *s = (const char *)src;
    for (i = 0;;)
    {
      Byte c = (Byte)s[i];
      if (c == 0)
        break;
      // we can use ascii compatibilty character '_'
      // if (c > 0x7F) c = '_'; // we replace "bad: character
      d[i++] = (wchar_t)c;
    }
    d[i] = 0;
    dest.ReleaseBuf_SetLen(i);
  }
}

static void UnicodeStringToMultiByte2_Native(AString &dest, const UString &src)
{
  dest.Empty();
  if (src.IsEmpty())
    return;

  const size_t limit = ((size_t)src.Len() + 1) * 6;
  char *d = dest.GetBuf((unsigned)limit);

  const size_t len = wcstombs(d, src, limit);

  if (len != (size_t)-1)
  {
    dest.ReleaseBuf_SetEnd((unsigned)len);
    return;
  }
  dest.ReleaseBuf_SetEnd(0);
}


static void UnicodeStringToMultiByte2(AString &dest, const UString &src2, UINT codePage, char defaultChar, bool &defaultCharWasUsed)
{
  // if (codePage == 1234567) // for debug purposes
  if (codePage == CP_UTF8 || g_ForceToUTF8)
  {
#if 1
    defaultCharWasUsed = false;
    ConvertUnicodeToUTF8(src2, dest);
    return;
#endif
  }

  UString src = src2;
#if WCHAR_MAX > 0xffff
  {
    src.Empty();
    for (unsigned i = 0; i < src2.Len();)
    {
      wchar_t c = src2[i++];
      if (c >= 0xd800 && c < 0xdc00 && i != src2.Len())
      {
        const wchar_t c2 = src2[i];
        if (c2 >= 0xdc00 && c2 < 0xe000)
        {
#if 1
          // printf("\nSurragate [%d]: %4x %4x -> ", i, (int)c, (int)c2);
          c = 0x10000 + ((c & 0x3ff) << 10) + (c2 & 0x3ff);
          // printf("%4x\n", (int)c);
          i++;
#else
          // c = '_'; // for debug
#endif
        }
      }
      src += c;
    }
  }
#endif

  dest.Empty();
  defaultCharWasUsed = false;
  if (src.IsEmpty())
    return;

  const size_t len = wcstombs(NULL, src, 0);

  if (len != (size_t)-1)
  {
    const unsigned limit = ((unsigned)len);
    if (limit == len)
    {
      char *d = dest.GetBuf(limit);

      /*
      {
        printf("\nwcstombs; len = %d %ls \n", (int)src.Len(), src.Ptr());
        for (unsigned i = 0; i < src.Len(); i++)
          printf (" %02x", (int)src[i]);
        printf("\n");
        printf("\ndest Limit = %d \n", limit);
      }
      */

      const size_t len2 = wcstombs(d, src, len + 1);
      
      if (len2 != (size_t)-1 && len2 <= limit)
      {
        /*
        printf("\nOK : destLen = %d : %s\n", (int)len, dest.Ptr());
        for (unsigned i = 0; i < len2; i++)
          printf(" %02x", (int)(Byte)dest[i]);
        printf("\n");
        */
        dest.ReleaseBuf_SetEnd((unsigned)len2);
        return;
      }
    }
  }

  {
    const wchar_t *s = (const wchar_t *)src;
    char *d = dest.GetBuf(src.Len());

    unsigned i;
    for (i = 0;;)
    {
      wchar_t c = s[i];
      if (c == 0)
        break;
      if (c >=
            0x100
            // 0x80
          )
      {
        c = defaultChar;
        defaultCharWasUsed = true;
      }

      d[i++] = (char)c;
    }
    d[i] = 0;
    dest.ReleaseBuf_SetLen(i);
    /*
    printf("\nUnicodeStringToMultiByte2; len = %d \n", (int)src.Len());
    printf("ERROR: %s\n", dest.Ptr());
    */
  }
}

#endif // _WIN32


UString MultiByteToUnicodeString(const AString &src, UINT codePage)
{
  UString dest;
  MultiByteToUnicodeString2(dest, src, codePage);
  return dest;
}

UString MultiByteToUnicodeString(const char *src, UINT codePage)
{
  return MultiByteToUnicodeString(AString(src), codePage);
}


void UnicodeStringToMultiByte2(AString &dest, const UString &src, UINT codePage)
{
  bool defaultCharWasUsed;
  UnicodeStringToMultiByte2(dest, src, codePage, k_DefultChar, defaultCharWasUsed);
}

AString UnicodeStringToMultiByte(const UString &src, UINT codePage, char defaultChar, bool &defaultCharWasUsed)
{
  AString dest;
  UnicodeStringToMultiByte2(dest, src, codePage, defaultChar, defaultCharWasUsed);
  return dest;
}

AString UnicodeStringToMultiByte(const UString &src, UINT codePage)
{
  AString dest;
  bool defaultCharWasUsed;
  UnicodeStringToMultiByte2(dest, src, codePage, k_DefultChar, defaultCharWasUsed);
  return dest;
}




#if !defined(_WIN32) || defined(ENV_HAVE_LOCALE)

#ifdef _WIN32
#define U_to_A(a, b, c)  UnicodeStringToMultiByte2
// #define A_to_U(a, b, c)  MultiByteToUnicodeString2
#else
// void MultiByteToUnicodeString2_Native(UString &dest, const AString &src);
#define U_to_A(a, b, c)  UnicodeStringToMultiByte2_Native(a, b)
// #define A_to_U(a, b, c)  MultiByteToUnicodeString2_Native(a, b)
#endif

bool IsNativeUTF8()
{
  UString u;
  AString a, a2;
  // for (unsigned c = 0x80; c < (UInt32)0x10000; c += (c >> 9) + 1)
  for (unsigned c = 0x80; c < (UInt32)0xD000; c += (c >> 2) + 1)
  {
    u.Empty();
    u += (wchar_t)c;
    /*
    if (Unicode_Is_There_Utf16SurrogateError(u))
      continue;
    #ifndef _WIN32
    if (Unicode_Is_There_BmpEscape(u))
      continue;
    #endif
    */
    ConvertUnicodeToUTF8(u, a);
    U_to_A(a2, u, CP_OEMCP);
    if (a != a2)
      return false;
  }
  return true;
}

#endif


#ifdef ENV_HAVE_LOCALE

const char *GetLocale(void)
{
  #ifdef ENV_HAVE_LOCALE
    // printf("\n\nsetlocale(LC_CTYPE, NULL) : return : ");
    const char *s = setlocale(LC_CTYPE, NULL);
    if (!s)
    {
      // printf("[NULL]\n");
      s = "C";
    }
    else
    {
      // ubuntu returns "C" after program start
      // printf("\"%s\"\n", s);
    }
    return s;
  #elif defined(LOCALE_IS_UTF8)
    return "utf8";
  #else
    return "C";
  #endif
}

#ifdef _WIN32
  static void Set_ForceToUTF8(bool) {}
#else
  static void Set_ForceToUTF8(bool val) { g_ForceToUTF8 = val; }
#endif

static bool Is_Default_Basic_Locale(const char *locale)
{
  const AString a (locale);
  if (a.IsEqualTo_Ascii_NoCase("")
      || a.IsEqualTo_Ascii_NoCase("C")
      || a.IsEqualTo_Ascii_NoCase("POSIX"))
      return true;
  return false;
}

static bool Is_Default_Basic_Locale()
{
  return Is_Default_Basic_Locale(GetLocale());
}


void MY_SetLocale()
{
  #ifdef ENV_HAVE_LOCALE
  /*
  {
    const char *s = GetLocale();
    printf("\nGetLocale() : returned : \"%s\"\n", s);
  }
  */
  
  unsigned start = 0;
  // unsigned lim = 0;
  unsigned lim = 3;

  /*
  #define MY_SET_LOCALE_FLAGS__FROM_ENV 1
  #define MY_SET_LOCALE_FLAGS__TRY_UTF8 2

  unsigned flags =
      MY_SET_LOCALE_FLAGS__FROM_ENV |
      MY_SET_LOCALE_FLAGS__TRY_UTF8

  if (flags != 0)
  {
    if (flags & MY_SET_LOCALE_FLAGS__FROM_ENV)
      lim = (flags & MY_SET_LOCALE_FLAGS__TRY_UTF8) ? 3 : 1;
    else
    {
      start = 1;
      lim = 2;
    }
  }
  */

  for (unsigned i = start; i < lim; i++)
  {
    /*
    man7: "If locale is an empty string, "", each part of the locale that
    should be modified is set according to the environment variables.
    for glibc: glibc, first from the user's environment variables:
      1) the environment variable LC_ALL,
      2) environment variable with the same name as the category (see the
      3) the environment variable LANG
    The locale "C" or "POSIX" is a portable locale; it exists on all conforming systems.
    
    for WIN32 : MSDN :
      Sets the locale to the default, which is the user-default
      ANSI code page obtained from the operating system.
      The locale name is set to the value returned by GetUserDefaultLocaleName.
      The code page is set to the value returned by GetACP
  */
    const char *newLocale = "";
    
    #ifdef __APPLE__
    
    /* look also CFLocale
       there is no C.UTF-8 in macos
       macos has UTF-8 locale only with some language like en_US.UTF-8
       what is best way to set UTF-8 locale in macos? */
    if (i == 1)
      newLocale = "en_US.UTF-8";
   
    /* file open with non-utf8 sequencies return
      #define EILSEQ    92    // "Illegal byte sequence"
    */
#else
    // newLocale = "C";
    if (i == 1)
    {
      newLocale = "C.UTF-8";    // main UTF-8 locale in ubuntu
      // newLocale = ".utf8";    // supported in new Windows 10 build 17134 (April 2018 Update), the Universal C Runtime
      // newLocale = "en_US.utf8"; // supported by ubuntu ?
      // newLocale = "en_US.UTF-8";
      /* setlocale() in ubuntu allows locales with minor chracter changes in strings
        "en_US.UTF-8" /  "en_US.utf8" */
    }
    
#endif
    
    // printf("\nsetlocale(LC_ALL, \"%s\") : returned: ", newLocale);
    
    // const char *s =
    setlocale(LC_ALL, newLocale);
    
    /*
    if (!s)
      printf("NULL: can't set locale");
    else
      printf("\"%s\"\n", s);
    */
    
    // request curent locale of program
    const char *locale = GetLocale();
    if (locale)
    {
      AString a (locale);
      a.MakeLower_Ascii();
      // if (a.Find("utf") >= 0)
      {
        if (IsNativeUTF8())
        {
          Set_ForceToUTF8(true);
          return;
        }
      }
      if (!Is_Default_Basic_Locale(locale))
      {
        // if there is some non-default and non-utf locale, we want to use it
        break; // comment it for debug
      }
    }
  }

  if (IsNativeUTF8())
  {
    Set_ForceToUTF8(true);
    return;
  }

  if (Is_Default_Basic_Locale())
  {
    Set_ForceToUTF8(true);
    return;
  }

  Set_ForceToUTF8(false);

  #elif defined(LOCALE_IS_UTF8)
    // assume LC_CTYPE="utf8"
  #else
    // assume LC_CTYPE="C"
  #endif
}
#endif
