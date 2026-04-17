<#
.SYNOPSIS
    Splits a Windows .ico file into its individual frames, preserving the raw
    bytes of each embedded image.

.DESCRIPTION
    Parses the ICO container directly per the documented file layout:

        ICONDIR        (6 bytes)   : reserved=0, type=1 (ICO), count
        ICONDIRENTRY[] (16 bytes)  : per-frame width, height, bpp, size, offset
        payload[]                  : either a full PNG file or a headerless DIB

    For each frame the script slices [dwImageOffset, dwImageOffset+dwBytesInRes)
    out of the source file and writes the payload with the smallest possible
    transformation:

      - PNG frames (payload starting with the 8-byte PNG signature) are written
        as .png. The bytes are byte-identical to a standalone PNG file.
      - DIB frames (everything else - BITMAPINFOHEADER + XOR pixels + AND mask,
        no BITMAPFILEHEADER) are written according to -DibFormat:
          * Bmp (default): produces a valid .bmp by prepending a 14-byte
            BITMAPFILEHEADER, halving biHeight back to the real image height
            (the on-disk DIB has biHeight = 2 * height to fit the AND mask),
            and dropping the trailing AND-mask rows. Pixel bytes are untouched.
          * Ico: rewraps the DIB payload byte-for-byte into a single-frame .ico
            (fresh 6-byte ICONDIR + 16-byte ICONDIRENTRY + original payload).
            Most faithful to the source bytes; transparency for sub-32bpp frames
            is preserved via the AND mask.

    Note: bWidth / bHeight of 0 in the directory means 256 (per spec).
    Type=2 (CUR) files are rejected.

.PARAMETER Path
    One or more .ico files (or directories) to split. Accepts pipeline input.

.PARAMETER OutDir
    Directory to write frames into. If omitted, frames are written next to the
    source file in a sibling folder named '{basename}.frames'.

.PARAMETER DibFormat
    How to write DIB (non-PNG) frames. 'Bmp' (default) emits a valid .bmp by
    adding the missing BITMAPFILEHEADER, halving the doubled biHeight and
    stripping the AND mask. 'Ico' rewraps the payload byte-for-byte into a
    single-frame .ico. PNG frames are always written as .png.

.PARAMETER Force
    Overwrite existing output files.

.EXAMPLE
    .\scripts\Expand-Ico.ps1 -Path .\out\icons\Git.Git\Git.{...}.ico

.EXAMPLE
    Get-ChildItem .\out\icons -Recurse -Filter *.ico |
        .\scripts\Expand-Ico.ps1 -OutDir .\out\frames

.EXAMPLE
    .\scripts\Expand-Ico.ps1 -Path .\app.ico |
        Select-Object Index, Width, Height, BitCount, Format, OutPath
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName, Position = 0)]
    [Alias('FullName', 'PSPath')]
    [string[]] $Path,

    [string] $OutDir,

    [ValidateSet('Bmp', 'Ico')]
    [string] $DibFormat = 'Bmp',

    [switch] $Force
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # PNG signature: 89 50 4E 47 0D 0A 1A 0A
    $script:PngSignature = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

    function Test-IsPng {
        param([byte[]] $Bytes)
        if ($Bytes.Length -lt 8) { return $false }
        for ($i = 0; $i -lt 8; $i++) {
            if ($Bytes[$i] -ne $script:PngSignature[$i]) { return $false }
        }
        return $true
    }

    function Write-LE-UInt16 {
        param([System.IO.BinaryWriter] $Writer, [uint16] $Value)
        $Writer.Write([uint16] $Value)
    }

    function Write-LE-UInt32 {
        param([System.IO.BinaryWriter] $Writer, [uint32] $Value)
        $Writer.Write([uint32] $Value)
    }

    function Write-SingleFrameIco {
        param(
            [string] $OutFile,
            [byte] $BWidth,
            [byte] $BHeight,
            [byte] $BColorCount,
            [byte] $BReserved,
            [uint16] $WPlanes,
            [uint16] $WBitCount,
            [byte[]] $Payload
        )

        # ICONDIR (6) + 1 * ICONDIRENTRY (16) = 22; image data starts at offset 22.
        $imageOffset = [uint32] 22
        $bytesInRes  = [uint32] $Payload.Length

        $stream = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create,
                                          [System.IO.FileAccess]::Write,
                                          [System.IO.FileShare]::None)
        try {
            $bw = [System.IO.BinaryWriter]::new($stream)
            try {
                # ICONDIR
                Write-LE-UInt16 $bw 0      # idReserved
                Write-LE-UInt16 $bw 1      # idType = 1 (ICO)
                Write-LE-UInt16 $bw 1      # idCount

                # ICONDIRENTRY
                $bw.Write([byte] $BWidth)
                $bw.Write([byte] $BHeight)
                $bw.Write([byte] $BColorCount)
                $bw.Write([byte] $BReserved)
                Write-LE-UInt16 $bw $WPlanes
                Write-LE-UInt16 $bw $WBitCount
                Write-LE-UInt32 $bw $bytesInRes
                Write-LE-UInt32 $bw $imageOffset

                # Payload (verbatim)
                $bw.Write($Payload)
                $bw.Flush()
            } finally {
                $bw.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    }

    function Write-DibAsBmp {
        param(
            [string] $OutFile,
            [int] $Width,
            [int] $Height,
            [uint16] $WBitCount,
            [byte[]] $Payload
        )

        # Payload layout (no BITMAPFILEHEADER):
        #   [0..3]  biSize (DWORD; usually 40 for BITMAPINFOHEADER, can be 108/124 for V4/V5)
        #   ...
        #   [8..11] biHeight (LONG, signed) - on disk this is 2 * Height for ICO DIBs
        #   [14..15] biBitCount (WORD)
        #   [biSize..]   color table (palette) for <=8bpp; bitfield masks for some 16/32bpp
        #   then        XOR pixel data (Height rows, bottom-up, DWORD-aligned)
        #   then        AND mask     (Height rows, 1bpp, DWORD-aligned) -- to be dropped

        if ($Payload.Length -lt 16) {
            throw "DIB payload too small ($($Payload.Length) bytes) to contain BITMAPINFOHEADER."
        }

        $biSize = [System.BitConverter]::ToUInt32($Payload, 0)
        if ($biSize -lt 16 -or $biSize -gt 124 -or $biSize -gt $Payload.Length) {
            throw "DIB has implausible biSize=$biSize."
        }

        # Palette / bitfield masks size that lives between header and pixels.
        # For <=8bpp images the directory's color count is the palette size in
        # 4-byte BGRA entries (0 means 'use the maximum for this depth').
        $paletteEntries = 0
        if ($WBitCount -le 8) {
            # biClrUsed at offset 32 (DWORD); 0 means 2^biBitCount entries.
            $biClrUsed = [System.BitConverter]::ToUInt32($Payload, 32)
            $paletteEntries = if ($biClrUsed -ne 0) { [int] $biClrUsed } else { 1 -shl [int] $WBitCount }
        }
        $paletteBytes = $paletteEntries * 4

        # XOR pixel rows are DWORD-aligned per row.
        $xorRowBytes = [int] ((([int] $WBitCount * $Width + 31) -band -bnot 31) / 8)
        $xorBytes    = $xorRowBytes * $Height

        # Where the BMP file ends (header + DIB header + palette + XOR pixels). The
        # AND mask that follows in the ICO payload is dropped.
        $dibKeepBytes = [int] $biSize + $paletteBytes + $xorBytes

        if ($dibKeepBytes -gt $Payload.Length) {
            throw ("DIB payload too small for declared geometry: need {0} bytes (header={1} + palette={2} + pixels={3}), have {4}." `
                -f $dibKeepBytes, $biSize, $paletteBytes, $xorBytes, $Payload.Length)
        }

        $bfOffBits = [uint32] (14 + [int] $biSize + $paletteBytes)
        $bfSize    = [uint32] (14 + $dibKeepBytes)

        # Patch biHeight in a copy so we don't mutate the caller's array.
        $patched = New-Object byte[] $dibKeepBytes
        [System.Buffer]::BlockCopy($Payload, 0, $patched, 0, $dibKeepBytes)
        $heightBytes = [System.BitConverter]::GetBytes([int32] $Height)  # signed; image is bottom-up
        [System.Buffer]::BlockCopy($heightBytes, 0, $patched, 8, 4)

        $stream = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create,
                                          [System.IO.FileAccess]::Write,
                                          [System.IO.FileShare]::None)
        try {
            $bw = [System.IO.BinaryWriter]::new($stream)
            try {
                # BITMAPFILEHEADER (14 bytes)
                $bw.Write([byte] 0x42)             # 'B'
                $bw.Write([byte] 0x4D)             # 'M'
                Write-LE-UInt32 $bw $bfSize        # bfSize
                Write-LE-UInt16 $bw 0              # bfReserved1
                Write-LE-UInt16 $bw 0              # bfReserved2
                Write-LE-UInt32 $bw $bfOffBits     # bfOffBits

                $bw.Write($patched)
                $bw.Flush()
            } finally {
                $bw.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    }

    function Expand-OneIco {
        param(
            [string] $IcoPath,
            [string] $TargetDir,
            [string] $DibFormat,
            [switch] $Force
        )

        $bytes = [System.IO.File]::ReadAllBytes($IcoPath)
        if ($bytes.Length -lt 6) {
            throw "File '$IcoPath' is too small to be an ICO ($($bytes.Length) bytes)."
        }

        $reserved = [System.BitConverter]::ToUInt16($bytes, 0)
        $type     = [System.BitConverter]::ToUInt16($bytes, 2)
        $count    = [System.BitConverter]::ToUInt16($bytes, 4)

        if ($reserved -ne 0) {
            throw "File '$IcoPath' has non-zero idReserved ($reserved); not a valid ICO."
        }
        if ($type -ne 1) {
            throw "File '$IcoPath' has idType=$type (expected 1 for ICO; 2 = CUR is not supported)."
        }
        if ($count -eq 0) {
            Write-Warning "File '$IcoPath' declares zero frames."
            return
        }

        $needed = 6 + ($count * 16)
        if ($bytes.Length -lt $needed) {
            throw "File '$IcoPath' is truncated: need $needed bytes for directory, have $($bytes.Length)."
        }

        if (-not (Test-Path -LiteralPath $TargetDir)) {
            New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
        }

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($IcoPath)

        for ($i = 0; $i -lt $count; $i++) {
            $entryOffset = 6 + ($i * 16)

            $bWidth      = $bytes[$entryOffset + 0]
            $bHeight     = $bytes[$entryOffset + 1]
            $bColorCount = $bytes[$entryOffset + 2]
            $bReserved   = $bytes[$entryOffset + 3]
            $wPlanes     = [System.BitConverter]::ToUInt16($bytes, $entryOffset + 4)
            $wBitCount   = [System.BitConverter]::ToUInt16($bytes, $entryOffset + 6)
            $dwBytesInRes  = [System.BitConverter]::ToUInt32($bytes, $entryOffset + 8)
            $dwImageOffset = [System.BitConverter]::ToUInt32($bytes, $entryOffset + 12)

            # Width/height of 0 means 256 per spec.
            $width  = if ($bWidth  -eq 0) { 256 } else { [int] $bWidth  }
            $height = if ($bHeight -eq 0) { 256 } else { [int] $bHeight }

            if ($dwImageOffset + $dwBytesInRes -gt [uint32] $bytes.Length) {
                Write-Warning ("Frame #{0} in '{1}' is truncated (offset={2}, size={3}, file={4}); skipping." `
                    -f $i, $IcoPath, $dwImageOffset, $dwBytesInRes, $bytes.Length)
                continue
            }

            $payload = New-Object byte[] $dwBytesInRes
            [System.Buffer]::BlockCopy($bytes, [int] $dwImageOffset, $payload, 0, [int] $dwBytesInRes)

            $isPng = Test-IsPng -Bytes $payload
            if ($isPng) {
                $format = 'PNG'
                $ext    = 'png'
            } elseif ($DibFormat -eq 'Bmp') {
                $format = 'DIB'
                $ext    = 'bmp'
            } else {
                $format = 'DIB'
                $ext    = 'ico'
            }

            $outName = '{0}_{1:D2}_{2}x{3}_{4}bpp.{5}' -f $baseName, $i, $width, $height, $wBitCount, $ext
            $outPath = Join-Path -Path $TargetDir -ChildPath $outName

            if ((Test-Path -LiteralPath $outPath) -and -not $Force) {
                throw "Output file '$outPath' already exists. Use -Force to overwrite."
            }

            if ($isPng) {
                # PNG frame: bytes are already a complete .png file. Write verbatim.
                [System.IO.File]::WriteAllBytes($outPath, $payload)
            } elseif ($DibFormat -eq 'Bmp') {
                # DIB frame -> proper .bmp: prepend BITMAPFILEHEADER, halve biHeight,
                # drop the AND mask. Pixel bytes (XOR plane) are untouched.
                Write-DibAsBmp -OutFile $outPath `
                    -Width $width -Height $height `
                    -WBitCount $wBitCount -Payload $payload
            } else {
                # DIB frame -> single-frame .ico, payload bytes preserved 1:1.
                Write-SingleFrameIco -OutFile $outPath `
                    -BWidth $bWidth -BHeight $bHeight `
                    -BColorCount $bColorCount -BReserved $bReserved `
                    -WPlanes $wPlanes -WBitCount $wBitCount `
                    -Payload $payload
            }

            [pscustomobject] @{
                SourceIco    = $IcoPath
                Index        = $i
                Width        = $width
                Height       = $height
                BitCount     = [int] $wBitCount
                Planes       = [int] $wPlanes
                ColorCount   = [int] $bColorCount
                Format       = $format
                PayloadBytes = [int] $dwBytesInRes
                OutPath      = $outPath
            }
        }
    }
}

process {
    foreach ($p in $Path) {
        $resolved = Resolve-Path -LiteralPath $p -ErrorAction Stop
        foreach ($r in $resolved) {
            $item = Get-Item -LiteralPath $r.ProviderPath
            $files = if ($item.PSIsContainer) {
                Get-ChildItem -LiteralPath $item.FullName -Filter *.ico -File
            } else {
                @($item)
            }

            foreach ($file in $files) {
                $target = if ($PSBoundParameters.ContainsKey('OutDir') -and $OutDir) {
                    $OutDir
                } else {
                    Join-Path -Path $file.DirectoryName `
                              -ChildPath ([System.IO.Path]::GetFileNameWithoutExtension($file.Name) + '.frames')
                }

                Write-Verbose "Expanding '$($file.FullName)' into '$target' (DibFormat=$DibFormat)"
                Expand-OneIco -IcoPath $file.FullName -TargetDir $target -DibFormat $DibFormat -Force:$Force
            }
        }
    }
}
