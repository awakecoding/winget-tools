<#
.SYNOPSIS
    Extracts the raw application icon (.ico) from an installed WinGet package.

.DESCRIPTION
    Mirrors the algorithm winget itself uses (see winget-cli's IconExtraction.cpp
    and ARPHelper.cpp) without invoking 'winget show':

      1. Resolve the WinGet PackageId to one or more ARP ProductCodes by reading
         the manifest via Get-WinGetManifest.ps1 (-AsJson). All ProductCodes
         declared on Installers[*] / Installers[*].AppsAndFeaturesEntries[*]
         are considered.
      2. Walk the Uninstall registry hives (HKCU + HKLM 64-view + HKLM 32-view)
         and find subkeys whose name (case-insensitive) matches any candidate
         ProductCode.
      3. For each match, pick the icon source like winget does:
           - If WindowsInstaller == 1 -> MsiGetProductInfoW(INSTALLPROPERTY_PRODUCTICON)
           - Else -> the DisplayIcon REG_SZ / REG_EXPAND_SZ
         Then PathUnquoteSpacesW + PathParseIconLocationW to split path,index,
         and ExpandEnvironmentStringsW.
      4. If the source is .ico, copy bytes verbatim. If .exe / .dll, walk
         RT_GROUP_ICON resources (RESOURCE_ENUM_MUI|LN|VALIDATE) and assemble
         a proper .ico (ICONDIR + ICONDIRENTRY entries + concatenated RT_ICON
         payloads with recomputed dwImageOffset). Same byte-for-byte layout
         as ExtractIconFromBinaryFile.
      5. Write the result to OutDir as {SanitizedDisplayName}.{ProductCode}.ico
         and emit one PSCustomObject per match.

    The native heavy lifting is done by a small C# helper compiled inline via
    Add-Type. MSIX / Microsoft Store packages are out of scope (they have no
    ARP entry; winget's own IconExtraction does not handle them either).

.PARAMETER PackageId
    Exact WinGet package identifier, e.g. 'Git.Git' or 'Microsoft.PowerShell'.

.PARAMETER Scope
    Which ARP hives to search. One of User, Machine, Both. Default: Both.

.PARAMETER OutDir
    Directory to write extracted .ico files into. Created if missing.
    Default: $env:TEMP\winget-icons.

.PARAMETER Force
    Overwrite existing .ico files in OutDir.

.EXAMPLE
    .\scripts\Get-WinGetIcon.ps1 -PackageId Git.Git

.EXAMPLE
    .\scripts\Get-WinGetIcon.ps1 -PackageId Microsoft.PowerShell -Scope Machine

.EXAMPLE
    .\scripts\Get-WinGetIcon.ps1 -PackageId Git.Git -OutDir .\icons -Force |
        Select-Object PackageId, ProductCode, IconPath
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, HelpMessage = 'Exact WinGet package identifier, e.g. Git.Git')]
    [string] $PackageId,

    [Parameter(HelpMessage = 'Which ARP hives to search.')]
    [ValidateSet('User', 'Machine', 'Both')]
    [string] $Scope = 'Both',

    [Parameter(HelpMessage = 'Directory to write extracted .ico files. Default: $env:TEMP\winget-icons')]
    [string] $OutDir,

    [Parameter(HelpMessage = 'Overwrite existing .ico files.')]
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutDir) {
    $OutDir = Join-Path $env:TEMP 'winget-icons'
}

# =============================================================================
# Native helper (compiled once per session via Add-Type)
# =============================================================================
if (-not ('WinGetIconTools.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace WinGetIconTools
{
    public static class Native
    {
        // ----- kernel32 -----
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryExW(string lpFileName, IntPtr hReservedNull, uint dwFlags);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FreeLibrary(IntPtr hModule);

        // EnumResourceNamesExW with the LangId param. We always pass 0.
        private delegate bool EnumResNameProcW(IntPtr hModule, IntPtr lpType, IntPtr lpName, IntPtr lParam);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumResourceNamesExW(
            IntPtr hModule, IntPtr lpszType, EnumResNameProcW lpEnumFunc,
            IntPtr lParam, uint dwFlags, ushort langId);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindResourceExW(IntPtr hModule, IntPtr lpType, IntPtr lpName, ushort wLanguage);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LoadResource(IntPtr hModule, IntPtr hResInfo);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LockResource(IntPtr hResData);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint SizeofResource(IntPtr hModule, IntPtr hResInfo);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint ExpandEnvironmentStringsW(string lpSrc, StringBuilder lpDst, uint nSize);

        // ----- shlwapi -----
        [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
        private static extern void PathUnquoteSpacesW(StringBuilder lpsz);

        [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
        private static extern int PathParseIconLocationW(StringBuilder lpsz);

        // ----- msi -----
        [DllImport("msi.dll", CharSet = CharSet.Unicode)]
        private static extern uint MsiGetProductInfoW(string szProduct, string szProperty, StringBuilder lpValueBuf, ref uint pcchValueBuf);

        // ----- advapi32 (registry key timestamp) -----
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int RegOpenKeyExW(IntPtr hKey, string lpSubKey, uint ulOptions, uint samDesired, out IntPtr phkResult);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern int RegCloseKey(IntPtr hKey);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern int RegQueryInfoKeyW(
            IntPtr hKey, IntPtr lpClass, IntPtr lpcchClass, IntPtr lpReserved,
            IntPtr lpcSubKeys, IntPtr lpcbMaxSubKeyLen, IntPtr lpcbMaxClassLen,
            IntPtr lpcValues, IntPtr lpcbMaxValueNameLen, IntPtr lpcbMaxValueLen,
            IntPtr lpcbSecurityDescriptor, out long lpftLastWriteTime);

        private const uint KEY_READ           = 0x20019;
        private const uint KEY_WOW64_64KEY    = 0x0100;
        private const uint KEY_WOW64_32KEY    = 0x0200;
        private static readonly IntPtr HKEY_LOCAL_MACHINE = new IntPtr(unchecked((int)0x80000002));
        private static readonly IntPtr HKEY_CURRENT_USER  = new IntPtr(unchecked((int)0x80000001));

        // ----- constants -----
        private const uint LOAD_LIBRARY_AS_DATAFILE        = 0x00000002;
        private const uint LOAD_LIBRARY_AS_IMAGE_RESOURCE  = 0x00000020;

        // From winuser.h
        private static readonly IntPtr RT_ICON       = (IntPtr)3;
        private static readonly IntPtr RT_GROUP_ICON = (IntPtr)14;

        private const uint RESOURCE_ENUM_LN       = 0x00000001;
        private const uint RESOURCE_ENUM_MUI      = 0x00000002;
        private const uint RESOURCE_ENUM_VALIDATE = 0x00000008;

        private const uint ERROR_MORE_DATA = 234;
        private const uint ERROR_SUCCESS   = 0;

        // ----- helpers -----
        public sealed class ParsedIconLocation
        {
            public string Path  { get; set; }
            public int    Index { get; set; }
        }

        public static ParsedIconLocation ParseIconLocation(string raw)
        {
            if (string.IsNullOrEmpty(raw)) return new ParsedIconLocation { Path = string.Empty, Index = 0 };

            // Need a writable buffer big enough for both shlwapi calls.
            var sb = new StringBuilder(raw, Math.Max(raw.Length + 4, 260));
            PathUnquoteSpacesW(sb);
            int idx = PathParseIconLocationW(sb); // truncates ",-N" suffix in place
            return new ParsedIconLocation { Path = sb.ToString(), Index = idx };
        }

        public static string ExpandEnv(string raw)
        {
            if (string.IsNullOrEmpty(raw)) return raw;
            uint needed = ExpandEnvironmentStringsW(raw, null, 0);
            if (needed == 0) return raw;
            var sb = new StringBuilder((int)needed);
            uint written = ExpandEnvironmentStringsW(raw, sb, needed);
            if (written == 0) return raw;
            return sb.ToString();
        }

        public static string GetMsiProductIcon(string productCode)
        {
            if (string.IsNullOrEmpty(productCode)) return null;
            const string INSTALLPROPERTY_PRODUCTICON = "ProductIcon";

            uint size = 0;
            uint rc = MsiGetProductInfoW(productCode, INSTALLPROPERTY_PRODUCTICON, null, ref size);
            if (rc != ERROR_MORE_DATA)
            {
                return null;
            }

            // size returned does NOT include the null terminator.
            size += 1;
            var buf = new StringBuilder((int)size);
            rc = MsiGetProductInfoW(productCode, INSTALLPROPERTY_PRODUCTICON, buf, ref size);
            if (rc != ERROR_SUCCESS) return null;
            return buf.ToString();
        }

        // ----- ICO assembly -----
        // GRPICONDIRENTRY layout (packed, 14 bytes):
        //   BYTE  bWidth, bHeight, bColorCount, bReserved
        //   WORD  wPlanes, wBitCount
        //   DWORD dwBytesInRes
        //   WORD  nID
        // ICONDIRENTRY layout (packed, 16 bytes):
        //   BYTE  bWidth, bHeight, bColorCount, bReserved
        //   WORD  wPlanes, wBitCount
        //   DWORD dwBytesInRes
        //   DWORD dwImageOffset

        private sealed class GrpEntry
        {
            public byte  Width, Height, ColorCount, Reserved;
            public ushort Planes, BitCount;
            public uint  BytesInRes;
            public ushort Id;
        }

        private sealed class EnumState
        {
            public int  RequestedIndex;
            public int  IconsFound;
            public IntPtr ResourceHandle;
        }

        public static byte[] ExtractIcoFromBinary(string binaryPath, int iconIndex)
        {
            if (string.IsNullOrEmpty(binaryPath) || !File.Exists(binaryPath)) return null;

            IntPtr module = LoadLibraryExW(binaryPath, IntPtr.Zero,
                LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE);
            if (module == IntPtr.Zero) return null;

            try
            {
                var state = new EnumState { RequestedIndex = iconIndex };
                EnumResNameProcW callback = (hMod, lpType, lpName, lParam) =>
                    EnumGroupIconProc(hMod, lpType, lpName, state);

                EnumResourceNamesExW(
                    module, RT_GROUP_ICON, callback, IntPtr.Zero,
                    RESOURCE_ENUM_MUI | RESOURCE_ENUM_LN | RESOURCE_ENUM_VALIDATE,
                    0);

                if (state.ResourceHandle == IntPtr.Zero) return null;

                IntPtr grpRes = LoadResource(module, state.ResourceHandle);
                if (grpRes == IntPtr.Zero) return null;
                IntPtr grpPtr = LockResource(grpRes);
                if (grpPtr == IntPtr.Zero) return null;

                // GRPICONDIR header: WORD reserved, WORD type, WORD count
                ushort reserved = (ushort)Marshal.ReadInt16(grpPtr, 0);
                ushort type     = (ushort)Marshal.ReadInt16(grpPtr, 2);
                ushort count    = (ushort)Marshal.ReadInt16(grpPtr, 4);
                if (reserved != 0 || type != 1 || count == 0) return null;

                var entries = new GrpEntry[count];
                int p = 6;
                for (int i = 0; i < count; i++)
                {
                    var e = new GrpEntry();
                    e.Width      = Marshal.ReadByte(grpPtr, p + 0);
                    e.Height     = Marshal.ReadByte(grpPtr, p + 1);
                    e.ColorCount = Marshal.ReadByte(grpPtr, p + 2);
                    e.Reserved   = Marshal.ReadByte(grpPtr, p + 3);
                    e.Planes     = (ushort)Marshal.ReadInt16(grpPtr, p + 4);
                    e.BitCount   = (ushort)Marshal.ReadInt16(grpPtr, p + 6);
                    e.BytesInRes = (uint)Marshal.ReadInt32(grpPtr, p + 8);
                    e.Id         = (ushort)Marshal.ReadInt16(grpPtr, p + 12);
                    entries[i] = e;
                    p += 14;
                }

                // Pull each RT_ICON payload.
                var payloads = new byte[count][];
                uint imageOffset = (uint)(6 + count * 16);
                var dirEntries = new byte[count][];
                for (int i = 0; i < count; i++)
                {
                    IntPtr h = FindResourceExW(module, RT_ICON, (IntPtr)entries[i].Id, 0);
                    if (h == IntPtr.Zero) return null;
                    IntPtr res = LoadResource(module, h);
                    if (res == IntPtr.Zero) return null;
                    uint sz = SizeofResource(module, h);
                    if (sz == 0) return null;
                    IntPtr data = LockResource(res);
                    if (data == IntPtr.Zero) return null;

                    byte[] payload = new byte[sz];
                    Marshal.Copy(data, payload, 0, (int)sz);
                    payloads[i] = payload;

                    byte[] dir = new byte[16];
                    dir[0]  = entries[i].Width;
                    dir[1]  = entries[i].Height;
                    dir[2]  = entries[i].ColorCount;
                    dir[3]  = entries[i].Reserved;
                    dir[4]  = (byte)(entries[i].Planes      & 0xFF);
                    dir[5]  = (byte)((entries[i].Planes >> 8) & 0xFF);
                    dir[6]  = (byte)(entries[i].BitCount    & 0xFF);
                    dir[7]  = (byte)((entries[i].BitCount >> 8) & 0xFF);
                    dir[8]  = (byte)( entries[i].BytesInRes        & 0xFF);
                    dir[9]  = (byte)((entries[i].BytesInRes >>  8) & 0xFF);
                    dir[10] = (byte)((entries[i].BytesInRes >> 16) & 0xFF);
                    dir[11] = (byte)((entries[i].BytesInRes >> 24) & 0xFF);
                    dir[12] = (byte)( imageOffset        & 0xFF);
                    dir[13] = (byte)((imageOffset >>  8) & 0xFF);
                    dir[14] = (byte)((imageOffset >> 16) & 0xFF);
                    dir[15] = (byte)((imageOffset >> 24) & 0xFF);
                    dirEntries[i] = dir;

                    imageOffset += sz;
                }

                using (var ms = new MemoryStream())
                {
                    // ICONDIR header
                    ms.WriteByte(0); ms.WriteByte(0);                       // reserved
                    ms.WriteByte(1); ms.WriteByte(0);                       // type = 1
                    ms.WriteByte((byte)(count & 0xFF));                     // count
                    ms.WriteByte((byte)((count >> 8) & 0xFF));

                    foreach (var d in dirEntries) ms.Write(d, 0, d.Length);
                    foreach (var pl in payloads)  ms.Write(pl, 0, pl.Length);
                    return ms.ToArray();
                }
            }
            catch
            {
                return null;
            }
            finally
            {
                FreeLibrary(module);
            }
        }

        public static long GetKeyLastWriteTime(string hive, string subKeyPath, bool wow6432)
        {
            // hive: "HKLM" or "HKCU". Returns FILETIME (ticks since 1601-01-01) or 0 on failure.
            IntPtr root;
            if (string.Equals(hive, "HKLM", StringComparison.OrdinalIgnoreCase)) root = HKEY_LOCAL_MACHINE;
            else if (string.Equals(hive, "HKCU", StringComparison.OrdinalIgnoreCase)) root = HKEY_CURRENT_USER;
            else return 0;

            uint sam = KEY_READ | (wow6432 ? KEY_WOW64_32KEY : KEY_WOW64_64KEY);
            IntPtr h;
            int rc = RegOpenKeyExW(root, subKeyPath, 0, sam, out h);
            if (rc != 0) return 0;
            try
            {
                long ft;
                rc = RegQueryInfoKeyW(h, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                                       IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                                       IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                                       IntPtr.Zero, out ft);
                return rc == 0 ? ft : 0;
            }
            finally
            {
                RegCloseKey(h);
            }
        }

        private static bool EnumGroupIconProc(IntPtr hModule, IntPtr lpType, IntPtr lpName, EnumState state)
        {
            bool found = false;

            if (state.RequestedIndex < 0)
            {
                // Negative -> match by resource ID.
                int wanted = -state.RequestedIndex;
                if (IsIntResource(lpName))
                {
                    if (wanted == (lpName.ToInt64() & 0xFFFF)) found = true;
                }
                else
                {
                    string name = Marshal.PtrToStringUni(lpName);
                    if (!string.IsNullOrEmpty(name) && name[0] == '#')
                    {
                        try
                        {
                            int id = Convert.ToInt32(name.Substring(1), 10);
                            if (wanted == id) found = true;
                        }
                        catch { return false; }
                    }
                }
            }
            else if (state.RequestedIndex == state.IconsFound)
            {
                found = true;
            }

            if (found)
            {
                state.ResourceHandle = FindResourceExW(hModule, lpType, lpName, 0);
                return false;
            }

            state.IconsFound++;
            return true;
        }

        private static bool IsIntResource(IntPtr p)
        {
            // IS_INTRESOURCE: high bits zero, value < 0x10000.
            ulong v = (ulong)p.ToInt64();
            return v >> 16 == 0;
        }
    }
}
'@
}

# =============================================================================
# Helpers
# =============================================================================

function Get-PackageHints {
    # Returns a hint object describing how to recognise this package's ARP entry:
    #   ProductCodes : explicit product code(s) declared in the manifest (best signal)
    #   Names        : DisplayName candidates (English + each Localization PackageName)
    #   Publishers   : Publisher candidates (English + each Localization Publisher)
    #   Version      : PackageVersion (used as a tiebreaker, not required to match)
    param([string] $PackageId)

    $manifestScript = Join-Path $PSScriptRoot 'Get-WinGetManifest.ps1'
    if (-not (Test-Path $manifestScript)) {
        throw "Required helper not found: $manifestScript"
    }

    Write-Verbose "Resolving manifest for '$PackageId' via Get-WinGetManifest.ps1 -AsJson"
    $json = $null
    try {
        $json = & $manifestScript -PackageId $PackageId -AsJson 2>$null
    } catch {
        Write-Verbose "  First lookup threw: $($_.Exception.Message)"
    }
    if (-not $json) {
        # Fresh runner / first-time lookup / preinstalled package: the
        # FileCache hasn't been populated yet (winget only writes it as a side
        # effect of install/show). Retry with -WarmCache, which runs
        # `winget show` to fetch + cache the manifest, then re-reads it.
        Write-Verbose "  Retrying with -WarmCache."
        try {
            $json = & $manifestScript -PackageId $PackageId -AsJson -WarmCache 2>$null
        } catch {
            Write-Verbose "  WarmCache retry threw: $($_.Exception.Message)"
        }
    }
    if (-not $json) {
        throw "Could not retrieve manifest for '$PackageId' (cache lookup, package-index version resolution, and 'winget show' retry did not produce a manifest)."
    }

    try {
        $manifest = $json | ConvertFrom-Json
    }
    catch {
        # The manifest helper falls back to native YAML when Yayaml isn't
        # available; surface a clear error rather than the ConvertFrom-Json one.
        throw "Manifest for '$PackageId' is not JSON. Install the Yayaml PowerShell module: Install-Module Yayaml -Scope CurrentUser"
    }

    $codes      = New-Object System.Collections.Generic.List[string]
    $names      = New-Object System.Collections.Generic.List[string]
    $publishers = New-Object System.Collections.Generic.List[string]

    if ($manifest.PSObject.Properties.Name -contains 'Installers' -and $manifest.Installers) {
        foreach ($inst in $manifest.Installers) {
            if ($inst.PSObject.Properties.Name -contains 'ProductCode' -and $inst.ProductCode) {
                [void]$codes.Add([string]$inst.ProductCode)
            }
            if ($inst.PSObject.Properties.Name -contains 'AppsAndFeaturesEntries' -and $inst.AppsAndFeaturesEntries) {
                foreach ($afe in $inst.AppsAndFeaturesEntries) {
                    if ($afe.PSObject.Properties.Name -contains 'ProductCode' -and $afe.ProductCode) {
                        [void]$codes.Add([string]$afe.ProductCode)
                    }
                    if ($afe.PSObject.Properties.Name -contains 'DisplayName' -and $afe.DisplayName) {
                        [void]$names.Add([string]$afe.DisplayName)
                    }
                    if ($afe.PSObject.Properties.Name -contains 'Publisher' -and $afe.Publisher) {
                        [void]$publishers.Add([string]$afe.Publisher)
                    }
                }
            }
        }
    }

    if ($manifest.PSObject.Properties.Name -contains 'PackageName' -and $manifest.PackageName) {
        [void]$names.Add([string]$manifest.PackageName)
    }
    if ($manifest.PSObject.Properties.Name -contains 'Publisher' -and $manifest.Publisher) {
        [void]$publishers.Add([string]$manifest.Publisher)
    }
    if ($manifest.PSObject.Properties.Name -contains 'Localization' -and $manifest.Localization) {
        foreach ($loc in $manifest.Localization) {
            if ($loc.PSObject.Properties.Name -contains 'PackageName' -and $loc.PackageName) {
                [void]$names.Add([string]$loc.PackageName)
            }
            if ($loc.PSObject.Properties.Name -contains 'Publisher' -and $loc.Publisher) {
                [void]$publishers.Add([string]$loc.Publisher)
            }
        }
    }

    $version = $null
    if ($manifest.PSObject.Properties.Name -contains 'PackageVersion' -and $manifest.PackageVersion) {
        $version = [string]$manifest.PackageVersion
    }

    function Get-Unique-Ci([System.Collections.Generic.IEnumerable[string]] $items) {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $out  = New-Object System.Collections.Generic.List[string]
        foreach ($i in $items) { if ($i -and $seen.Add($i)) { [void]$out.Add($i) } }
        return ,$out.ToArray()
    }

    return [pscustomobject]@{
        ProductCodes = (Get-Unique-Ci $codes)
        Names        = (Get-Unique-Ci $names)
        Publishers   = (Get-Unique-Ci $publishers)
        Version      = $version
    }
}

function Get-ArpHives {
    param([string] $Scope)

    $hives = @()
    if ($Scope -in @('User', 'Both')) {
        $hives += [pscustomobject]@{
            Label = 'HKCU'
            Root  = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::CurrentUser,
                [Microsoft.Win32.RegistryView]::Default)
        }
    }
    if ($Scope -in @('Machine', 'Both')) {
        $hives += [pscustomobject]@{
            Label = 'HKLM-64'
            Root  = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::LocalMachine,
                [Microsoft.Win32.RegistryView]::Registry64)
        }
        $hives += [pscustomobject]@{
            Label = 'HKLM-32'
            Root  = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::LocalMachine,
                [Microsoft.Win32.RegistryView]::Registry32)
        }
    }
    return $hives
}

function Find-ArpEntries {
    param(
        [Parameter(Mandatory)] $Hints,
        [Parameter(Mandatory)] [string] $Scope
    )

    $wantedCodes = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($c in $Hints.ProductCodes) { [void]$wantedCodes.Add($c) }

    $wantedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $Hints.Names) { [void]$wantedNames.Add($n) }

    $wantedPubs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $Hints.Publishers) { [void]$wantedPubs.Add($p) }

    $haveNameMatch = $wantedNames.Count -gt 0 -and $wantedPubs.Count -gt 0

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($hive in (Get-ArpHives -Scope $Scope)) {
        try {
            $arp = $hive.Root.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $arp) { continue }
            try {
                foreach ($name in $arp.GetSubKeyNames()) {
                    $sub = $arp.OpenSubKey($name)
                    if (-not $sub) { continue }
                    try {
                        $codeMatch = $wantedCodes.Contains($name)

                        $displayName = $sub.GetValue('DisplayName')
                        $publisher   = $sub.GetValue('Publisher')
                        $displayVer  = $sub.GetValue('DisplayVersion')
                        $displayIcon = $sub.GetValue('DisplayIcon')
                        $installDate = $sub.GetValue('InstallDate')
                        $winInst     = $sub.GetValue('WindowsInstaller')
                        $isMsi       = ($winInst -is [int] -and $winInst -eq 1)

                        $nameMatch = $false
                        $matchKind = $null
                        if ($codeMatch) {
                            $matchKind = 'ProductCode'
                        }
                        elseif ($haveNameMatch -and $displayName -and $publisher) {
                            $dn = [string]$displayName
                            $pb = [string]$publisher
                            if ($wantedNames.Contains($dn) -and $wantedPubs.Contains($pb)) {
                                $nameMatch = $true
                                $matchKind = 'NamePublisher'
                                if ($Hints.Version -and $displayVer -and ([string]$displayVer -eq $Hints.Version)) {
                                    $matchKind = 'NamePublisherVersion'
                                }
                            }
                            else {
                                # Fuzzy fallback: many installers expand the manifest
                                # name (e.g. "Opera" -> "Opera Stable 117.0.5408.36",
                                # "Chrome" -> "Google Chrome", "Brave" -> "Brave"
                                # but Publisher "Brave Software, Inc"). Accept if
                                # ANY hint name appears as a prefix/substring of the
                                # ARP DisplayName AND ANY hint publisher appears as
                                # a substring of the ARP Publisher.
                                $nameHit = $false
                                foreach ($wn in $wantedNames) {
                                    if ($dn.StartsWith($wn, [StringComparison]::OrdinalIgnoreCase) -or
                                        $dn.IndexOf($wn, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                                        $nameHit = $true; break
                                    }
                                }
                                $pubHit = $false
                                foreach ($wp in $wantedPubs) {
                                    if ($pb.IndexOf($wp, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                                        $wp.IndexOf($pb, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                                        $pubHit = $true; break
                                    }
                                }
                                if ($nameHit -and $pubHit) {
                                    $nameMatch = $true
                                    $matchKind = 'NamePublisherFuzzy'
                                }
                            }
                        }

                        if (-not ($codeMatch -or $nameMatch)) { continue }

                        # Registry key LastWriteTime via RegQueryInfoKey (advapi32).
                        $hiveName = if ($hive.Label -eq 'HKCU') { 'HKCU' } else { 'HKLM' }
                        $isWow32  = ($hive.Label -eq 'HKLM-32')
                        $subPath  = "Software\Microsoft\Windows\CurrentVersion\Uninstall\$name"
                        $ft = [WinGetIconTools.Native]::GetKeyLastWriteTime($hiveName, $subPath, $isWow32)
                        $lastWrite = if ($ft -gt 0) { [datetime]::FromFileTimeUtc($ft) } else { $null }
                        $resolvedDisplayName = $name
                        if ($displayName) {
                            $resolvedDisplayName = [string]$displayName
                        }
                        $resolvedPublisher = ''
                        if ($publisher) {
                            $resolvedPublisher = [string]$publisher
                        }
                        $resolvedDisplayVersion = ''
                        if ($displayVer) {
                            $resolvedDisplayVersion = [string]$displayVer
                        }
                        $resolvedDisplayIcon = ''
                        if ($displayIcon) {
                            $resolvedDisplayIcon = [string]$displayIcon
                        }
                        $resolvedInstallDate = ''
                        if ($installDate) {
                            $resolvedInstallDate = [string]$installDate
                        }

                        $results.Add([pscustomobject]@{
                            Hive          = $hive.Label
                            ProductCode   = $name
                            DisplayName   = $resolvedDisplayName
                            Publisher     = $resolvedPublisher
                            DisplayVersion= $resolvedDisplayVersion
                            DisplayIcon   = $resolvedDisplayIcon
                            InstallDate   = $resolvedInstallDate
                            LastWriteTime = $lastWrite
                            IsMsi         = $isMsi
                            MatchKind     = $matchKind
                        }) | Out-Null
                    }
                    finally { $sub.Dispose() }
                }
            }
            finally { $arp.Dispose() }
        }
        finally { $hive.Root.Dispose() }
    }
    return ,$results.ToArray()
}

function ConvertTo-SafeFileName {
    param([string] $s)
    if ([string]::IsNullOrWhiteSpace($s)) { return 'icon' }
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $s.ToCharArray()) {
        if ($invalid -contains $c) { [void]$sb.Append('_') } else { [void]$sb.Append($c) }
    }
    return $sb.ToString().Trim()
}

# =============================================================================
# Main
# =============================================================================

Write-Verbose "PackageId   : $PackageId"
Write-Verbose "Scope       : $Scope"
Write-Verbose "OutDir      : $OutDir"

$hints = Get-PackageHints -PackageId $PackageId
if (($hints.ProductCodes.Count -eq 0) -and (($hints.Names.Count -eq 0) -or ($hints.Publishers.Count -eq 0))) {
    throw "Manifest for '$PackageId' provides neither ProductCode nor a (PackageName, Publisher) pair to correlate against ARP. (MSIX/Store packages are not supported.)"
}
Write-Verbose ("Hints: ProductCodes=[{0}] Names=[{1}] Publishers=[{2}] Version={3}" -f `
    ($hints.ProductCodes -join ', '), ($hints.Names -join ', '), ($hints.Publishers -join ', '), $hints.Version)

$arpMatches = Find-ArpEntries -Hints $hints -Scope $Scope
if (-not $arpMatches -or $arpMatches.Count -eq 0) {
    throw "No ARP entries matched in scope '$Scope' for '$PackageId'. Is the package actually installed?"
}
Write-Verbose ("ARP matches: {0}" -f $arpMatches.Count)

function Select-NewestArpEntry {
    param([object[]] $Entries)

    if ($Entries.Count -le 1) { return $Entries }

    # Score per entry: prefer DisplayVersion (parseable [version]) > InstallDate > LastWriteTime.
    $scored = foreach ($e in $Entries) {
        $ver = $null
        if ($e.DisplayVersion) {
            try { $ver = [version]$e.DisplayVersion } catch { $ver = $null }
        }
        $instDate = $null
        if ($e.InstallDate -and $e.InstallDate.Length -eq 8) {
            try {
                $instDate = [datetime]::ParseExact($e.InstallDate, 'yyyyMMdd',
                    [System.Globalization.CultureInfo]::InvariantCulture)
            } catch { $instDate = $null }
        }
        [pscustomobject]@{
            Entry         = $e
            Version       = $ver
            InstallDateDt = $instDate
            LastWrite     = $e.LastWriteTime
        }
    }

    $sorted = $scored | Sort-Object `
        @{ Expression = { if ($_.Version)       { $_.Version }       else { [version]'0.0' } }; Descending = $true }, `
        @{ Expression = { if ($_.InstallDateDt) { $_.InstallDateDt } else { [datetime]::MinValue } }; Descending = $true }, `
        @{ Expression = { if ($_.LastWrite)     { $_.LastWrite }     else { [datetime]::MinValue } }; Descending = $true }

    return ,@($sorted[0].Entry)
}

# When multiple ARP entries match, auto-pick the newest by
# DisplayVersion > InstallDate > registry key LastWriteTime.
if ($arpMatches.Count -gt 1) {
    $picked = Select-NewestArpEntry -Entries $arpMatches
    Write-Verbose ("Multiple ARP matches; picking newest: {0} (Version={1}, InstallDate={2}, LastWrite={3})" -f `
        $picked[0].ProductCode, $picked[0].DisplayVersion, $picked[0].InstallDate, $picked[0].LastWriteTime)
    $arpMatches = $picked
}

if (-not (Test-Path -LiteralPath $OutDir)) {
    [void](New-Item -ItemType Directory -Path $OutDir -Force)
}

foreach ($m in $arpMatches) {
    Write-Verbose ("Processing {0} [{1}] -> {2} (msi={3})" -f $m.ProductCode, $m.Hive, $m.DisplayName, $m.IsMsi)

    # 1. Resolve raw icon path
    $rawIcon = if ($m.IsMsi) {
        [WinGetIconTools.Native]::GetMsiProductIcon($m.ProductCode)
    } else {
        $m.DisplayIcon
    }

    if ([string]::IsNullOrWhiteSpace($rawIcon)) {
        Write-Warning ("[{0}] No icon source ({1})." -f $m.ProductCode, $(if ($m.IsMsi) { 'MSI ProductIcon empty' } else { 'DisplayIcon empty' }))
        continue
    }

    # 2. Unquote + parse index + expand env vars
    $parsed = [WinGetIconTools.Native]::ParseIconLocation($rawIcon)
    $iconPath = [WinGetIconTools.Native]::ExpandEnv($parsed.Path)
    $iconIndex = [int]$parsed.Index

    if ([string]::IsNullOrWhiteSpace($iconPath) -or -not (Test-Path -LiteralPath $iconPath)) {
        Write-Warning ("[{0}] Icon source not found on disk: '{1}'" -f $m.ProductCode, $iconPath)
        continue
    }

    # 3. Extract bytes
    $ext = [IO.Path]::GetExtension($iconPath).ToLowerInvariant()
    $bytes = $null
    switch ($ext) {
        '.ico' {
            $bytes = [IO.File]::ReadAllBytes($iconPath)
        }
        { $_ -in '.exe', '.dll' } {
            $bytes = [WinGetIconTools.Native]::ExtractIcoFromBinary($iconPath, $iconIndex)
        }
        default {
            Write-Warning ("[{0}] Unsupported icon source extension '{1}': {2}" -f $m.ProductCode, $ext, $iconPath)
            continue
        }
    }

    if (-not $bytes -or $bytes.Length -eq 0) {
        Write-Warning ("[{0}] Failed to extract icon bytes from '{1}' (index {2})." -f $m.ProductCode, $iconPath, $iconIndex)
        continue
    }

    # 4. Write file
    $safeName = ConvertTo-SafeFileName $m.DisplayName
    $outFile  = Join-Path $OutDir ("{0}.{1}.ico" -f $safeName, $m.ProductCode)

    if ((Test-Path -LiteralPath $outFile) -and -not $Force) {
        Write-Warning ("[{0}] Output file exists, skipping (use -Force to overwrite): {1}" -f $m.ProductCode, $outFile)
    }
    else {
        [IO.File]::WriteAllBytes($outFile, $bytes)
    }

    [pscustomobject]@{
        PackageId     = $PackageId
        ProductCode   = $m.ProductCode
        DisplayName   = $m.DisplayName
        Publisher     = $m.Publisher
        DisplayVersion= $m.DisplayVersion
        InstallDate   = $m.InstallDate
        LastWriteTime = $m.LastWriteTime
        Hive          = $m.Hive
        MatchKind     = $m.MatchKind
        Source        = $iconPath
        IconIndex     = $iconIndex
        IconPath      = $outFile
        SizeBytes     = $bytes.Length
    }
}
