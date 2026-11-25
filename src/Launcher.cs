using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

namespace GameLoopDoctor
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string scriptPath = Path.Combine(baseDir, "GameLoop-Doctor.ps1");
            bool isTemp = false;

            // If GameLoop-Doctor.ps1 is not next to the .exe, extract embedded copy to temp
            if (!File.Exists(scriptPath))
            {
                Assembly asm = Assembly.GetExecutingAssembly();
                using (Stream s = asm.GetManifestResourceStream("GameLoop-Doctor.ps1"))
                {
                    if (s == null)
                    {
                        Console.Error.WriteLine("GameLoop-Doctor.ps1 not found next to executable.");
                        return 1;
                    }
                    string tmpDir = Path.Combine(Path.GetTempPath(), "GameLoopDoctor");
                    Directory.CreateDirectory(tmpDir);
                    scriptPath = Path.Combine(tmpDir, "GameLoop-Doctor.ps1");
                    using (FileStream fs = File.Create(scriptPath))
                    {
                        s.CopyTo(fs);
                    }
                    isTemp = true;
                }
            }

            string extraArgs = "";
            foreach (string a in args)
            {
                extraArgs += " \"" + a.Replace("\"", "\\\"") + "\"";
            }

            ProcessStartInfo psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"" + extraArgs,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            try
            {
                using (Process p = Process.Start(psi))
                {
                    p.WaitForExit();
                    return p.ExitCode;
                }
            }
            finally
            {
                if (isTemp)
                {
                    try { File.Delete(scriptPath); } catch { }
                }
            }
        }
    }
}
