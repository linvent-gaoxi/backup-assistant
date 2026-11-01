param([switch]$SmokeTest)

$ErrorActionPreference = 'Stop'
# Set DPI awareness before creating any WinForms window.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class BackupDesktopDpi {
    [DllImport("shcore.dll")]
    public static extern int SetProcessDpiAwareness(int awareness);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
"@
try { [void][BackupDesktopDpi]::SetProcessDpiAwareness(1) }
catch { [void][BackupDesktopDpi]::SetProcessDPIAware() }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$root = Split-Path -Parent $PSScriptRoot
$connectionConfig = Join-Path $env:LOCALAPPDATA 'BackupAssistant-Server.txt'
$addressHistoryFile = Join-Path $env:LOCALAPPDATA 'BackupAssistant-AddressHistory.json'
$cloudAddress = 'ssh://TencentCloud'
$wslAddress = 'https://127.0.0.1:19444'
$savedAddress = if (Test-Path -LiteralPath $connectionConfig -PathType Leaf) {
    [IO.File]::ReadAllText($connectionConfig).Trim()
} elseif ($env:BACKUP_ASSISTANT_TARGET -eq 'wsl') { $wslAddress } else { $cloudAddress }
if ($savedAddress -notin $cloudAddress,$wslAddress) { $savedAddress = $cloudAddress }
$localTarget = $savedAddress -eq $wslAddress
$serverName = if ($localTarget) { 'WSL' } else { '腾讯云' }
$baseUrl = if ($localTarget) { 'http://127.0.0.1:18766' } else { 'http://127.0.0.1:18765' }
$apiHeaders = @{'X-Backup-Console'='1'}

function Invoke-BackupApi($Action, $Data) {
    $request = @{Uri="$baseUrl/api/$Action"; Headers=$apiHeaders; TimeoutSec=3}
    if ($Action -eq 'email-code') { $request.TimeoutSec = 30 }
    if ($null -ne $Data) {
        $request.Method = 'POST'
        $request.ContentType = 'application/json; charset=utf-8'
        $request.Body = [Text.Encoding]::UTF8.GetBytes(($Data | ConvertTo-Json -Compress -Depth 5))
    }
    Invoke-RestMethod @request
}

if ($SmokeTest) {
    $state = Invoke-BackupApi state
    if (!$state.example -or $null -eq $state.authenticated) {
        throw "无法连接 $serverName 备份空间"
    }
    "PASS Windows client connected to $serverName storage"
    return
}

$ink = [Drawing.Color]::FromArgb(31,31,31)
$muted = [Drawing.Color]::FromArgb(90,90,90)
$accent = [Drawing.Color]::FromArgb(0,103,192)
$border = [Drawing.Color]::FromArgb(224,225,228)
$white = [Drawing.Color]::White
Add-Type -ReferencedAssemblies System.Windows.Forms.dll,System.Drawing.dll -TypeDefinition @"
using System;
using System.Windows.Forms;
using System.Drawing;
using System.Runtime.InteropServices;

public sealed class BackupClientForm : Form {
    public bool CanResize { get; set; }

    [DllImport("user32.dll")]
    private static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);

    public void DragWindow() {
        ReleaseCapture();
        SendMessage(Handle, 0x00A1, new IntPtr(2), IntPtr.Zero);
    }

    public void ToggleMaximize() {
        if (!CanResize) return;
        MaximizedBounds = Screen.FromControl(this).WorkingArea;
        WindowState = WindowState == FormWindowState.Maximized
            ? FormWindowState.Normal : FormWindowState.Maximized;
    }

    protected override void WndProc(ref Message message) {
        const int getIcon = 0x007F;
        if (message.Msg == getIcon && Icon != null) {
            message.Result = Icon.Handle;
            return;
        }
        base.WndProc(ref message);
        if (message.Msg != 0x0084 || !CanResize || WindowState != FormWindowState.Normal) return;
        long position = message.LParam.ToInt64();
        Point point = PointToClient(new Point((short)position, (short)(position >> 16)));
        const int edge = 6;
        bool left = point.X < edge;
        bool right = point.X >= ClientSize.Width - edge;
        bool top = point.Y < edge;
        bool bottom = point.Y >= ClientSize.Height - edge;
        if (top) message.Result = new IntPtr(left ? 13 : right ? 14 : 12);
        else if (bottom) message.Result = new IntPtr(left ? 16 : right ? 17 : 15);
        else if (left || right) message.Result = new IntPtr(left ? 10 : 11);
    }
}
"@
$form = New-Object BackupClientForm
$appIconPath = Join-Path $PSScriptRoot 'BackupAssistant.ico'
if (Test-Path -LiteralPath $appIconPath -PathType Leaf) {
    $appIcon = New-Object Drawing.Icon($appIconPath)
    $form.Icon = $appIcon
    $form.Add_Disposed({ $appIcon.Dispose() })
}
$form.ShowIcon = $false
$form.FormBorderStyle = 'None'
$form.Text = '文件备份助手'
$form.ClientSize = New-Object Drawing.Size(1050,760)
$form.MinimumSize = New-Object Drawing.Size(1066,799)
$form.StartPosition = 'CenterScreen'
$form.AutoScaleMode = 'None'
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI',10)
$form.ForeColor = $ink
$windowSurface = [Drawing.Color]::FromArgb(243,243,243)
$form.BackColor = $windowSurface
$form.SuspendLayout()

function Scale-DesktopLayout($Window) {
    $graphics = $Window.CreateGraphics()
    try { $factor = [single]($graphics.DpiX / 96.0) }
    finally { $graphics.Dispose() }
    if ($factor -eq 1) { return }
    $width = $Window.ClientSize.Width
    $height = $Window.ClientSize.Height
    $Window.MinimumSize = [Drawing.Size]::Empty
    $Window.Scale((New-Object Drawing.SizeF($factor,$factor)))
    $Window.ClientSize = New-Object Drawing.Size(([int]($width*$factor)),([int]($height*$factor)))
}

function Add-Caption($Parent,$Text,$X,$Y,$Width,$Height,$Size,$Color,[switch]$Bold) {
    $caption = New-Object Windows.Forms.Label
    $caption.Text = $Text
    $caption.SetBounds($X,$Y,$Width,$Height)
    $caption.ForeColor = $Color
    $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $caption.Font = New-Object Drawing.Font('Microsoft YaHei UI',$Size,$style)
    $Parent.Controls.Add($caption)
    return $caption
}

$rail = New-Object Windows.Forms.Panel
$rail.SetBounds(0,0,208,760)
$rail.Anchor = 'Top,Bottom,Left'
$rail.BackColor = $form.BackColor
$form.Controls.Add($rail)
$railMuted = [Drawing.Color]::FromArgb(76,76,76)
$null = Add-Caption $rail 'BACKUP STUDIO' 23 27 170 22 10 $railMuted -Bold
$null = Add-Caption $rail '文件备份助手' 22 53 176 38 17 $ink -Bold
$null = Add-Caption $rail '工作区' 24 116 165 24 10 $railMuted -Bold
$connection = Add-Caption $rail "●  正在连接 $serverName" 23 700 174 26 10 $railMuted
$connection.Anchor = 'Bottom,Left'

$heading = Add-Caption $form '' 234 23 770 43 23 $ink -Bold
$description = Add-Caption $form '' 237 73 766 28 10 $muted
$workspace = New-Object Windows.Forms.Panel
$workspace.SetBounds(233,108,800,468)
$workspace.BackColor = $white
$workspace.Anchor = 'Top,Left,Right'
$form.Controls.Add($workspace)
$script:pages = @()
$script:navButtons = @()

$statusCard = New-Object Windows.Forms.Panel
$statusCard.SetBounds(233,593,800,149)
$statusCard.Anchor = 'Top,Bottom,Left,Right'
$statusCard.BackColor = $white
$form.Controls.Add($statusCard)
$null = Add-Caption $statusCard '任务状态' 20 13 170 30 11 $ink -Bold
$status = New-Object Windows.Forms.TextBox
$status.Multiline = $true
$status.ReadOnly = $true
$status.ScrollBars = 'Vertical'
$status.BackColor = [Drawing.Color]::FromArgb(248,248,248)
$status.BorderStyle = 'None'
$status.ForeColor = $ink
$status.SetBounds(20,51,760,81)
$status.Anchor = 'Top,Bottom,Left,Right'
$status.Text = "正在连接 $serverName…"
$statusCard.Controls.Add($status)
$progressLabel = Add-Caption $statusCard '' 20 42 760 22 9 $muted
$progressLabel.Anchor = 'Top,Left,Right'
$progressBar = New-Object Windows.Forms.ProgressBar
$progressBar.SetBounds(20,66,760,8)
$progressBar.Anchor = 'Top,Left,Right'
$statusCard.Controls.Add($progressBar)
$progressBar.Hide()
$progressLabel.Hide()
$script:notice = ''
$script:initialized = $false
$script:authenticated = $false
$script:activeUser = ''
$script:jobCache = ''
$script:starting = $false
$script:startupTime = [DateTime]::UtcNow
$submitButtons = New-Object 'System.Collections.Generic.List[Windows.Forms.Button]'

function Set-FluentCorners($Control, [int]$Diameter = 0) {
    if (!$Diameter) { $Diameter = [int]($Control.Height * 0.46) }
    $diameter = [Math]::Min($Control.Height, $Diameter)
    if ($diameter -lt 2 -or $Control.Width -lt $diameter) { return }
    $shape = New-Object Drawing.Drawing2D.GraphicsPath
    try {
        $shape.AddArc(0,0,$diameter,$diameter,180,90)
        $shape.AddArc(($Control.Width-$diameter),0,$diameter,$diameter,270,90)
        $shape.AddArc(($Control.Width-$diameter),($Control.Height-$diameter),$diameter,$diameter,0,90)
        $shape.AddArc(0,($Control.Height-$diameter),$diameter,$diameter,90,90)
        $shape.CloseFigure()
        $oldRegion = $Control.Region
        $Control.Region = New-Object Drawing.Region($shape)
        if ($oldRegion) { $oldRegion.Dispose() }
    } finally { $shape.Dispose() }
}

function Add-Button($Parent, $Text, $X, $Y, $Width, $Handler, [switch]$Primary) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.SetBounds($X,$Y,$Width,32)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(230,230,230)
    $button.BackColor = [Drawing.Color]::FromArgb(240,240,240)
    $button.ForeColor = $ink
    $button.Cursor = [Windows.Forms.Cursors]::Hand
    if ($Primary) {
        $button.FlatAppearance.BorderSize = 0
        $button.BackColor = $accent
        $button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(0,91,171)
        $button.ForeColor = [Drawing.Color]::White
    }
    $button.Add_Click($Handler)
    $Parent.Controls.Add($button)
    if ($Parent -ne $rail -and $Parent -ne $chrome) {
        $button.Add_SizeChanged({ Set-FluentCorners $this })
        Set-FluentCorners $button
    }
    return $button
}

function Select-Page([int]$Index) {
    if (!$script:authenticated -and $Index -notin 6,7) { $Index = 6 }
    if ($script:serverConfigBounds) {
        $compact = $Index -in 6,7
        $serverConfig.Size = if ($compact) { $script:compactConfigSize } else { $script:regularConfigSize }
        for ($i = 0; $i -lt $serverConfig.Controls.Count; $i++) {
            $control = $serverConfig.Controls[$i]
            $control.Bounds = if ($compact) { $script:compactConfigBounds[$i] } else { $script:serverConfigBounds[$i] }
        }
        $serverExample.Visible = !$compact
        $serverAddress.BorderStyle = if ($compact) { 'None' } else { 'FixedSingle' }
        $serverConfig.Invalidate()
        $serverConfig.BackColor = if ($compact) { [Drawing.Color]::Transparent } else { $white }
    }
    if ($script:mainClientSize) {
        $windowMode = if ($script:authenticated) { 'workspace' } elseif ($Index -eq 7) { 'register' } else { 'login' }
        if ($script:windowMode -ne $windowMode) {
            $screen = [Windows.Forms.Screen]::FromControl($form).WorkingArea
            $form.WindowState = 'Normal'
            $form.MinimumSize = [Drawing.Size]::Empty
            $form.CanResize = $script:authenticated
            $chromeMaximize.Visible = $script:authenticated
            if ([Environment]::OSVersion.Version.Build -ge 22000) {
                $null = [BackupWindowAppearance]::Apply($form.Handle, $true)
            }
            if ($script:authenticated) {
                $form.ClientSize = $script:mainClientSize
            } else {
                $top = if ($Index -eq 7) { $script:loginWorkspaceTop + $script:registerConfigTop } else { $script:loginWorkspaceTop + $script:loginConfigTop }
                $form.ClientSize = New-Object Drawing.Size(
                    ($script:compactLoginWidth + 2),
                    ($loginCard.Height + 2))
            }
            $form.MinimumSize = $form.Size
            if ($form.Visible) {
                $form.Location = New-Object Drawing.Point(
                    ($screen.Left + [int][Math]::Max(0,($screen.Width - $form.Width) / 2)),
                    ($screen.Top + [int][Math]::Max(0,($screen.Height - $form.Height) / 2)))
            }
            $script:windowMode = $windowMode
        }
    }
    $rail.Visible = $script:authenticated
    $heading.Left = if ($script:authenticated) { $script:mainHeadingLeft } else { $script:guestLeft }
    $description.Left = $heading.Left
    $workspace.Left = $heading.Left
    $workspace.Width = $form.ClientSize.Width - $workspace.Left - $script:guestLeft
    $loginLayout = $Index -in 6,7
    $heading.Visible = !$loginLayout
    $description.Visible = !$loginLayout
    $workspace.Top = if ($loginLayout) { 1 } else { $script:mainWorkspaceTop }
    $workspace.BackColor = if ($loginLayout) { $form.BackColor } else { $white }
    $workspace.Anchor = if ($loginLayout) { 'Top' } else { 'Top,Left,Right' }
    if ($loginLayout) {
        $workspace.Width = $script:compactLoginWidth
        $workspace.Left = [int](($form.ClientSize.Width - $workspace.Width) / 2)
    }
    if ($script:mainWorkspaceHeight) {
        $workspace.Height = if ($script:authenticated) { $script:mainWorkspaceHeight } else { $loginCard.Height }
    }
    $form.BackColor = if ($loginLayout) { [Drawing.Color]::FromArgb(187,193,202) } else { $windowSurface }
    if ($loginLayout -and $script:mainClientSize) {
        $cornerDiameter = [int](20 * $layoutFactor)
        Set-FluentCorners $form $cornerDiameter
        Set-FluentCorners $workspace ($cornerDiameter - 2)
    } else {
        foreach ($surface in $form,$workspace) {
            if ($surface.Region) {
                $previousRegion = $surface.Region
                $surface.Region = $null
                $previousRegion.Dispose()
            }
        }
    }
    if ($chrome) {
        $chrome.Parent = if ($loginLayout) { $connectionSurface } else { $form }
        $chrome.BackColor = if ($loginLayout) { [Drawing.Color]::Transparent } else { $form.BackColor }
        foreach ($button in $chromeClose,$chromeMaximize,$chromeMinimize) {
            $button.BackColor = $chrome.BackColor
        }
        $chrome.BringToFront()
    }
    $statusCard.Visible = $script:authenticated
    if ($Index -in 6,7) {
        $serverConfig.Parent = $connectionSurface
        $serverConfig.Location = New-Object Drawing.Point(0,$script:loginConfigTop)
    } else {
        $serverConfig.Parent = $settings
        $serverConfig.Location = [Drawing.Point]::Empty
    }
    $script:currentPage = $Index
    for ($i = 0; $i -lt $script:pages.Count; $i++) {
        $selected = $i -eq $Index
        $script:pages[$i].Panel.Visible = $selected
        $active = $selected
        $script:navButtons[$i].BackColor = if ($active) { [Drawing.Color]::FromArgb(224,230,235) } else { $rail.BackColor }
        $script:navButtons[$i].ForeColor = if ($active) { $ink } else { $railMuted }
    }
    $heading.Text = $script:pages[$Index].Title
    $description.Text = $script:pages[$Index].Description
    $script:pageRequest = $null
    switch ($Index) {
        4 { Start-PageRequest space @{path=$(if ($script:spaceListing) { $script:spaceListing.path } else { '.' })} $spaceHint }
        5 { Start-PageRequest 'trash-list' @{} $trashHint }
        8 {
            $profileName.Text = "账号：$script:activeUser"
            if ($script:profileQuotaUser -ne $script:activeUser) {
                $profileUsage.Hide()
                $profileQuota.Text = [string]::Empty
            }
            Start-PageRequest quota @{} $profileQuota
        }
    }
}

function Add-Page($Title,$Description) {
    $page = New-Object Windows.Forms.Panel
    $page.Dock = 'Fill'
    $page.Visible = $false
    $page.BackColor = $white
    $workspace.Controls.Add($page)
    $index = $script:pages.Count
    $script:pages += @{Panel=$page; Title=$Title; Description=$Description}
    $button = Add-Button $rail ("{0:D2}    {1}" -f ($index+1),$Title) 0 (148+$index*51) $rail.Width { Select-Page ([int]$this.Tag) }
    $button.Tag = $index
    $button.Height = 42
    $button.TextAlign = 'MiddleLeft'
    $button.Padding = New-Object Windows.Forms.Padding(27,0,0,0)
    $button.FlatAppearance.BorderSize = 0
    $button.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(229,229,229)
    $script:navButtons += $button
    return $page
}

function Initialize-ExplorerFolderPicker {
    if ('BackupExplorerFolderPicker' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class BackupExplorerFolderPicker
{
    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileDialog
    {
        [PreserveSig] int Show(IntPtr owner);
        void SetFileTypes(uint count, IntPtr filters);
        void SetFileTypeIndex(uint index);
        void GetFileTypeIndex(out uint index);
        void Advise(IntPtr events, out uint cookie);
        void Unadvise(uint cookie);
        void SetOptions(uint options);
        void GetOptions(out uint options);
        void SetDefaultFolder(IntPtr folder);
        void SetFolder(IntPtr folder);
        void GetFolder(out IntPtr folder);
        void GetCurrentSelection(out IntPtr item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetFileName(out IntPtr name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
        void GetResult(out IShellItem item);
    }

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr bind, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint kind, out IntPtr name);
    }

    public static string Pick(IntPtr owner, string title)
    {
        const int Cancelled = unchecked((int)0x800704C7);
        const uint PickFolders = 0x20, ForceFileSystem = 0x40, PathMustExist = 0x800;
        const uint FileSystemPath = 0x80058000;
        var clsid = new Guid("dc1c5a9c-e88a-4dde-a5a1-60f82a20aef7");
        var dialog = (IFileDialog)Activator.CreateInstance(Type.GetTypeFromCLSID(clsid));
        IShellItem item = null;
        IntPtr name = IntPtr.Zero;
        try
        {
            uint options;
            dialog.GetOptions(out options);
            dialog.SetOptions(options | PickFolders | ForceFileSystem | PathMustExist);
            dialog.SetTitle(title);
            int result = dialog.Show(owner);
            if (result == Cancelled) return null;
            Marshal.ThrowExceptionForHR(result);
            dialog.GetResult(out item);
            item.GetDisplayName(FileSystemPath, out name);
            return Marshal.PtrToStringUni(name);
        }
        finally
        {
            if (name != IntPtr.Zero) Marshal.FreeCoTaskMem(name);
            if (item != null) Marshal.ReleaseComObject(item);
            Marshal.ReleaseComObject(dialog);
        }
    }
}
"@
}

function Add-Field($Parent, $Label, $X, $Y, $Width, $Kind = '') {
    $labelControl = New-Object Windows.Forms.Label
    $labelControl.Text = $Label
    $labelControl.ForeColor = $muted
    $labelControl.SetBounds($X,$Y,$Width,22)
    $Parent.Controls.Add($labelControl)
    $field = New-Object Windows.Forms.TextBox
    $field.AccessibleName = $Label
    $field.BorderStyle = 'FixedSingle'
    $field.ForeColor = $ink
    $field.SetBounds($X,($Y+25),$Width,27)
    if ($Kind -eq 'password') { $field.UseSystemPasswordChar = $true }
    $Parent.Controls.Add($field)
    if ($Kind -in 'folder','open','save') {
        $pick = {
            switch ($Kind) {
                'folder' { $dialog = New-Object Windows.Forms.FolderBrowserDialog }
                'open' { $dialog = New-Object Windows.Forms.OpenFileDialog }
                'save' { $dialog = New-Object Windows.Forms.SaveFileDialog; $dialog.DefaultExt = 'sbackup' }
            }
            try {
                if ($Kind -ne 'folder') { $dialog.Filter = '备份文件 (*.sbackup)|*.sbackup|所有文件 (*.*)|*.*' }
                if ($dialog.ShowDialog() -eq 'OK') {
                    $field.Text = if ($Kind -eq 'folder') { $dialog.SelectedPath } else { $dialog.FileName }
                }
            } finally { $dialog.Dispose() }
        }.GetNewClosure()
        $null = Add-Button $Parent '浏览…' ($X+$Width+12) ($Y+22) 90 $pick
    }
    return $field
}

function Show-ApiError($Record) {
    $message = $Record.Exception.Message
    if ($Record.ErrorDetails.Message) {
        try { $message = ($Record.ErrorDetails.Message | ConvertFrom-Json).error } catch {}
    }
    $script:notice = '失败：' + ($message -replace '^(失败：\s*)+', '')
    $status.Text = $script:notice
}

function Submit-BackupAction($Action, $Data) {
    $script:notice = ''
    try {
        $result = Invoke-BackupApi $Action $Data
        Update-Desktop
        return $result
    } catch { Show-ApiError $_ }
}

function Show-TransferDialog($Panel, [string]$Title) {
    if ($script:transferDialog) { return }
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.Font = $form.Font
    $dialog.AutoScaleMode = 'None'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.BackColor = $white
    $width = $workspace.ClientSize.Width
    $height = $workspace.ClientSize.Height
    $scale = $width / 800.0
    $footerHeight = [int](72 * [Math]::Min($scale,1.5))
    $dialog.ClientSize = New-Object Drawing.Size($width,($height+$footerHeight))
    $message = New-Object Windows.Forms.TextBox
    $message.Multiline = $true
    $message.ReadOnly = $true
    $message.BorderStyle = 'None'
    $message.BackColor = [Drawing.Color]::FromArgb(248,248,248)
    $message.ScrollBars = 'Vertical'
    $message.SetBounds(22,($height+5),($width-44),($footerHeight-12))
    $dialog.Controls.Add($message)
    $script:transferDialog = $dialog
    $script:transferMessage = $message
    $workspace.Controls.Remove($Panel)
    $dialog.Controls.Add($Panel)
    $Panel.Dock = 'Top'
    $Panel.Height = $height
    $Panel.Visible = $true
    try { [void]$dialog.ShowDialog($form) }
    finally {
        $Panel.Visible = $false
        $dialog.Controls.Remove($Panel)
        $workspace.Controls.Add($Panel)
        $Panel.Dock = 'Fill'
        $script:transferMessage = $null
        $script:transferDialog = $null
        $dialog.Dispose()
    }
}

$status.Add_TextChanged({
    if ($script:transferMessage) { $script:transferMessage.Text = $status.Text }
})

function New-SpaceIcons {
    $icons = New-Object Windows.Forms.ImageList
    $icons.ColorDepth = 'Depth32Bit'
    $dpiProbe = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    try { $pixels = [int][Math]::Round(20 * $dpiProbe.DpiX / 96) }
    finally { $dpiProbe.Dispose() }
    $icons.ImageSize = New-Object Drawing.Size($pixels,$pixels)
    $folderIcon = New-Object Drawing.Bitmap($pixels,$pixels)
    $archiveIcon = New-Object Drawing.Bitmap($pixels,$pixels)
    $folderDrawing = [Drawing.Graphics]::FromImage($folderIcon)
    $archiveDrawing = [Drawing.Graphics]::FromImage($archiveIcon)
    $gold = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(224,151,41))
    $amber = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255,193,76))
    $blue = New-Object Drawing.SolidBrush($accent)
    try {
        $factor = [single]($pixels / 20.0)
        $folderDrawing.ScaleTransform($factor,$factor)
        $archiveDrawing.ScaleTransform($factor,$factor)
        $folderDrawing.FillRectangle($gold,1,4,8,5)
        $folderDrawing.FillRectangle($amber,1,7,18,10)
        $archiveDrawing.FillRectangle($blue,3,2,14,16)
        $archiveDrawing.FillRectangle([Drawing.Brushes]::White,9,3,2,9)
        $archiveDrawing.FillRectangle([Drawing.Brushes]::White,8,12,4,3)
        $icons.Images.Add('folder',$folderIcon)
        $icons.Images.Add('archive',$archiveIcon)
    } finally {
        $folderDrawing.Dispose(); $archiveDrawing.Dispose()
        $gold.Dispose(); $amber.Dispose(); $blue.Dispose()
    }
    return @{Images=$icons; Folder=$folderIcon; Archive=$archiveIcon}
}

function Format-BackupSpaceLocation([string]$Path) {
    $root = $script:spaceRoot.TrimEnd('/')
    $relative = if ($Path -eq $root) { '' } else { $Path.Substring($root.Length + 1) }
    if ($relative) { '备份空间 / ' + ($relative -replace '/', ' / ') } else { '备份空间' }
}

function Set-BackupSpaceLocation($Field, [string]$Path) {
    $Field.Tag = $Path
    $Field.Text = Format-BackupSpaceLocation $Path
}

function Show-NewFolderDialog($Owner, [string]$Path) {
    $window = New-Object Windows.Forms.Form
    $window.Text = '新建文件夹'
    $window.ClientSize = New-Object Drawing.Size(478,238)
    $window.StartPosition = 'CenterParent'
    $window.FormBorderStyle = 'FixedDialog'
    $window.ShowInTaskbar = $false
    $window.MinimizeBox = $false
    $window.MaximizeBox = $false
    $window.AutoScaleMode = 'None'
    $window.Font = $form.Font
    $window.BackColor = $white
    $stripe = New-Object Windows.Forms.Panel
    $stripe.SetBounds(0,0,478,5)
    $stripe.BackColor = $accent
    $window.Controls.Add($stripe)
    $null = Add-Caption $window '新建文件夹' 24 24 430 35 17 $ink -Bold
    $location = Add-Caption $window (Format-BackupSpaceLocation $Path) 25 65 428 25 10 $muted
    $location.AutoEllipsis = $true
    $folderName = Add-Field $window '文件夹名称' 24 105 430
    $folderName.MaxLength = 200
    $folderMessage = Add-Caption $window '' 24 158 430 24 9 ([Drawing.Color]::Firebrick)
    $cancel = Add-Button $window '取消' 260 187 88 { $window.DialogResult = 'Cancel' }
    $confirm = Add-Button $window '创建' 360 187 94 {
        $name = $folderName.Text.Trim()
        if (!$name -or $name.StartsWith('.') -or $name -match '[\\/:*?"<>|]' -or
            [Text.Encoding]::UTF8.GetByteCount($name) -gt 200) {
            $folderMessage.Text = '请输入有效的文件夹名称。'
            $folderName.Focus()
            return
        }
        try {
            $null = Invoke-BackupApi 'space-folder' @{path=$Path;name=$name}
            $window.DialogResult = 'OK'
        } catch {
            $folderMessage.Text = '创建失败，请检查名称是否已存在。'
            if ($_.ErrorDetails.Message) {
                try { $folderMessage.Text = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch {}
            }
        }
    } -Primary
    $window.AcceptButton = $confirm
    $window.CancelButton = $cancel
    $window.Add_Shown({ $folderName.Focus() })
    Scale-DesktopLayout $window
    try { return $window.ShowDialog($Owner) -eq 'OK' }
    finally { $window.Dispose() }
}

function Select-BackupSpace([string]$Mode, [string]$SuggestedName = '') {
    $picker = New-Object Windows.Forms.Form
    $picker.Text = "备份空间 · $serverName"
    $picker.ClientSize = New-Object Drawing.Size(740,500)
    $picker.FormBorderStyle = 'FixedDialog'
    $picker.StartPosition = 'CenterParent'
    $picker.MaximizeBox = $false
    $picker.MinimizeBox = $false
    $picker.AutoScaleMode = 'None'
    $picker.Font = $form.Font
    $picker.BackColor = $white
    $crumb = Add-Caption $picker '备份空间' 20 17 700 33 15 $ink -Bold
    $hint = Add-Caption $picker '双击文件夹进入。' 20 52 700 25 10 $muted
    $entries = New-Object Windows.Forms.ListView
    $entries.SetBounds(20,115,700,268)
    $entries.View = 'Details'
    $iconSet = New-SpaceIcons
    $icons = $iconSet.Images
    $entries.SmallImageList = $icons
    $entries.FullRowSelect = $true
    $entries.MultiSelect = $true
    $entries.LabelEdit = $true
    $entries.HideSelection = $false
    $null = $entries.Columns.Add('名称',355)
    $null = $entries.Columns.Add('大小',105)
    $null = $entries.Columns.Add('修改时间',205)
    $picker.Controls.Add($entries)
    $selection = @{current=$null; value=''}
    $refreshSpace = {
        param($Path)
        try {
            $listing = Invoke-BackupApi space @{path=$Path}
            $selection.current = $listing
            $relative = $listing.path.Substring($listing.root.Length).TrimStart('/')
            $crumb.Text = if ($relative) { '备份空间 / ' + $relative } else { '备份空间' }
            $hint.Text = if ($listing.entries.Count) { '双击文件夹进入。' } else { '这个文件夹是空的。' }
            $entries.BeginUpdate()
            try {
                $entries.Items.Clear()
                foreach ($entry in $listing.entries) {
                    $item = New-Object Windows.Forms.ListViewItem($entry.name)
                    $item.ImageKey = if ($entry.folder) { 'folder' } else { 'archive' }
                    $item.Tag = $entry
                    $size = if ($entry.folder) { '文件夹' } else { '{0:N1} KB' -f ($entry.bytes / 1024) }
                    $null = $item.SubItems.Add($size)
                    $date = [DateTimeOffset]::FromUnixTimeSeconds([long]$entry.modified).LocalDateTime
                    $null = $item.SubItems.Add($date.ToString('yyyy-MM-dd HH:mm'))
                    $null = $entries.Items.Add($item)
                }
            } finally { $entries.EndUpdate() }
        } catch { $hint.Text = '无法读取备份空间：' + $_.Exception.Message }
    }
    $null = Add-Button $picker '上一级' 20 79 100 {
        if ($selection.current.parent) { & $refreshSpace $selection.current.parent }
    }
    $refreshButton = Add-Button $picker '刷新' 132 79 80 {
        & $refreshSpace $(if ($selection.current) { $selection.current.path } else { '.' })
    }
    $newFolderButton = Add-Button $picker '新建文件夹' 224 79 115 {
        if (!$selection.current) { return }
        if (Show-NewFolderDialog $picker $selection.current.path) {
            & $refreshSpace $selection.current.path
        }
    }
    $openSelection = {
        if ($entries.SelectedItems.Count -ne 1) { return }
        $item = $entries.SelectedItems[0].Tag
        if ($item.folder) { & $refreshSpace $item.path }
        elseif ($Mode -eq 'open') { $selection.value = $item.path; $picker.DialogResult = 'OK' }
    }
    $renameSelection = {
        if ($entries.SelectedItems.Count -eq 1) { $entries.SelectedItems[0].BeginEdit() }
        else { $hint.Text = '请选择一个要重命名的项目。' }
    }
    $removeSelection = {
        if (!$selection.current -or $entries.SelectedItems.Count -eq 0) { return }
        $names = @($entries.SelectedItems | ForEach-Object { $_.Tag.name })
        $preview = ($names | Select-Object -First 8) -join "`r`n"
        if ($names.Count -gt 8) { $preview += "`r`n…另有 $($names.Count - 8) 项" }
        $answer = [Windows.Forms.MessageBox]::Show($picker,
            "将 $($names.Count) 个项目移到应用回收站？项目保留 7 天。`r`n`r`n$preview",
            '删除选中项目','YesNo','Warning','Button2')
        if ($answer -ne 'Yes') { return }
        try {
            $result = Invoke-BackupApi 'space-trash' @{path=$selection.current.path;names=$names}
            & $refreshSpace $selection.current.path
            $hint.Text = "已将 $($result.count) 个项目移到应用回收站。"
        } catch { $hint.Text = '删除失败：' + $_.Exception.Message }
    }
    $entries.Add_AfterLabelEdit({
        param($sender,$eventArgs)
        $eventArgs.CancelEdit = $true
        if ($null -eq $eventArgs.Label -or !$selection.current) { return }
        $item = $entries.Items[$eventArgs.Item]
        $entry = $item.Tag
        $name = $eventArgs.Label.Trim()
        if (!$name -or $name -ceq $entry.name) { return }
        if (!$entry.folder -and !$name.EndsWith('.sbackup',[StringComparison]::OrdinalIgnoreCase)) {
            $name += '.sbackup'
        }
        try {
            $null = Invoke-BackupApi 'space-rename' @{path=$selection.current.path;old=$entry.name;new=$name}
            $null = $picker.BeginInvoke([Action]{ & $refreshSpace $selection.current.path })
        } catch { $hint.Text = '重命名失败：' + $_.Exception.Message }
    })
    $menu = New-Object Windows.Forms.ContextMenuStrip
    $openItem = $menu.Items.Add('打开')
    $renameItem = $menu.Items.Add('重命名    F2')
    $removeItem = $menu.Items.Add('删除    Delete')
    $null = $menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $newItem = $menu.Items.Add('新建文件夹')
    $refreshItem = $menu.Items.Add('刷新')
    $openItem.Add_Click({ & $openSelection })
    $renameItem.Add_Click({ & $renameSelection })
    $removeItem.Add_Click({ & $removeSelection })
    $newItem.Add_Click({ $newFolderButton.PerformClick() })
    $refreshItem.Add_Click({ $refreshButton.PerformClick() })
    $menu.Add_Opening({
        $one = $entries.SelectedItems.Count -eq 1
        $openItem.Enabled = $one -and ($Mode -eq 'open' -or $entries.SelectedItems[0].Tag.folder)
        $renameItem.Enabled = $one
        $removeItem.Enabled = $entries.SelectedItems.Count -gt 0
        $newItem.Enabled = $null -ne $selection.current
    })
    $entries.ContextMenuStrip = $menu
    $entries.Add_MouseDown({
        param($sender,$eventArgs)
        if ($eventArgs.Button -ne 'Right') { return }
        $row = $entries.GetItemAt($eventArgs.X,$eventArgs.Y)
        if (!$row -or !$row.Selected) {
            foreach ($item in @($entries.SelectedItems)) { $item.Selected = $false }
            if ($row) { $row.Selected = $true; $row.Focused = $true }
        }
    })
    $entries.Add_DoubleClick({ & $openSelection })
    $entries.Add_KeyDown({
        param($sender,$eventArgs)
        if ($eventArgs.Control -and $eventArgs.KeyCode -eq 'A') {
            foreach ($item in $entries.Items) { $item.Selected = $true }
        } elseif ($eventArgs.KeyCode -eq 'F2') { & $renameSelection }
        elseif ($eventArgs.KeyCode -eq 'Delete') { & $removeSelection }
        elseif ($eventArgs.KeyCode -eq 'Enter') { & $openSelection }
        else { return }
        $eventArgs.SuppressKeyPress = $true
    })
    $nameField = $null
    if ($Mode -eq 'save') {
        $nameField = Add-Field $picker '归档文件名' 20 394 470
        $nameField.Text = $SuggestedName
    }
    $caption = switch ($Mode) { 'save' {'保存到此处'} 'folder' {'选择文件夹'} default {'选择归档'} }
    $confirm = Add-Button $picker $caption 558 440 162 {
        if (!$selection.current) { return }
        switch ($Mode) {
            'folder' {
                $folder = $entries.FocusedItem
                if (!$folder -or !$folder.Selected -or !$folder.Tag.folder) {
                    $folder = $entries.SelectedItems | Where-Object { $_.Tag.folder } | Select-Object -First 1
                }
                $selection.value = if ($folder) { $folder.Tag.path } else { $selection.current.path }
            }
            'open' {
                if ($entries.SelectedItems.Count -ne 1 -or $entries.SelectedItems[0].Tag.folder) {
                    $hint.Text = '请选中一个 .sbackup 归档。'; return
                }
                $selection.value = $entries.SelectedItems[0].Tag.path
            }
            'save' {
                $name = $nameField.Text.Trim()
                if (!$name -or $name.StartsWith('.') -or $name -match '[\\/:*?"<>|]') {
                    $hint.Text = '请输入有效的归档文件名。'; return
                }
                if (!$name.EndsWith('.sbackup',[StringComparison]::OrdinalIgnoreCase)) { $name += '.sbackup' }
                $selection.value = $selection.current.path + '/' + $name
            }
        }
        $picker.DialogResult = 'OK'
    } -Primary
    $picker.AcceptButton = $confirm
    Scale-DesktopLayout $picker
    $picker.Add_Shown({ & $refreshSpace '.' })
    try {
        if ($picker.ShowDialog($form) -eq 'OK') { return $selection.value }
    } finally { $picker.Dispose(); $menu.Dispose(); $icons.Dispose(); $iconSet.Folder.Dispose(); $iconSet.Archive.Dispose() }
}

$backup = Add-Page '上传' '选择源文件夹，将归档保存到当前服务器的备份空间。'
$source = Add-Field $backup '源文件夹' 22 20 630
$sourceBrowse = Add-Button $backup '浏览…' 664 42 90 {
    try {
        Initialize-ExplorerFolderPicker
        $folderPath = [BackupExplorerFolderPicker]::Pick($form.Handle,'选择要备份的源文件夹')
        if ($folderPath) { $source.Text = $folderPath }
    } catch { Show-ApiError $_ }
}
$archive = Add-Field $backup '归档保存位置 · 备份空间' 22 84 630
$archive.ReadOnly = $true
$null = Add-Button $backup '选择位置…' 664 106 100 {
    $path = Select-BackupSpace folder
    if ($path) { $archive.Tag = $path; Update-ArchivePreview }
}
$archiveName = Add-Field $backup '归档文件名' 22 148 630
function Get-ArchiveFileName {
    $name = $archiveName.Text.Trim()
    if (!$name -or $name.StartsWith('.') -or $name -match '[\\/:*?"<>|]') { return }
    if (!$name.EndsWith('.sbackup',[StringComparison]::OrdinalIgnoreCase)) { $name += '.sbackup' }
    return $name
}
function Update-ArchivePreview {
    if (!$archive.Tag) { return }
    $name = if (!$archiveName.ReadOnly) { Get-ArchiveFileName }
    $path = if ($name) { $archive.Tag + '/' + $name } else { $archive.Tag }
    $archive.Text = Format-BackupSpaceLocation $path
}
$archiveName.Add_TextChanged({ Update-ArchivePreview })
$password = Add-Field $backup '归档密码（选填）' 22 206 340 password
$compress = New-Object Windows.Forms.CheckBox
$compress.Text = 'Huffman 压缩'
$compress.Checked = $true
$compress.SetBounds(405,228,230,30)
$backup.Controls.Add($compress)
$filters = New-Object Windows.Forms.GroupBox
$filters.Text = '筛选条件 · 留空表示不限'
$filters.SetBounds(22,265,744,137)
$backup.Controls.Add($filters)
$filterFields = @{
    name=(Add-Field $filters '文件名' 12 18 165)
    path=(Add-Field $filters '相对路径' 195 18 165)
    extensions=(Add-Field $filters '扩展名' 378 18 165)
    'min-size'=(Add-Field $filters '最小字节数' 560 18 165)
    'max-size'=(Add-Field $filters '最大字节数' 12 73 165)
    after=(Add-Field $filters '起始日期 YYYY-MM-DD' 195 73 165)
    before=(Add-Field $filters '结束日期 YYYY-MM-DD' 378 73 165)
}
$submitButtons.Add((Add-Button $backup '开始上传' 22 414 135 {
    $name = Get-ArchiveFileName
    $dropped = $script:droppedUploadPaths
    if ((!$name -and $dropped.Count -le 1) -or !$archive.Tag) {
        $script:notice = '请选择保存位置，并填写有效的归档文件名。'
        $status.Text = $script:notice
        $signInMessage.Text = $script:notice
        $errorLabel.Text = $script:notice
        return
    }
    $archivePath = $archive.Tag + '/' + $name
    $data = @{source=$source.Text; archive=$archivePath
              password=$password.Text; compression=$compress.Checked}
    foreach ($key in $filterFields.Keys) { $data[$key] = $filterFields[$key].Text }
    $accepted = if ($dropped.Count) {
        Submit-BackupAction 'drop-upload' @{paths=$dropped;directory=$archive.Tag;options=$data;
            archive_name=$(if ($dropped.Count -eq 1) { $name } else { $null })}
    } else { Submit-BackupAction backup $data }
    if ($accepted) {
        $script:refreshAfterDrop = $true
        if ($dropped.Count -le 1) { Set-RestoreArchive $archivePath }
        $password.Clear()
        if ($script:transferDialog) { $script:transferDialog.Close() }
    }
} -Primary))

$restore = Add-Page '下载' '从服务器取回备份内容，并解包到指定的本地文件夹。'
$restoreArchive = Add-Field $restore '备份归档' 22 20 630
$restoreArchive.ReadOnly = $true
function Set-RestoreArchive([string]$Path, [string]$Version = '', [string]$Name = '') {
    $restoreArchive.Tag = @{path=$Path;version=$Version}
    $restoreArchive.Text = if ($Version) { '远端版本 / ' + $Name } else { Format-BackupSpaceLocation $Path }
}
$null = Add-Button $restore '备份空间…' 664 42 100 {
    $path = Select-BackupSpace open
    if ($path) { Set-RestoreArchive $path }
}
$destination = Add-Field $restore '还原位置（已有文件夹）' 22 84 630
$destination.ReadOnly = $true
$destinationTooltip = New-Object Windows.Forms.ToolTip
$form.Add_FormClosed({ $destinationTooltip.Dispose() })
function Set-RestoreDestination([string]$Path) {
    if (![IO.Path]::IsPathRooted($Path)) { throw '请选择 Windows 中已有的文件夹。' }
    $destination.Tag = $Path
    $destination.Text = $Path
    $destinationTooltip.SetToolTip($destination,$Path)
}
$null = Add-Button $restore '浏览…' 664 106 90 {
    try {
        Initialize-ExplorerFolderPicker
        $path = [BackupExplorerFolderPicker]::Pick($form.Handle,'选择还原目标文件夹')
        if ($path) { Set-RestoreDestination $path }
    } catch { Show-ApiError $_ }
}
$restorePassword = Add-Field $restore '归档密码（加密归档需要）' 22 148 340 password
$submitButtons.Add((Add-Button $restore '下载' 22 221 135 {
    $data = @{destination=$destination.Tag; password=$restorePassword.Text}
    $action = if ($restoreArchive.Tag.version) { $data.version = $restoreArchive.Tag.version; 'download' }
        else { $data.archive = $restoreArchive.Tag.path; 'restore' }
    if (Submit-BackupAction $action $data) {
        $restorePassword.Clear()
        if ($script:transferDialog) { $script:transferDialog.Close() }
    }
} -Primary))
$submitButtons.Add((Add-Button $restore '仅检查备份' 170 221 135 {
    $data = @{password=$restorePassword.Text}
    $action = if ($restoreArchive.Tag.version) { $data.version = $restoreArchive.Tag.version; 'remote-inspect' }
        else { $data.archive = $restoreArchive.Tag.path; 'inspect' }
    if (Submit-BackupAction $action $data) {
        $restorePassword.Clear()
        if ($script:transferDialog) { $script:transferDialog.Close() }
    }
}))

$auto = Add-Page '自动备份' '安排周期备份，或在文件变化后自动保存一个版本。'
$autoSource = Add-Field $auto '源文件夹' 22 20 630 folder
$autoOutput = Add-Field $auto '备份保存目录 · 备份空间' 22 84 630
$autoOutput.ReadOnly = $true
$null = Add-Button $auto '选择目录…' 664 106 100 {
    $path = Select-BackupSpace folder
    if ($path) { Set-BackupSpaceLocation $autoOutput $path }
}
$modeLabel = New-Object Windows.Forms.Label
$modeLabel.Text = '触发方式'
$modeLabel.SetBounds(22,148,180,22)
$auto.Controls.Add($modeLabel)
$mode = New-Object Windows.Forms.ComboBox
$mode.DropDownStyle = 'DropDownList'
$mode.SetBounds(22,173,180,27)
$mode.Items.AddRange(@('定时备份','文件变化自动备份'))
$mode.SelectedIndex = 0
$auto.Controls.Add($mode)
$period = Add-Field $auto '周期 / 稳定等待（秒）' 223 148 205
$period.Text = '60'
$keep = Add-Field $auto '保留份数' 450 148 95
$keep.Text = '3'
$null = Add-Button $auto '添加任务' 565 170 100 {
    $trigger = if ($mode.SelectedIndex -eq 0) { 'schedule' } else { 'watch' }
    $null = Submit-BackupAction job @{mode=$trigger; source=$autoSource.Text
        output=$autoOutput.Tag; period=$period.Text; keep=$keep.Text}
} -Primary
$jobList = New-Object Windows.Forms.ListBox
$jobList.HorizontalScrollbar = $true
$jobList.SetBounds(22,216,744,172)
$auto.Controls.Add($jobList)
$null = Add-Button $auto '移除选中任务' 22 400 135 {
    if ($jobList.SelectedIndex -ge 0) {
        $null = Submit-BackupAction remove @{id=$script:jobs[$jobList.SelectedIndex].id}
    }
}

$settings = Add-Page '设置' '输入服务器地址并连接。连接成功后会保存该地址。'
$serverConfig = New-Object Windows.Forms.Panel
$serverConfig.SetBounds(0,0,760,152)
$serverConfig.BackColor = $white
$settings.Controls.Add($serverConfig)
$serverAddress = Add-Field $serverConfig '服务器地址' 22 20 630
$serverAddress.Text = $savedAddress
$script:addressHistory = @()
$script:hiddenAddresses = @()
if (Test-Path -LiteralPath $addressHistoryFile -PathType Leaf) {
    try {
        $addressData = Get-Content -LiteralPath $addressHistoryFile -Raw | ConvertFrom-Json
        $script:addressHistory = @($addressData.recent | Where-Object { $_ -is [string] -and $_ })
        $script:hiddenAddresses = @($addressData.hidden | Where-Object { $_ -is [string] -and $_ })
    } catch {}
}

function Save-AddressHistory {
    $history = @{recent=@($script:addressHistory);hidden=@($script:hiddenAddresses)}
    [IO.File]::WriteAllText($addressHistoryFile,($history | ConvertTo-Json -Compress),[Text.Encoding]::UTF8)
}

$addressSuggestions = New-Object Windows.Forms.ToolStripDropDown
$addressSuggestions.AutoSize = $true
$addressSuggestions.Padding = New-Object Windows.Forms.Padding(1)
$form.Add_FormClosed({ $addressSuggestions.Dispose() })

function Show-AddressSuggestions {
    if ($addressSuggestions.Visible) { return }
    $addresses = @(@($script:addressHistory) + @($cloudAddress,$wslAddress) |
        Where-Object { $_ -notin $script:hiddenAddresses } | Select-Object -Unique -First 10)
    if (!$addresses.Count) { return }
    foreach ($old in @($addressSuggestions.Items)) { $old.Dispose() }
    $addressSuggestions.Items.Clear()
    $rowHeight = [Math]::Max(31,$serverAddress.Height + 10)
    $list = New-Object Windows.Forms.Panel
    $list.BackColor = $white
    $list.Size = New-Object Drawing.Size($serverAddress.Width,($addresses.Count * $rowHeight))
    foreach ($address in $addresses) {
        $y = $list.Controls.Count / 2 * $rowHeight
        $choose = New-Object Windows.Forms.Button
        $choose.Text = $address
        $choose.Tag = $address
        $choose.Font = $form.Font
        $choose.TextAlign = 'MiddleLeft'
        $choose.FlatStyle = 'Flat'
        $choose.FlatAppearance.BorderSize = 0
        $choose.SetBounds(0,$y,($list.Width-$rowHeight),$rowHeight)
        $choose.Add_Click({
            $serverAddress.Text = [string]$this.Tag
            $addressSuggestions.Close()
            $serverAddress.SelectionStart = $serverAddress.TextLength
        })
        $removeAddress = New-Object Windows.Forms.Button
        $removeAddress.Text = '×'
        $removeAddress.Tag = $address
        $removeAddress.AccessibleName = '移除地址建议 ' + $address
        $removeAddress.Font = $form.Font
        $removeAddress.FlatStyle = 'Flat'
        $removeAddress.FlatAppearance.BorderSize = 0
        $removeAddress.SetBounds(($list.Width-$rowHeight),$y,$rowHeight,$rowHeight)
        $removeAddress.Add_Click({
            $address = [string]$this.Tag
            $script:addressHistory = @($script:addressHistory | Where-Object { $_ -ne $address })
            $script:hiddenAddresses = @($script:hiddenAddresses + $address | Select-Object -Unique)
            Save-AddressHistory
            $addressSuggestions.Close()
            Show-AddressSuggestions
        })
        $list.Controls.Add($choose)
        $list.Controls.Add($removeAddress)
    }
    $hostItem = New-Object Windows.Forms.ToolStripControlHost($list)
    $hostItem.AutoSize = $false
    $hostItem.Size = $list.Size
    $hostItem.Margin = New-Object Windows.Forms.Padding(0)
    $null = $addressSuggestions.Items.Add($hostItem)
    $addressSuggestions.Show($serverAddress,(New-Object Drawing.Point(0,$serverAddress.Height)))
}

$serverAddress.Add_MouseDown({ Show-AddressSuggestions })
$serverAddress.Add_KeyDown({
    param($sender,$eventArgs)
    if ($eventArgs.KeyCode -eq 'Down') { Show-AddressSuggestions; $eventArgs.SuppressKeyPress = $true }
})
$accountShortcut = Add-Button $statusCard '登录 / 注册' 665 10 115 {
    if ($script:authenticated) { Select-Page 8 } else { Select-Page 6 }
}
$accountShortcut.Anchor = 'Top,Right'
$serverExample = Add-Caption $serverConfig '腾讯云：ssh://TencentCloud    本地 WSL：https://127.0.0.1:19444' 22 86 730 28 10 $muted
$guestConnection = Add-Caption $serverConfig '' 180 124 570 26 10 $muted
$connectSaveButton = Add-Button $serverConfig '连接并保存' 22 121 145 {
    $address = $serverAddress.Text.Trim().TrimEnd('/')
    if ($address -eq 'TencentCloud') { $address = $cloudAddress }
    if ($address -notin $cloudAddress,$wslAddress) {
        $script:notice = '请输入腾讯云或本地 WSL 的服务器地址。'
        $status.Text = $script:notice
        return
    }
    $script:pendingAddress = $address
    $script:localTarget = $address -eq $wslAddress
    $script:serverName = if ($script:localTarget) { 'WSL' } else { '腾讯云' }
    $script:baseUrl = if ($script:localTarget) { 'http://127.0.0.1:18766' } else { 'http://127.0.0.1:18765' }
    $script:initialized = $false
    $script:authenticated = $false
    $script:activeUser = ''
    $script:starting = $false
    $script:notice = ''
    $script:spaceListing = $null
    $script:refreshAfterDrop = $false
    $spaceEntries.Items.Clear()
    $restoreArchive.Clear()
    $restoreArchive.Tag = $null
    $archive.Clear()
    $archive.Tag = $null
    $autoOutput.Clear()
    $autoOutput.Tag = $null
    $jobList.Items.Clear()
    $script:jobCache = ''
    $form.Text = '文件备份助手'
    Select-Page 6
    Update-Desktop
} -Primary

$spacePage = Add-Page '备份空间' '浏览远端服务器里的备份文件，选中归档后即可还原。'
$spaceCrumb = Add-Caption $spacePage '备份空间' 22 20 744 30 14 $ink -Bold
$spaceHint = Add-Caption $spacePage '可将文件或文件夹拖到这里上传。双击打开，右键下载或管理。' 22 52 744 24 10 $muted
$spaceEntries = New-Object Windows.Forms.ListView
$spaceEntries.SetBounds(22,121,744,270)
$spaceEntries.View = 'Details'
$spaceEntries.FullRowSelect = $true
$spaceEntries.MultiSelect = $true
$spaceEntries.LabelEdit = $true
$spaceEntries.HideSelection = $false
$spaceIcons = New-SpaceIcons
$spaceEntries.SmallImageList = $spaceIcons.Images
$null = $spaceEntries.Columns.Add('名称',380)
$null = $spaceEntries.Columns.Add('大小',110)
$null = $spaceEntries.Columns.Add('修改时间',210)
$spacePage.Controls.Add($spaceEntries)
$script:spaceListing = $null

function Update-SpacePage([string]$Path = '.', $Listing = $null) {
    if (!$script:authenticated) {
        $spaceHint.Text = '请在设置中登录，或注册一个新账号。'
        return
    }
    try {
        if ($null -eq $Listing) {
            if ($script:pageRequest.Action -eq 'space') { $script:pageRequest = $null }
            $Listing = Invoke-BackupApi space @{path=$Path}
        }
        $script:spaceListing = $listing
        $relative = $listing.path.Substring($listing.root.Length).TrimStart('/')
        $spaceCrumb.Text = if ($relative) { '备份空间 / ' + $relative } else { '备份空间' }
        $spaceHint.Text = '可将文件或文件夹拖到这里上传。双击打开，右键下载或管理。'
        $spaceEntries.BeginUpdate()
        try {
            $spaceEntries.Items.Clear()
            foreach ($entry in $listing.entries) {
                $item = New-Object Windows.Forms.ListViewItem($entry.name)
                $item.ImageKey = if ($entry.folder) { 'folder' } else { 'archive' }
                $item.Tag = $entry
                $size = if ($entry.folder) { '文件夹' } else { '{0:N1} KB' -f ($entry.bytes / 1024) }
                $null = $item.SubItems.Add($size)
                $date = [DateTimeOffset]::FromUnixTimeSeconds([long]$entry.modified).LocalDateTime
                $null = $item.SubItems.Add($date.ToString('yyyy-MM-dd HH:mm'))
                $null = $spaceEntries.Items.Add($item)
            }
        } finally { $spaceEntries.EndUpdate() }
    } catch { $spaceHint.Text = '无法读取备份空间：' + $_.Exception.Message }
}

function Open-SpaceSelection {
    if ($spaceEntries.SelectedItems.Count -ne 1) { $spaceHint.Text = '打开时请选择一个项目。'; return }
    $entry = $spaceEntries.SelectedItems[0].Tag
    if ($entry.folder) { Update-SpacePage $entry.path; return }
    Set-RestoreArchive $entry.path
    Show-TransferDialog $restore '下载'
}

function Remove-SpaceSelection {

    if (!$script:spaceListing -or $spaceEntries.SelectedItems.Count -eq 0) {
        $spaceHint.Text = '请先选中要删除的项目。'
        return
    }
    $names = @($spaceEntries.SelectedItems | ForEach-Object { $_.Tag.name })
    $preview = ($names | Select-Object -First 8) -join "`r`n"
    if ($names.Count -gt 8) { $preview += "`r`n…另有 $($names.Count - 8) 项" }
    $prompt = "将 $($names.Count) 个项目移到应用回收站？保留满 7 天后会自动彻底删除。选中的文件夹会连同内容一起移走。`r`n`r`n$preview"
    $answer = [Windows.Forms.MessageBox]::Show($form,$prompt,'删除选中项目',
        [Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning,
        [Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($answer -ne 'Yes') { return }
    try {
        $result = Invoke-BackupApi 'space-trash' @{path=$script:spaceListing.path;names=$names}
        Update-SpacePage $script:spaceListing.path
        $spaceHint.Text = "已将 $($result.count) 个项目移到应用回收站，将保留 7 天。"
        $script:notice = "已移动 $($result.count) 个项目。`r`n回收站位置：$($result.trash)"
        $status.Text = $script:notice
    } catch { Show-ApiError $_ }
}

function Rename-SpaceSelection {
    if ($spaceEntries.SelectedItems.Count -ne 1) {
        $spaceHint.Text = '请选择一个要重命名的文件或文件夹。'; return
    }
    $spaceEntries.SelectedItems[0].BeginEdit()
}

$spaceEntries.Add_AfterLabelEdit({
    param($sender,$eventArgs)
    $eventArgs.CancelEdit = $true
    if ($null -eq $eventArgs.Label) { return }
    $entry = $spaceEntries.Items[$eventArgs.Item].Tag
    $name = $eventArgs.Label.Trim()
    if (!$name -or $name -ceq $entry.name) { return }
    if (!$entry.folder -and !$name.EndsWith('.sbackup',[StringComparison]::OrdinalIgnoreCase)) {
        $name += '.sbackup'
    }
    try {
        $null = Invoke-BackupApi 'space-rename' @{path=$script:spaceListing.path;old=$entry.name;new=$name}
        $null = $form.BeginInvoke([Action]{ Update-SpacePage $script:spaceListing.path })
    } catch { Show-ApiError $_ }
})

$null = Add-Button $spacePage '上一级' 22 82 100 {
    if ($script:spaceListing.parent) { Update-SpacePage $script:spaceListing.parent }
}
$refreshSpaceButton = Add-Button $spacePage '刷新' 134 82 80 {
    Update-SpacePage $(if ($script:spaceListing) { $script:spaceListing.path } else { '.' })
}
$newFolderButton = Add-Button $spacePage '新建文件夹' 226 82 115 {
    if (!$script:spaceListing) { return }
    if (Show-NewFolderDialog $form $script:spaceListing.path) {
        Update-SpacePage $script:spaceListing.path
    }
}
$null = Add-Button $spacePage '上传' 353 82 100 {
    if (!$script:authenticated) { Select-Page 3; return }
    Show-TransferDialog $backup '上传'
} -Primary
$null = Add-Button $spacePage '下载' 465 82 100 {
    if (!$script:authenticated) { Select-Page 3; return }
    if ($spaceEntries.SelectedItems.Count -eq 1 -and !$spaceEntries.SelectedItems[0].Tag.folder) {
        Set-RestoreArchive $spaceEntries.SelectedItems[0].Tag.path
    }
    Show-TransferDialog $restore '下载'
}

$trashPage = Add-Page '回收站' '恢复误删项目，或彻底删除无需保留的备份。'
$trashHint = Add-Caption $trashPage '项目保留 7 天，可恢复到原位置。' 22 22 700 25 10 $muted
$trashList = New-Object Windows.Forms.ListView
$trashList.SetBounds(22,58,744,342)
$trashList.View = 'Details'
$trashList.FullRowSelect = $true
$trashList.MultiSelect = $true
$trashList.HideSelection = $false
$trashIcons = New-SpaceIcons
$trashList.SmallImageList = $trashIcons.Images
$null = $trashList.Columns.Add('名称',265)
$null = $trashList.Columns.Add('原位置',245)
$null = $trashList.Columns.Add('删除时间',170)
$trashPage.Controls.Add($trashList)
$reloadTrash = {
    param($LoadedItems)
    try {
        if ($null -eq $LoadedItems -and $script:pageRequest.Action -eq 'trash-list') { $script:pageRequest = $null }
        $items = if ($null -eq $LoadedItems) { @((Invoke-BackupApi 'trash-list' @{}) | ForEach-Object { $_ }) } else { $LoadedItems }
        $trashList.Items.Clear()
        foreach ($entry in $items) {
            $row = New-Object Windows.Forms.ListViewItem($entry.name)
            $row.Tag = $entry
            $row.ImageKey = if ($entry.folder) { 'folder' } else { 'archive' }
            $origin = if ($entry.origin -eq '.') { '备份空间' } else { '备份空间 / ' + ($entry.origin -replace '/', ' / ') }
            $null = $row.SubItems.Add($origin)
            $date = [DateTimeOffset]::FromUnixTimeSeconds([long]$entry.deleted).LocalDateTime
            $null = $row.SubItems.Add($date.ToString('yyyy-MM-dd HH:mm'))
            $null = $trashList.Items.Add($row)
        }
        $trashHint.Text = if ($items.Count) { "共 $($items.Count) 项。可从空白处拖框多选，右键恢复或删除。" } else { '回收站为空。' }
    } catch { $trashHint.Text = '无法读取回收站：' + $_.Exception.Message }
}
$restoreTrashSelection = {
    if ($trashList.SelectedItems.Count -eq 0) { $trashHint.Text = '请选中要恢复的项目。'; return }
    $selected = @($trashList.SelectedItems | ForEach-Object { $_.Tag })
    $restored = 0
    $errors = @()
    foreach ($entry in $selected) {
        try {
            $null = Invoke-BackupApi 'trash-restore' @{batch=$entry.batch;name=$entry.name}
            $restored++
        } catch { $errors += $entry.name + '：' + $_.Exception.Message }
    }
    & $reloadTrash
    $trashHint.Text = "已恢复 $restored 项，失败 $($errors.Count) 项。"
    if ($errors.Count) {
        [void][Windows.Forms.MessageBox]::Show($form,($errors -join [Environment]::NewLine),'恢复结果')
    }
}
$deleteTrashSelection = {
    $items = @($trashList.SelectedItems | ForEach-Object { @{batch=$_.Tag.batch;name=$_.Tag.name} })
    if (!$items.Count) { return }
    $answer = [Windows.Forms.MessageBox]::Show($form,
        "确定彻底删除选中的 $($items.Count) 项？此操作无法恢复。",'删除回收站项目','YesNo','Warning','Button2')
    if ($answer -ne 'Yes') { return }
    try {
        $result = Invoke-BackupApi 'trash-delete' @{items=$items}
        & $reloadTrash
        $trashHint.Text = "已彻底删除 $($result.count) 项。"
    } catch { $trashHint.Text = '删除失败：' + $_.Exception.Message }
}
$trashMenu = New-Object Windows.Forms.ContextMenuStrip
$restoreItem = $trashMenu.Items.Add('恢复')
$deleteItem = $trashMenu.Items.Add('删除')
$restoreItem.Add_Click({ & $restoreTrashSelection })
$deleteItem.Add_Click({ & $deleteTrashSelection })
$trashMenu.Add_Opening({ param($sender,$eventArgs); $eventArgs.Cancel = $trashList.SelectedItems.Count -eq 0 })
$trashList.ContextMenuStrip = $trashMenu
$trashList.Add_MouseDown({
    param($sender,$eventArgs)
    if ($eventArgs.Button -ne 'Right') { return }
    $row = $trashList.GetItemAt($eventArgs.X,$eventArgs.Y)
    if (!$row -or !$row.Selected) {
        foreach ($item in @($trashList.SelectedItems)) { $item.Selected = $false }
        if ($row) { $row.Selected = $true; $row.Focused = $true }
    }
})
$null = Add-Button $trashPage '恢复选中项' 20 422 140 { & $restoreTrashSelection } -Primary
$null = Add-Button $trashPage '清空回收站' 173 422 140 {
    if ($trashList.Items.Count -eq 0) { return }
    $confirm = [Windows.Forms.MessageBox]::Show($form,
        '确定彻底删除回收站里的所有项目？此操作无法恢复。','清空回收站','YesNo','Warning','Button2')
    if ($confirm -ne 'Yes') { return }
    try {
        $result = Invoke-BackupApi 'trash-empty' @{}
        & $reloadTrash
        $trashHint.Text = "已彻底删除 $($result.count) 项。"
    } catch { $trashHint.Text = '清空失败：' + $_.Exception.Message }
}
$null = Add-Button $trashPage '刷新' 326 422 90 { & $reloadTrash }
$form.Add_FormClosed({
    $trashMenu.Dispose()
    $trashIcons.Images.Dispose()
    $trashIcons.Folder.Dispose()
    $trashIcons.Archive.Dispose()
})
$null = Add-Button $spacePage '打开选中项'  22 405 140 { Open-SpaceSelection } -Primary
$null = Add-Button $spacePage '删除选中项' 174 405 140 { Remove-SpaceSelection }
$null = Add-Button $spacePage '重命名' 326 405 105 { Rename-SpaceSelection }
$spaceMenu = New-Object Windows.Forms.ContextMenuStrip
$downloadMenu = $spaceMenu.Items.Add('下载')
$renameMenu = $spaceMenu.Items.Add('重命名    F2')
$removeMenu = $spaceMenu.Items.Add('删除    Delete')
$null = $spaceMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$newFolderMenu = $spaceMenu.Items.Add('新建文件夹')
$refreshMenu = $spaceMenu.Items.Add('刷新')
$downloadMenu.Add_Click({
    if ($spaceEntries.SelectedItems.Count -eq 1 -and !$spaceEntries.SelectedItems[0].Tag.folder) { Open-SpaceSelection }
})
$renameMenu.Add_Click({ Rename-SpaceSelection })
$removeMenu.Add_Click({ Remove-SpaceSelection })
$newFolderMenu.Add_Click({ $newFolderButton.PerformClick() })
$refreshMenu.Add_Click({ $refreshSpaceButton.PerformClick() })
$spaceMenu.Add_Opening({
    $one = $spaceEntries.SelectedItems.Count -eq 1
    $downloadMenu.Visible = $one -and !$spaceEntries.SelectedItems[0].Tag.folder
    $renameMenu.Enabled = $one
    $removeMenu.Enabled = $spaceEntries.SelectedItems.Count -gt 0
    $newFolderMenu.Enabled = $null -ne $script:spaceListing
})
$spaceEntries.ContextMenuStrip = $spaceMenu
$spaceDropEnter = {
    param($sender,$eventArgs)
    if ($script:spaceListing -and $eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $eventArgs.Effect = [Windows.Forms.DragDropEffects]::Copy
    }
}
$spaceDropUpload = {
    param($sender,$eventArgs)
    if (!$script:spaceListing -or !$eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { return }
    $paths = @($eventArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop))
    if (!$paths.Count -or $script:transferDialog) { return }
    $script:pendingDropPaths = $paths
    $script:pendingDropDirectory = $script:spaceListing.path
    $null = $form.BeginInvoke([Action]{
        if ($script:transferDialog -or !$script:pendingDropPaths) { return }
        $oldSource = $source.Text
        $oldFolder = $archive.Tag
        $oldName = $archiveName.Text
        $script:droppedUploadPaths = @($script:pendingDropPaths)
        $script:pendingDropPaths = $null
        $source.Text = if ($script:droppedUploadPaths.Count -eq 1) { $script:droppedUploadPaths[0] }
            else { "$($script:droppedUploadPaths.Count) 个拖入项目 · " + (($script:droppedUploadPaths | ForEach-Object { Split-Path $_ -Leaf }) -join '、') }
        $source.ReadOnly = $true
        $sourceBrowse.Enabled = $false
        $archive.Tag = $script:pendingDropDirectory
        $archiveName.ReadOnly = $script:droppedUploadPaths.Count -gt 1
        $archiveName.Text = if ($archiveName.ReadOnly) { '每项自动命名' }
            else { (Split-Path $script:droppedUploadPaths[0] -Leaf) + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
        Update-ArchivePreview
        try { Show-TransferDialog $backup '上传' }
        finally {
            $script:droppedUploadPaths = $null
            $source.ReadOnly = $false
            $sourceBrowse.Enabled = $true
            $source.Text = $oldSource
            $archive.Tag = $oldFolder
            $archiveName.ReadOnly = $false
            $archiveName.Text = $oldName
            Update-ArchivePreview
        }
    })
}
foreach ($dropTarget in @($spacePage,$spaceEntries)) {
    $dropTarget.AllowDrop = $true
    $dropTarget.Add_DragEnter($spaceDropEnter)
    $dropTarget.Add_DragDrop($spaceDropUpload)
}
$spaceEntries.Add_MouseDown({
    param($sender,$eventArgs)
    if ($eventArgs.Button -ne 'Right') { return }
    $row = $spaceEntries.GetItemAt($eventArgs.X,$eventArgs.Y)
    if (!$row -or !$row.Selected) {
        foreach ($item in @($spaceEntries.SelectedItems)) { $item.Selected = $false }
        if ($row) { $row.Selected = $true; $row.Focused = $true }
    }
})
$spaceEntries.Add_DoubleClick({ Open-SpaceSelection })
$spaceEntries.Add_KeyDown({
    param($sender,$eventArgs)
    if ($eventArgs.Control -and $eventArgs.KeyCode -eq 'A') {
        foreach ($item in $spaceEntries.Items) { $item.Selected = $true }
        $eventArgs.SuppressKeyPress = $true
    } elseif ($eventArgs.KeyCode -eq 'Delete') {
        Remove-SpaceSelection
        $eventArgs.SuppressKeyPress = $true
    } elseif ($eventArgs.KeyCode -eq 'Enter') {
        Open-SpaceSelection
        $eventArgs.SuppressKeyPress = $true
    } elseif ($eventArgs.KeyCode -eq 'F2') {
        Rename-SpaceSelection
        $eventArgs.SuppressKeyPress = $true
    }
})
$form.Add_FormClosed({
    $spaceMenu.Dispose()
    $spaceIcons.Images.Dispose()
    $spaceIcons.Folder.Dispose()
    $spaceIcons.Archive.Dispose()
})
$signInPage = Add-Page '登录' '登录后即可浏览该账号的备份空间。'
function Set-AuthButtonStyle($Button, [bool]$Primary) {
    $Button.FlatAppearance.BorderSize = 0
    $Button.BackColor = if ($Primary) { [Drawing.Color]::FromArgb(0,103,192) } else { [Drawing.Color]::FromArgb(239,239,239) }
    $Button.ForeColor = if ($Primary) { $white } else { [Drawing.Color]::FromArgb(48,48,48) }
    $Button.FlatAppearance.MouseOverBackColor = if ($Primary) { [Drawing.Color]::FromArgb(0,91,171) } else { [Drawing.Color]::FromArgb(228,228,228) }
    Set-FluentCorners $Button
}

$loginCard = New-Object Windows.Forms.Panel
$loginCard.SetBounds(0,0,352,316)
$loginCard.BackColor = $white
$signInPage.Controls.Add($loginCard)
$null = Add-Caption $loginCard '账号登录' 25 24 300 42 22 $ink -Bold
$signInName = Add-Field $loginCard '账号' 26 83 300
$signInSecret = Add-Field $loginCard '密码' 26 144 300 password
$signInMessage = Add-Caption $loginCard '' 26 201 300 34 10 ([Drawing.Color]::Firebrick)
$signInAction = Add-Button $loginCard '登录' 26 228 300 {
    $name = $signInName.Text.Trim()
    if (!$name -or !$signInSecret.TextLength) {
        $signInMessage.Text = '请输入账号和密码。'
        return
    }
    try {
        $null = Invoke-BackupApi login @{username=$name;password=$signInSecret.Text}
        $signInSecret.Clear()
        $signInMessage.Text = ''
        $script:notice = ''
        Update-Desktop
    } catch {
        $signInMessage.Text = '登录失败，请检查账号和密码。'
        if ($_.ErrorDetails.Message) {
            try { $signInMessage.Text = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch {}
        }
    }
} -Primary
$signInAction.Height = 42
Set-AuthButtonStyle $signInAction $true
$signInAction.BackColor = [Drawing.Color]::FromArgb(0,119,203)
$signInAction.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(0,104,183)
$connectionSurface = New-Object Windows.Forms.Panel
$connectionSurface.SetBounds(352,0,204,316)
$connectionSurface.BackColor = [Drawing.Color]::FromArgb(247,248,253)
$connectionSurface.Add_Paint({
    param($sender,$eventArgs)
    if ($sender.ClientSize.Width -lt 1 -or $sender.ClientSize.Height -lt 1) { return }
    $gradient = New-Object Drawing.Drawing2D.LinearGradientBrush(
        $sender.ClientRectangle,
        [Drawing.Color]::FromArgb(250,247,252),
        [Drawing.Color]::FromArgb(234,247,253),
        [Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal)
    try { $eventArgs.Graphics.FillRectangle($gradient,$sender.ClientRectangle) }
    finally { $gradient.Dispose() }
})
$signInPage.Controls.Add($connectionSurface)
$null = Add-Caption $connectionSurface '文件备份助手' 18 61 168 39 16 $ink -Bold
$createAccount = New-Object Windows.Forms.LinkLabel
$createAccount.Text = '创建账号'
$createAccount.SetBounds(108,25,78,24)
$createAccount.TextAlign = 'MiddleRight'
$createAccount.LinkColor = $ink
$createAccount.ActiveLinkColor = $ink
$createAccount.LinkBehavior = 'HoverUnderline'
$createAccount.Add_LinkClicked({ Show-RegistrationWindow })
$connectionSurface.Controls.Add($createAccount)
$registrationPage = Add-Page '注册' '创建账号后即可登录备份空间。'
    $null = Add-Caption $registrationPage '创建备份账号' 24 17 270 42 19 $ink -Bold
    $usernameField = Add-Field $registrationPage '账号（字母、数字、下划线或连字符）' 24 65 300
    $passwordField = Add-Field $registrationPage '密码（至少 8 个字符）' 24 123 300 password
    $errorLabel = Add-Caption $registrationPage '' 24 300 300 30 10 ([Drawing.Color]::Firebrick)
        $beforeEmailControls = $registrationPage.Controls.Count
        $emailField = Add-Field $registrationPage '接收验证码的邮箱' 24 181 300
        $codeField = Add-Field $registrationPage '邮箱验证码' 24 239 165
        $codeField.MaxLength = 6
        $verificationButton = Add-Button $registrationPage '获取验证码' 200 262 124 {
            $sender = $this
            $sender.Enabled = $false
            try {
                $errorLabel.Text = '正在发送验证码…'
                $errorLabel.Refresh()
                $null = Invoke-BackupApi 'email-code' @{username=$usernameField.Text.Trim();email=$emailField.Text.Trim()}
                $errorLabel.Text = '验证码已发送，5 分钟内有效。'
            } catch {
                $errorLabel.Text = '验证码发送失败。'
                if ($_.ErrorDetails.Message) {
                    try { $errorLabel.Text = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch {}
                }
            } finally { $sender.Enabled = $true }
        }
    foreach ($control in @($registrationPage.Controls | Select-Object -Skip $beforeEmailControls)) { $control.Tag = 'email-verification' }
    $cancel = Add-Button $registrationPage '返回登录' 24 334 135 { $script:registrationWindow.Close() }
    $confirm = Add-Button $registrationPage '注册' 174 334 150 {
        $username = $usernameField.Text.Trim()
        if ($username -notmatch '^[a-zA-Z0-9_-]{1,40}$' -or $passwordField.TextLength -lt 8 -or $passwordField.TextLength -gt 128) {
            $errorLabel.Text = '请检查账号格式和密码长度。'
            return
        }
        try {
            $details = @{username=$username;password=$passwordField.Text}
            if ($script:emailVerification) {
                $details.email = $emailField.Text.Trim()
                $details.code = $codeField.Text.Trim()
            }
            $null = Invoke-BackupApi register $details
            $signInName.Text = $username
            $passwordField.Clear()
            $codeField.Clear()
            $errorLabel.Text = ''
            $script:registrationWindow.Close()
            $signInMessage.Text = '注册成功，请登录。'
        } catch {
            $errorLabel.Text = '请求失败，请检查账号信息或连接。'
            if ($_.ErrorDetails.Message) {
                try { $errorLabel.Text = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch {}
            }
        }
    } -Primary

function Add-AuthFieldOutline($Parent) {
    $Parent.Add_Paint({
        param($sender,$eventArgs)
        $graphics = $eventArgs.Graphics
        $graphics.SmoothingMode = 'AntiAlias'
        foreach ($field in $sender.Controls) {
            if ($field -isnot [Windows.Forms.TextBox] -or !$field.Visible -or $field.BorderStyle -ne 'None') { continue }
            $left = $field.Left - 5
            $top = $field.Top - 4
            $right = $field.Right + 5
            $bottom = $field.Bottom + 4
            $diameter = 12
            $shape = New-Object Drawing.Drawing2D.GraphicsPath
            $fill = New-Object Drawing.SolidBrush($field.BackColor)
            $line = New-Object Drawing.Pen([Drawing.Color]::FromArgb(222,224,230))
            try {
                $shape.AddArc($left,$top,$diameter,$diameter,180,90)
                $shape.AddArc(($right-$diameter),$top,$diameter,$diameter,270,90)
                $shape.AddArc(($right-$diameter),($bottom-$diameter),$diameter,$diameter,0,90)
                $shape.AddArc($left,($bottom-$diameter),$diameter,$diameter,90,90)
                $shape.CloseFigure()
                $graphics.FillPath($fill,$shape)
                $graphics.DrawPath($line,$shape)
            } finally {
                $line.Dispose()
                $fill.Dispose()
                $shape.Dispose()
            }
        }
    })
}

foreach ($field in $signInName,$signInSecret,$usernameField,$passwordField,$emailField,$codeField,$serverAddress) {
    $field.BackColor = [Drawing.Color]::FromArgb(243,243,245)
    if ($field -ne $serverAddress) { $field.BorderStyle = 'None' }
}
Add-AuthFieldOutline $loginCard
Add-AuthFieldOutline $registrationPage
Add-AuthFieldOutline $serverConfig
Set-AuthButtonStyle $connectSaveButton $true
Set-AuthButtonStyle $verificationButton $false
Set-AuthButtonStyle $confirm $true
Set-AuthButtonStyle $cancel $false

function Show-RegistrationWindow {
    if ($script:registrationWindow) { return }
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = '注册账号'
    $dialog.ShowIcon = $false
    $dialog.Font = $form.Font
    $dialog.BackColor = [Drawing.Color]::FromArgb(187,193,202)
    $dialog.Padding = New-Object Windows.Forms.Padding(1)
    $dialog.AutoScaleMode = 'None'
    $dialog.FormBorderStyle = 'None'
    $dialog.StartPosition = 'CenterParent'
    $dialog.ShowInTaskbar = $false
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ClientSize = New-Object Drawing.Size(([int](348*$layoutFactor)+2),([int](386*$layoutFactor)+2))
    $script:registrationWindow = $dialog
    $errorLabel.Text = ''
    $registrationPage.Parent = $dialog
    $diameter = [int](20 * $layoutFactor)
    Set-FluentCorners $dialog $diameter
    $close = Add-Button $registrationPage '×' ([int](304*$layoutFactor)) ([int](5*$layoutFactor)) ([int](38*$layoutFactor)) { $script:registrationWindow.Close() }
    $close.Height = [int](27*$layoutFactor)
    $close.BackColor = $white
    $close.AccessibleName = '关闭'
    $close.BringToFront()
    $close.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(230,120,126)
    $dialog.CancelButton = $close
    $registrationPage.Visible = $true
    $dialog.Add_Shown({
        $dialog.PerformLayout()
        Set-FluentCorners $registrationPage ($diameter - 2)
    })
    try { [void]$dialog.ShowDialog($form) }
    finally {
        $passwordField.Clear()
        $codeField.Clear()
        $registrationPage.Visible = $false
        $registrationPage.Parent = $workspace
        $previousRegion = $registrationPage.Region
        $registrationPage.Region = $null
        if ($previousRegion) { $previousRegion.Dispose() }
        $close.Dispose()
        $script:registrationWindow = $null
        $dialog.Dispose()
    }
}

$profilePage = Add-Page '我的' '查看当前账号和备份空间用量。'
$profileName = Add-Caption $profilePage '' 28 30 700 36 16 $ink -Bold
$profileQuota = Add-Caption $profilePage '' 28 85 700 34 13 $muted
$profileUsage = New-Object Windows.Forms.ProgressBar
$profileUsage.SetBounds(28,128,540,12)
$profileUsage.Maximum = 1000
$profileUsage.Style = 'Continuous'
$profileUsage.AccessibleName = '备份空间使用比例'
$profileUsage.Visible = $false
$profilePage.Controls.Add($profileUsage)
$profileLogout = Add-Button $profilePage '退出登录' 28 170 120 { $null = Submit-BackupAction logout @{} }
$script:mainHeadingLeft = 234
$script:guestLeft = 24
$script:mainWorkspaceTop = 108
$script:loginWorkspaceTop = 54
$script:loginConfigTop = 114
$script:registerConfigTop = 310
$signInSecret.Add_KeyDown({
    param($sender,$eventArgs)
    if ($eventArgs.KeyCode -eq 'Enter') { $signInAction.PerformClick(); $eventArgs.SuppressKeyPress = $true }
})
$script:navButtons[6].Visible = $false
$script:navButtons[0].Visible = $false
$script:navButtons[1].Visible = $false
$script:navButtons[7].Visible = $false
$mainPages = @(4,2,5,3,8)
for ($position = 0; $position -lt $mainPages.Count; $position++) {
    $index = $mainPages[$position]
    $button = $script:navButtons[$index]
    $button.Text = "{0:D2}    {1}" -f ($position+1),$script:pages[$index].Title
    $button.Top = 148 + $position*51
    $button.TabIndex = $position
}
Select-Page 4
$form.ResumeLayout($true)
Scale-DesktopLayout $form
$form.MinimumSize = $form.Size
$layoutFactor = $form.ClientSize.Width / 1050
$script:mainHeadingLeft = [int](234 * $layoutFactor)
$script:guestLeft = [int](24 * $layoutFactor)
$script:mainWorkspaceTop = [int](108 * $layoutFactor)
$script:loginWorkspaceTop = [int](32 * $layoutFactor)
$script:loginConfigTop = [int](114 * $layoutFactor)
$connectionSurface.Left = $loginCard.Right
$connectionSurface.Height = $loginCard.Height
$signInPage.BackColor = $form.BackColor
$script:compactLoginWidth = $connectionSurface.Right
$script:registerConfigTop = [int](310 * $layoutFactor)
$script:mainWorkspaceHeight = $workspace.Height
$script:regularConfigSize = $serverConfig.Size
$script:serverConfigBounds = @($serverConfig.Controls | ForEach-Object { $_.Bounds })
$script:compactConfigSize = New-Object Drawing.Size(([int](204 * $layoutFactor)),([int](174 * $layoutFactor)))
$script:compactConfigBounds = @(
    foreach ($bounds in @(@(18,4,168,22), @(18,29,168,27), @(0,0,1,1), @(18,123,168,43), @(18,74,168,34))) {
        New-Object Drawing.Rectangle(([int]($bounds[0]*$layoutFactor)),([int]($bounds[1]*$layoutFactor)),([int]($bounds[2]*$layoutFactor)),([int]($bounds[3]*$layoutFactor)))
    }
)
if ([Environment]::OSVersion.Version.Build -ge 22000) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class BackupWindowAppearance {
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

    public static void Apply(IntPtr window, bool hideCaption = false) {
        int round = 2;
        int caption = 0x00F3F3F3;
        int border = 0x00D7D7D7;
        DwmSetWindowAttribute(window, 33, ref round, sizeof(int));
        DwmSetWindowAttribute(window, 35, ref caption, sizeof(int));
        DwmSetWindowAttribute(window, 34, ref border, sizeof(int));
        if (hideCaption) DwmSetWindowAttribute(window, 36, ref caption, sizeof(int));
    }
}
"@
}
$script:mainClientSize = $form.ClientSize
$chrome = New-Object Windows.Forms.Panel
$chrome.Height = [int](23 * $layoutFactor)
$chrome.Dock = 'Top'
$chrome.BackColor = $form.BackColor
$form.Controls.Add($chrome)
$chrome.BringToFront()
$chrome.Add_MouseDown({
    param($sender,$eventArgs)
    if ($eventArgs.Button -eq 'Left') {
        if ($eventArgs.Clicks -eq 2) { $form.ToggleMaximize() }
        elseif ($form.WindowState -eq 'Normal') { $form.DragWindow() }
    }
})
$chromeButtonWidth = [int](44 * $layoutFactor)
$chromeClose = Add-Button $chrome '×' 0 0 $chromeButtonWidth { $form.Close() }
$chromeMaximize = Add-Button $chrome '□' 0 0 $chromeButtonWidth { $form.ToggleMaximize() }
$chromeMinimize = Add-Button $chrome '−' 0 0 $chromeButtonWidth { $form.WindowState = 'Minimized' }
foreach ($button in $chromeClose,$chromeMaximize,$chromeMinimize) {
    $button.Dock = 'Right'
    $button.Region = $null
    $button.BackColor = $chrome.BackColor
}
$chrome.Controls.SetChildIndex($chromeClose, $chrome.Controls.Count - 1)
$chrome.Controls.SetChildIndex($chromeMaximize, $chrome.Controls.Count - 2)
$loginCard.Add_MouseDown({
    param($sender,$eventArgs)
    if ($eventArgs.Button -eq 'Left') { $form.DragWindow() }
})
$chromeClose.AccessibleName = '关闭'
$chromeMaximize.AccessibleName = '最大化或还原'
$chromeMinimize.AccessibleName = '最小化'
$chromeClose.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(230,120,126)
$form.Add_Resize({
    $chromeMaximize.Text = if ($form.WindowState -eq 'Maximized') { '❐' } else { '□' }
})
Select-Page 6

Add-Type -AssemblyName System.Net.Http
$stateClient = New-Object Net.Http.HttpClient
$stateClient.Timeout = [TimeSpan]::FromSeconds(3)
$stateClient.DefaultRequestHeaders.Add('X-Backup-Console','1')
$script:stateRequest = $null
$script:nextStateCheck = [DateTime]::MinValue

function Start-PageRequest($Action,$Data,$Hint) {
    $content = New-Object Net.Http.StringContent(($Data | ConvertTo-Json -Compress),[Text.Encoding]::UTF8,'application/json')
    $script:pageRequest = @{
        Task = $stateClient.PostAsync("$script:baseUrl/api/$Action",$content)
        Action = $Action
        Hint = $Hint
        Server = $script:baseUrl
        User = $script:activeUser
    }
}

function Complete-PageRequest {
    $pending = $script:pageRequest
    if (!$pending -or !$pending.Task.IsCompleted) { return }
    $script:pageRequest = $null
    if ($pending.Server -ne $script:baseUrl -or $pending.User -ne $script:activeUser) { return }
    try {
        $response = $pending.Task.GetAwaiter().GetResult()
        try {
            $null = $response.EnsureSuccessStatusCode()
            $data = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        } finally { $response.Dispose() }
        switch ($pending.Action) {
            'space' { Update-SpacePage -Listing $data }
            'trash-list' { & $reloadTrash @($data | Where-Object { $null -ne $_ }) }
            'quota' {
            $quota = $data
            $script:profileQuotaUser = $script:activeUser
            $profileQuota.Text = '已用 {0:N2} GB / {1:N0} GB（含回收站）' -f ($quota.used / 1e9),($quota.limit / 1e9)
            $profileUsage.Value = [int][Math]::Min(1000, [Math]::Max(0, 1000 * $quota.used / $quota.limit))
            $profileUsage.Show()
            }
        }
    } catch {
        if ($pending.Action -eq 'quota') { $profileUsage.Hide() }
        $pending.Hint.Text = '加载失败：' + $_.Exception.Message
    }
}

function Update-Desktop([switch]$Poll) {
    if (!$Poll) {
        $script:stateRequest = $null
        $script:nextStateCheck = [DateTime]::MinValue
    }
    if (!$script:stateRequest) {
        if ([DateTime]::UtcNow -lt $script:nextStateCheck) { return }
        $script:stateRequest = $stateClient.GetStringAsync("$script:baseUrl/api/state")
        return
    }
    if (!$script:stateRequest.IsCompleted) { return }
    $request = $script:stateRequest
    $script:stateRequest = $null
    $script:nextStateCheck = [DateTime]::UtcNow.AddMilliseconds(1200)
    try {
        $state = $request.GetAwaiter().GetResult() | ConvertFrom-Json
        if ($script:refreshAfterDrop -and !$state.busy) {
            $script:refreshAfterDrop = $false
            if ($spacePage.Visible -and $script:spaceListing) { Update-SpacePage $script:spaceListing.path }
        }
        $script:starting = $false
        if ($script:pendingAddress) {
            [IO.File]::WriteAllText($connectionConfig,$script:pendingAddress)
            $script:hiddenAddresses = @($script:hiddenAddresses | Where-Object { $_ -ne $script:pendingAddress })
            $script:addressHistory = @(@($script:pendingAddress) + @($script:addressHistory) | Select-Object -Unique -First 10)
            Save-AddressHistory
            $serverAddress.Text = $script:pendingAddress
            $script:pendingAddress = $null
            $script:notice = "已连接 $serverName，地址已保存。"
        }
        $connection.Text = "●  $serverName 已连接"
        $guestConnection.ForeColor = [Drawing.Color]::FromArgb(15,118,85)
        $guestConnection.Text = "●  $serverName 已连接"
        $signInAction.Enabled = $true
        $confirm.Enabled = $true
        $connection.ForeColor = [Drawing.Color]::FromArgb(15,118,85)
        $script:authenticated = [bool]$state.authenticated
        $script:emailVerification = [bool]$state.email_verification
        foreach ($control in $registrationPage.Controls) {
            if ($control.Tag -eq 'email-verification') { $control.Visible = $script:emailVerification }
        }
        $userChanged = $script:activeUser -ne [string]$state.username
        if ($userChanged) {
            $script:activeUser = [string]$state.username
            $script:profileQuotaUser = $null
            $script:initialized = $false
            $script:spaceListing = $null
            $spaceEntries.Items.Clear()
            $restoreArchive.Clear()
            $restoreArchive.Tag = $null
            $archive.Clear()
            $archive.Tag = $null
            $autoOutput.Clear()
            $autoOutput.Tag = $null
            if (!$script:authenticated) { $spaceHint.Text = '请在设置中登录，或注册一个新账号。' }
        }
        
        $accountShortcut.Text = if ($script:authenticated) { '我的' } else { '登录 / 注册' }
        $profileLogout.Enabled = $script:authenticated -and !$state.busy
        foreach ($button in $submitButtons) { $button.Enabled = $script:authenticated -and !$state.busy }
        $progress = $state.progress
        $progressBar.Visible = [bool]$state.busy -and $null -ne $progress
        $progressLabel.Visible = $progressBar.Visible
        $progressOffset = if ($progressBar.Visible) { $progressBar.Bottom + 8 } else { $progressLabel.Top + 9 }
        $status.Top = $progressOffset
        $status.Height = [Math]::Max(24,($statusCard.ClientSize.Height - $progressOffset - 14))
        if ($progressBar.Visible) {
            if ($progress.total -gt 0) {
                $percent = [int][Math]::Floor(100.0 * $progress.done / $progress.total)
                $progressBar.Style = 'Continuous'
                $progressBar.Value = [Math]::Min(100,[Math]::Max(0,$percent))
                $rateText = if ($progress.phase -eq '等待服务器校验') { '' }
                    elseif ($progress.rate -ge 1e6) { '  ·  {0:N2} MB/s' -f ($progress.rate/1e6) }
                    elseif ($progress.rate -gt 0) { '  ·  {0:N0} KB/s' -f ($progress.rate/1e3) }
                    else { '' }
                $progressLabel.Text = ('{0}  {1}%  ·  {2:N1} / {3:N1} MB' -f $progress.phase,$percent,($progress.done/1e6),($progress.total/1e6)) + $rateText
            } else {
                $progressBar.Style = 'Marquee'
                $progressLabel.Text = $progress.phase
            }
        }
        if ($script:authenticated -and !$script:initialized) {
            $source.Text = Join-Path (Split-Path -Parent $root) '测试文件夹\示例资料'
            $script:spaceRoot = $state.example.output
            Set-BackupSpaceLocation $archive $script:spaceRoot
            $archiveName.Text = 'desktop-' + [guid]::NewGuid().ToString('N').Substring(0,12) + '.sbackup'
            Set-RestoreDestination (Join-Path (Split-Path -Parent $root) '测试文件夹\还原位置')
            Set-BackupSpaceLocation $autoOutput $script:spaceRoot
            $script:initialized = $true
        }
        if ($userChanged) {
            if ($script:authenticated) { Select-Page 4 }
            else { $signInSecret.Clear(); $signInMessage.Text = ''; Select-Page 6 }
        } elseif (!$script:authenticated -and $script:currentPage -notin 6,7) {
            Select-Page 6
        }
        $newStatus = if ($script:notice) { $script:notice } else { $state.status }
        if ($newStatus.StartsWith('{"id"')) {
            try {
                $uploaded = $newStatus | ConvertFrom-Json
                $newStatus = "网络备份成功`r`n版本：$($uploaded.id)`r`n实际上传 $($uploaded.uploaded) / $($uploaded.bytes) 字节"
            } catch {}
        }
        $newStatus = $newStatus -replace '(?<!
)
', "`r`n"
        if ($status.Text -ne $newStatus) { $status.Text = $newStatus }
        $newJobs = ConvertTo-Json -InputObject @($state.jobs) -Compress
        if ($newJobs -ne $script:jobCache) {
            $oldId = if ($jobList.SelectedIndex -ge 0) { $script:jobs[$jobList.SelectedIndex].id }
            $script:jobs = @($state.jobs)
            $jobList.Items.Clear()
            foreach ($job in $script:jobs) {
                $kind = if ($job.mode -eq 'watch') { '变化触发' } else { '定时' }
                $index = $jobList.Items.Add("$kind · $($job.period) 秒 · 保留 $($job.keep) 份 · $($job.source) · $($job.status)")
                if ($job.id -eq $oldId) { $jobList.SelectedIndex = $index }
            }
            $script:jobCache = $newJobs
        }
    } catch {
        $progressBar.Hide()
        $progressLabel.Hide()
        $connection.Text = "●  等待 $serverName"
        $connection.ForeColor = $railMuted
        foreach ($button in $submitButtons) { $button.Enabled = $false }
        if (!$script:starting) {
            $script:starting = $true
            $script:startupTime = [DateTime]::UtcNow
            try {
                $python = Get-Command python.exe -ErrorAction Stop
                $logName = if ($localTarget) { 'BackupAssistantWSL-startup.log' } else { 'BackupAssistantCloud-startup.log' }
                $log = Join-Path $env:LOCALAPPDATA $logName
                $clientArguments = if ($localTarget) { '-B linux/cloud-client.py --wsl' } else { '-B linux/cloud-client.py' }
                $null = Start-Process -FilePath $python.Source -ArgumentList $clientArguments -WorkingDirectory $root -WindowStyle Hidden -RedirectStandardError $log -PassThru
            } catch {
                $status.Text = '无法启动 Windows 备份组件：' + $_.Exception.Message
                return
            }
        }
        $message = if (([DateTime]::UtcNow - $script:startupTime).TotalSeconds -gt 30) {
            if ($localTarget) { '无法连接 WSL。请检查 Ubuntu 是否可启动。' }
            else { '无法连接腾讯云。请检查 TencentCloud SSH 连接。' }
        } else { "正在连接 $serverName…" }
        $guestConnection.ForeColor = $muted
        $guestConnection.Text = $message
        $signInAction.Enabled = $false
        $confirm.Enabled = $false
        if ($status.Text -ne $message) { $status.Text = $message }
    }
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({ Update-Desktop -Poll; Complete-PageRequest })
$form.Add_Shown({ Update-Desktop; $timer.Start() })
$form.Add_FormClosed({ $timer.Stop(); $timer.Dispose(); $stateClient.Dispose() })
[void]$form.ShowDialog()
