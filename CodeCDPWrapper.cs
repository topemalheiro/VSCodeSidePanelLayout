using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

class Program
{
    static readonly string DefaultCodeRoot = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Programs",
        "Microsoft VS Code"
    );

    static bool IsChildLaunch(string[] originalArgs)
    {
        return originalArgs.Any(arg => arg.StartsWith("--type=", StringComparison.OrdinalIgnoreCase));
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

    static string TryGetSiblingRealCodePath(string wrapperPath)
    {
        string wrapperDirectory = Path.GetDirectoryName(wrapperPath);
        if (string.IsNullOrWhiteSpace(wrapperDirectory))
        {
            return null;
        }

        string siblingRealPath = Path.Combine(wrapperDirectory, "Code.real.exe");
        return File.Exists(siblingRealPath) ? siblingRealPath : null;
    }

    static string ResolveTargetExe(string wrapperPath)
    {
        string siblingRealPath = TryGetSiblingRealCodePath(wrapperPath);
        if (!string.IsNullOrWhiteSpace(siblingRealPath))
        {
            return siblingRealPath;
        }

        string managedRealPath = Path.Combine(DefaultCodeRoot, "Code.real.exe");
        if (File.Exists(managedRealPath))
        {
            return managedRealPath;
        }

        return Path.Combine(DefaultCodeRoot, "Code.exe");
    }

    static void Main(string[] args)
    {
        string wrapperPath = Process.GetCurrentProcess().MainModule.FileName;
        string targetExe = ResolveTargetExe(wrapperPath);

        if (
            string.IsNullOrWhiteSpace(targetExe)
            || !File.Exists(targetExe)
            || string.Equals(
                Path.GetFullPath(targetExe),
                Path.GetFullPath(wrapperPath),
                StringComparison.OrdinalIgnoreCase
            )
        )
        {
            return;
        }

        string[] originalArgs = args;
        var launchArgs = new List<string>(originalArgs);

        bool hasCdpFlag = originalArgs.Any(
            a => a.IndexOf("remote-debugging-port", StringComparison.OrdinalIgnoreCase) >= 0
        );

        if (!IsChildLaunch(originalArgs) && !hasCdpFlag)
        {
            launchArgs.Insert(0, "--remote-debugging-port=9222");
        }

        string allArgs = string.Join(" ", launchArgs.Select(QuoteArgument));

        try
        {
            var psi = new ProcessStartInfo(targetExe, allArgs)
            {
                UseShellExecute = false,
                WorkingDirectory = Path.GetDirectoryName(targetExe) ?? DefaultCodeRoot,
            };
            Process.Start(psi);
        }
        catch { }
    }
}
