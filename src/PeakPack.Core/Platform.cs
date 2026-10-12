using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace PeakPack.Core;

/// <summary>
/// Where PeakPack runs. On Mac, the same Windows PeakPack.exe runs inside our Wine prefix (MacPort DESIGN Track D),
/// so it must notice that and adapt: no shortcuts/registry uninstall entry/self-install, a per-app Wine DLL override
/// so Doorstop's winhttp.dll proxy loads, Mac launch arguments and Mac key defaults from the signed manifest.
/// Windows behaviour is unchanged.
/// Detection: ntdll exports wine_get_version only under Wine; wine_get_host_version reports "Darwin" on macOS.
/// Tests can set PEAKPACK_FAKE_PLATFORM=wine-mac (or wine-linux); a faked platform never writes to the registry.
/// </summary>
public static class Platform
{
    public enum Kind { Windows, WineMac, WineLinux }

    public static Kind Current { get; }
    public static bool IsFake { get; }

    static Platform()
    {
        Current = Detect(out var fake);
        IsFake = fake;
    }
    public static bool IsWine => Current != Kind.Windows;
    public static bool IsMac => Current == Kind.WineMac;
    public static string Describe => Current switch
    {
        Kind.WineMac => "Wine on macOS" + (IsFake ? " (simulated)" : ""),
        Kind.WineLinux => "Wine on Linux" + (IsFake ? " (simulated)" : ""),
        _ => "Windows",
    };

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr module, string name);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void WineHostVersion(out IntPtr sysname, out IntPtr release);

    static Kind Detect(out bool fake)
    {
        fake = false;
        switch (Environment.GetEnvironmentVariable("PEAKPACK_FAKE_PLATFORM")?.Trim().ToLowerInvariant())
        {
            case "wine-mac": fake = true; return Kind.WineMac;
            case "wine-linux": fake = true; return Kind.WineLinux;
        }
        try
        {
            var ntdll = GetModuleHandle("ntdll.dll");
            if (ntdll == IntPtr.Zero || GetProcAddress(ntdll, "wine_get_version") == IntPtr.Zero) return Kind.Windows;
            var hv = GetProcAddress(ntdll, "wine_get_host_version");
            if (hv == IntPtr.Zero) return Kind.WineLinux;
            Marshal.GetDelegateForFunctionPointer<WineHostVersion>(hv)(out var sys, out _);
            return string.Equals(Marshal.PtrToStringAnsi(sys), "Darwin", StringComparison.OrdinalIgnoreCase) ? Kind.WineMac : Kind.WineLinux;
        }
        catch { return Kind.Windows; }
    }

    /// <summary>Under Wine, Doorstop's winhttp.dll in the game folder only loads if Wine prefers the native DLL over its
    /// builtin one. Set it per app (HKCU\Software\Wine\AppDefaults\PEAK.exe\DllOverrides winhttp=native,builtin) before
    /// each launch; the launcher also passes WINEDLLOVERRIDES=winhttp=n,b to processes it starts directly.
    /// No-op on Windows; logged-only when the platform is simulated.</summary>
    public static void EnsureWineDllOverride(AppPaths paths)
    {
        if (!IsWine) return;
        if (IsFake) { paths.Log(@"(simulated Wine) would set HKCU\Software\Wine\AppDefaults\PEAK.exe\DllOverrides winhttp=native,builtin"); return; }
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(@"Software\Wine\AppDefaults\PEAK.exe\DllOverrides");
            if (k.GetValue("winhttp") as string != "native,builtin") k.SetValue("winhttp", "native,builtin");
        }
        catch (Exception ex) { paths.Log("Couldn't set the Wine DLL override: " + ex.Message); }
    }

    public const string WineDllOverridesEnv = "winhttp=n,b";
}
