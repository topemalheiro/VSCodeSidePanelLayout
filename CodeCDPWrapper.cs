using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using Microsoft.Win32;

class Program
{
    static bool IsCliLaunch(string[] originalArgs)
    {
        if (originalArgs.Length == 0)
        {
            return false;
        }

        string firstArg = originalArgs[0];
        string fileName = Path.GetFileName(firstArg);
        bool looksLikeCliScript =
            fileName.Equals("cli.js", StringComparison.OrdinalIgnoreCase) ||
            fileName.Equals("cli.mjs", StringComparison.OrdinalIgnoreCase);

        bool runsAsNode = string.Equals(
            Environment.GetEnvironmentVariable("ELECTRON_RUN_AS_NODE"),
            "1",
            StringComparison.Ordinal
        );

        return looksLikeCliScript && runsAsNode;
    }

    static string QuoteArgument(string arg)
    {
        if (string.IsNullOrEmpty(arg))
        {
            return "\"\"";
        }

        if (!arg.Any(ch => char.IsWhiteSpace(ch) || ch == '"'))
        {
            return arg;
        }

        return "\"" + arg.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }

    static void Main(string[] args)
    {
        if (args.Length == 0) return;

        string exe = args[0];
        string[] originalArgs = args.Skip(1).ToArray();
        string wrapperPath = System.Reflection.Assembly.GetExecutingAssembly().Location;
        string ifeoKeyPath = @"Software\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Code.exe";

        // Temporarily remove IFEO to prevent infinite recursion
        try { Registry.CurrentUser.DeleteSubKey(ifeoKeyPath, false); } catch { }

        var launchArgs = new List<string>(originalArgs);

        // Add CDP flag only for the main process (not child processes like --type=renderer)
        bool isChild = originalArgs.Any(a => a.StartsWith("--type=", StringComparison.OrdinalIgnoreCase));
        bool hasCdpFlag = originalArgs.Any(
            a => a.IndexOf("remote-debugging-port", StringComparison.OrdinalIgnoreCase) >= 0
        );

        if (!isChild && !hasCdpFlag)
        {
            // `code.cmd` launches Code.exe in Node mode to run cli.js first.
            // In that path the flag must sit after the script path so the CLI forwards it
            // to the real GUI process on first open.
            if (IsCliLaunch(originalArgs))
            {
                launchArgs.Insert(1, "--remote-debugging-port=9222");
            }
            else
            {
                launchArgs.Insert(0, "--remote-debugging-port=9222");
            }
        }

        string allArgs = string.Join(" ", launchArgs.Select(QuoteArgument));

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
