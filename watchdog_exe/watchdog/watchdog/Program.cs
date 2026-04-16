using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Threading;

class Program
{
    static string scriptPath = Path.Combine(Directory.GetCurrentDirectory(), "watchdog.ps1");
    static string workingDir = AppDomain.CurrentDomain.BaseDirectory;
    static string url = "http://localhost:8080";

    static void Main()
    {
        Directory.SetCurrentDirectory(AppDomain.CurrentDomain.BaseDirectory);

        StartWatchdogVisible();
        WaitForDashboard();
        OpenDashboard();
    }

    // ================================
    // START WATCHDOG (VISIBLE)
    // ================================
    static void StartWatchdogVisible()
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = @"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
            Arguments = $"-ExecutionPolicy Bypass -NoExit -File \"{scriptPath}\"",
            WorkingDirectory = workingDir,
            UseShellExecute = true,
            CreateNoWindow = false
        });
    }

    // ================================
    // WAIT FOR DASHBOARD
    // ================================
    static void WaitForDashboard()
    {
        using var client = new HttpClient();
        client.Timeout = TimeSpan.FromSeconds(1);

        for (int i = 0; i < 20; i++)
        {
            try
            {
                var res = client.GetAsync(url).Result;
                if (res.IsSuccessStatusCode)
                    return;
            }
            catch { }

            Thread.Sleep(1000);
        }
    }

    // ================================
    // OPEN DASHBOARD
    // ================================
    static void OpenDashboard()
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = url,
            UseShellExecute = true
        });
    }
}