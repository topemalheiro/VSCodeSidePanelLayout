using System;
using System.Diagnostics;
using System.Linq;
using Microsoft.Win32;

class Program
{
    static void Main(string[] args)
    {
        if (args.Length == 0) return;

        string exe = args[0];
        string[] originalArgs = args.Skip(1).ToArray();
        string wrapperPath = System.Reflection.Assembly.GetExecutingAssembly().Location;
        string ifeoKeyPath = @"Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Code.exe";

        // Temporarily remove IFEO to prevent infinite recursion
        try { Registry.CurrentUser.DeleteSubKey(ifeoKeyPath, false); } catch { }

        // Build args string
        string allArgs = string.Join(" ", originalArgs.Select(a => a.Contains(" ") ? "\"" + a + "\"" : a));

        // Add CDP flag only for the main process (not child processes like --type=renderer)
        bool isChild = originalArgs.Any(a => a.StartsWith("--type="));
        if (!isChild && !allArgs.Contains("remote-debugging-port"))
        {
            allArgs = "--remote-debugging-port=9222 " + allArgs;
        }

        // Launch real Code.exe
        try
        {
            var psi = new ProcessStartInfo(exe, allArgs) { UseShellExecute = false };
            Process.Start(psi);
        }
        catch { }

        // Re-add IFEO key
        try
        {
            var key = Registry.CurrentUser.CreateSubKey(ifeoKeyPath);
            key.SetValue("Debugger", "\"" + wrapperPath + "\"");
            key.Close();
        }
        catch { }
    }
}
