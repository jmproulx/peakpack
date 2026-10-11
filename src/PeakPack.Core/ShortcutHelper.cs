using System.Runtime.InteropServices;
using System.Text;
using IPersistFile = System.Runtime.InteropServices.ComTypes.IPersistFile;

namespace PeakPack.Core;

/// <summary>
/// Creates and reads Windows .lnk shortcut files using the Shell Link COM object,
/// with the COM types declared by hand (no IWshRuntimeLibrary / COM type library reference).
/// </summary>
public static class ShortcutHelper
{
    // Buffer size for path/argument/description out-parameters. Large enough for any
    // value the shell will store in a .lnk (arguments can exceed MAX_PATH).
    private const int TextBufferChars = 32767;

    // STGM_READ: open the .lnk read-only when loading it.
    private const int StgmRead = 0x00000000;

    /// <summary>
    /// Create (or overwrite) a .lnk shortcut at <paramref name="lnkPath"/>.
    /// The parent directory is created if it does not exist.
    /// </summary>
    public static void CreateShortcut(
        string lnkPath,
        string targetExe,
        string arguments,
        string workingDir,
        string? iconPath,
        int iconIndex,
        string description)
    {
        ArgumentException.ThrowIfNullOrEmpty(lnkPath);
        ArgumentException.ThrowIfNullOrEmpty(targetExe);

        lnkPath = Path.GetFullPath(lnkPath);
        string? parentDir = Path.GetDirectoryName(lnkPath);
        if (!string.IsNullOrEmpty(parentDir))
        {
            Directory.CreateDirectory(parentDir);
        }

        IShellLinkW link = (IShellLinkW)new ShellLinkCoClass();
        try
        {
            link.SetPath(targetExe);
            link.SetArguments(arguments ?? string.Empty);
            link.SetWorkingDirectory(workingDir ?? string.Empty);
            link.SetDescription(description ?? string.Empty);

            if (!string.IsNullOrEmpty(iconPath))
            {
                link.SetIconLocation(iconPath, iconIndex);
            }

            // The IPersistFile cast refers to the same managed RCW as 'link', so releasing
            // 'link' below releases the underlying COM object.
            IPersistFile file = (IPersistFile)link;
            file.Save(lnkPath, true);
        }
        finally
        {
            Marshal.FinalReleaseComObject(link);
        }
    }

    /// <summary>
    /// Read the target path, arguments and icon location of an existing .lnk file.
    /// Returns null if the file does not exist.
    /// </summary>
    public static (string Target, string Arguments, string IconPath, int IconIndex)? ReadShortcut(string lnkPath)
    {
        if (string.IsNullOrEmpty(lnkPath) || !File.Exists(lnkPath))
        {
            return null;
        }

        IShellLinkW link = (IShellLinkW)new ShellLinkCoClass();
        try
        {
            IPersistFile file = (IPersistFile)link;
            file.Load(Path.GetFullPath(lnkPath), StgmRead);

            var target = new StringBuilder(TextBufferChars);
            link.GetPath(target, target.Capacity, IntPtr.Zero, 0);

            var arguments = new StringBuilder(TextBufferChars);
            link.GetArguments(arguments, arguments.Capacity);

            var iconPath = new StringBuilder(TextBufferChars);
            link.GetIconLocation(iconPath, iconPath.Capacity, out int iconIndex);

            return (target.ToString(), arguments.ToString(), iconPath.ToString(), iconIndex);
        }
        finally
        {
            Marshal.FinalReleaseComObject(link);
        }
    }

    /// <summary>The current user's Desktop folder.</summary>
    public static string DesktopDir =>
        Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);

    /// <summary>The current user's Start Menu "Programs" folder.</summary>
    public static string StartMenuProgramsDir =>
        Environment.GetFolderPath(Environment.SpecialFolder.Programs);

    // Classic COM interop: the ShellLink coclass (CLSID_ShellLink).
    [ComImport]
    [Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLinkCoClass
    {
    }

    // IShellLinkW (IID_IShellLinkW). Method order must match the COM vtable exactly.
    // Non-PreserveSig (the default), so failing HRESULTs throw COMException.
    [ComImport]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLinkW
    {
        void GetPath(
            [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile,
            int cchMaxPath,
            IntPtr pfd, // WIN32_FIND_DATAW*, may be NULL
            uint fFlags);

        void GetIDList(out IntPtr ppidl);

        void SetIDList(IntPtr pidl);

        void GetDescription(
            [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName,
            int cchMaxName);

        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);

        void GetWorkingDirectory(
            [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir,
            int cchMaxPath);

        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);

        void GetArguments(
            [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs,
            int cchMaxPath);

        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);

        void GetHotkey(out short pwHotkey);

        void SetHotkey(short wHotkey);

        void GetShowCmd(out int piShowCmd);

        void SetShowCmd(int iShowCmd);

        void GetIconLocation(
            [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath,
            int cchIconPath,
            out int piIcon);

        void SetIconLocation(
            [MarshalAs(UnmanagedType.LPWStr)] string pszIconPath,
            int iIcon);

        void SetRelativePath(
            [MarshalAs(UnmanagedType.LPWStr)] string pszPathRel,
            uint dwReserved);

        void Resolve(IntPtr hwnd, uint fFlags);

        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }
}
