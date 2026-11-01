using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows.Forms;

internal static class DesktopLauncher
{
    [STAThread]
    private static void Main()
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string client = Path.Combine(root, "linux", "desktop.ps1");
        try
        {
            if (!File.Exists(client))
                throw new FileNotFoundException("Please run this EXE from the BackupAssistantCpp folder.", client);

            string executable = Path.GetFileNameWithoutExtension(Application.ExecutablePath);
            Environment.SetEnvironmentVariable("BACKUP_ASSISTANT_TARGET",
                executable.EndsWith("-WSL", StringComparison.OrdinalIgnoreCase) ? "wsl" : "cloud");
            Directory.SetCurrentDirectory(root);

            var session = InitialSessionState.CreateDefault();
            session.AuthorizationManager = new AuthorizationManager("BackupAssistant");
            using (Runspace runspace = RunspaceFactory.CreateRunspace(session))
            using (PowerShell shell = PowerShell.Create())
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                shell.Runspace = runspace;
                shell.AddCommand(client).Invoke();
                if (shell.HadErrors && shell.Streams.Error.Count > 0)
                    throw new InvalidOperationException(shell.Streams.Error[0].ToString());
            }
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "Backup Assistant", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
