// ByteCut - .exe launcher
// Developer: Inzamam Islam
//
// Hosts PowerShell inside this process and runs the embedded src\ByteCut.ps1.
// src\Core.ps1 is passed in as $CoreCode, and src\Native.cs is compiled into this .exe,
// so the app starts without a console window and without compiling anything at startup.
// Built by build\Build.ps1 with the csc.exe that ships with Windows (C# 5, .NET Framework 4.x).
using System;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

namespace ByteCut
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            try
            {
                string core = ReadResource("Core.ps1");
                string ui = ReadResource("ByteCut.ps1");

                InitialSessionState iss = InitialSessionState.CreateDefault();
                iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
                iss.ApartmentState = ApartmentState.STA;
                iss.ThreadOptions = PSThreadOptions.UseCurrentThread;

                using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
                {
                    rs.Open();
                    rs.SessionStateProxy.SetVariable("CoreCode", core);
                    rs.SessionStateProxy.SetVariable("AppExePath", Assembly.GetExecutingAssembly().Location);
                    rs.SessionStateProxy.SetVariable("AppArgs", args);

                    using (PowerShell ps = PowerShell.Create())
                    {
                        ps.Runspace = rs;
                        ps.AddScript(ui);
                        ps.Invoke();
                    }
                }
                return 0;
            }
            catch (Exception ex)
            {
                Exception inner = ex;
                while (inner.InnerException != null) inner = inner.InnerException;
                MessageBox.Show("ByteCut could not start:\n\n" + inner.Message, "ByteCut",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }

        private static string ReadResource(string name)
        {
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
            {
                if (s == null) throw new InvalidOperationException("Missing embedded resource: " + name);
                using (StreamReader r = new StreamReader(s, Encoding.UTF8)) return r.ReadToEnd();
            }
        }
    }
}
