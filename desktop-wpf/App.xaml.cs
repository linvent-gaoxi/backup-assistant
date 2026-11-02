using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Input;
using System.Windows.Documents;
using System.Windows.Threading;
using Wpf.Ui.Controls;
using Button = Wpf.Ui.Controls.Button;
using TextBox = Wpf.Ui.Controls.TextBox;
using PasswordBox = Wpf.Ui.Controls.PasswordBox;
using MessageBox = System.Windows.MessageBox;
using MessageBoxButton = System.Windows.MessageBoxButton;
using MessageBoxResult = System.Windows.MessageBoxResult;
using MenuItem = System.Windows.Controls.MenuItem;
using TextBlock = System.Windows.Controls.TextBlock;

namespace BackupDesktop;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var window = new ClientWindow();
        MainWindow = window;
        window.Show();
    }
}

sealed class ClientWindow : FluentWindow
{
    const string Cloud = "ssh://TencentCloud";
    const string Wsl = "https://127.0.0.1:19444";
    readonly string root = FindRoot();
    readonly string config = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BackupAssistant-Server.txt");
    readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(35) };
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    readonly TextBlock connection = Caption("");
    readonly TextBlock status = Caption("");
    readonly ProgressBar progress = new() { Height = 6, Maximum = 100 };
    readonly StackPanel page = new();
    readonly Wpf.Ui.Controls.ListView entries = new() { SelectionMode = SelectionMode.Extended, MinHeight = 300 };
    readonly TextBlock crumb = Caption("");
    JsonElement state;
    string address = Cloud, user = "", directory = ".", parentDirectory = "";
    string endpoint => address == Wsl ? "http://127.0.0.1:18766" : "http://127.0.0.1:18765";
    int revision, selectedPage;
    bool polling, starting;
    Point? dragOrigin;
    SelectionOutline? dragOutline;
    EditorOverlay? editor;
    readonly TextBlock emptySpace = Caption("这个文件夹还没有备份。可以点击「上传」，或将文件拖到列表中。");
    static readonly string[] Pages = ["备份空间", "自动备份", "回收站", "设置", "我的"];

    public ClientWindow()
    {
        Title = "文件备份助手";
        ExtendsContentIntoTitleBar = true;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var icon = System.Windows.Media.Imaging.BitmapDecoder.Create(
            new Uri(Path.Combine(root, "linux", "BackupAssistant.ico")),
            System.Windows.Media.Imaging.BitmapCreateOptions.None,
            System.Windows.Media.Imaging.BitmapCacheOption.OnLoad);
        Icon = icon.Frames.MaxBy(frame => frame.PixelWidth);
        http.DefaultRequestHeaders.Add("X-Backup-Console", "1");
        if (File.Exists(config) && File.ReadAllText(config).Trim() == Wsl) address = Wsl;
        var columns = new Wpf.Ui.Controls.GridView();
        columns.Columns.Add(new Wpf.Ui.Controls.GridViewColumn { Header = "名称", Width = 360, MinWidth = 180, DisplayMemberBinding = new System.Windows.Data.Binding(nameof(Entry.DisplayName)) });
        columns.Columns.Add(new Wpf.Ui.Controls.GridViewColumn { Header = "大小", Width = 95, DisplayMemberBinding = new System.Windows.Data.Binding(nameof(Entry.Size)) });
        columns.Columns.Add(new Wpf.Ui.Controls.GridViewColumn { Header = "修改时间", Width = 155, DisplayMemberBinding = new System.Windows.Data.Binding(nameof(Entry.Modified)) });
        entries.View = columns;
        entries.AllowDrop = true;
        EnableExplorerSelection(entries);
        entries.Drop += async (_, e) =>
        {
            if (e.Data.GetData(DataFormats.FileDrop) is string[] paths && paths.Length > 0)
                await Run(() => Upload(paths));
        };
        entries.MouseDoubleClick += async (_, e) =>
        {
            if (e.OriginalSource is DependencyObject source && ItemsControl.ContainerFromElement(entries, source) is System.Windows.Controls.ListViewItem)
                await Run(OpenSelection);
        };
        entries.PreviewKeyDown += async (_, e) =>
        {
            if (editor != null) return;
            Func<Task>? action = e.Key switch
            {
                Key.Enter => OpenSelection,
                Key.Back => OpenParent,
                Key.F2 => RenameSelection,
                Key.Delete => RemoveSelection,
                Key.F5 => () => RefreshSpace(),
                _ => null
            };
            if (e.Key == Key.A && Keyboard.Modifiers == ModifierKeys.Control)
            {
                entries.SelectAll();
                e.Handled = true;
            }
            else if (action != null)
            {
                e.Handled = true;
                await Run(action);
            }
        };
        ShowLogin();
        timer.Tick += async (_, _) => await Poll();
        Loaded += async (_, _) => { timer.Start(); await Poll(); };
        Closed += (_, _) => { timer.Stop(); http.Dispose(); };
    }

    static string FindRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "linux", "cloud-client.py"))) return dir.FullName;
        throw new DirectoryNotFoundException("请在备份助手项目目录中运行客户端。");
    }

    async Task<JsonElement> Call(string action, object? data = null, CancellationToken cancellation = default)
    {
        using var content = data == null ? null : new StringContent(JsonSerializer.Serialize(data), Encoding.UTF8, "application/json");
        using var result = data == null
            ? await http.GetAsync(endpoint + "/api/" + action, cancellation)
            : await http.PostAsync(endpoint + "/api/" + action, content, cancellation);
        using var json = JsonDocument.Parse(await result.Content.ReadAsStringAsync(cancellation));
        if (!result.IsSuccessStatusCode) throw new InvalidOperationException(Text(json.RootElement, "error"));
        return json.RootElement.Clone();
    }

    async Task Poll()
    {
        if (polling) return;
        polling = true;
        var target = endpoint;
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            var next = await Call("state", cancellation: timeout.Token);
            if (target != endpoint) return;
            var previouslyBusy = Flag(state, "busy");
            state = next;
            starting = false;
            connection.Foreground = Brushes.SeaGreen;
            connection.Text = "●  " + (address == Wsl ? "本地 WSL" : "腾讯云") + " 已连接";
            status.Text = Text(state, "status");
            var transfer = Property(state, "progress");
            var total = Number(transfer, "total");
            var done = Number(transfer, "done");
            var busy = Flag(state, "busy");
            progress.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
            progress.IsIndeterminate = total <= 0;
            progress.Value = total > 0 ? Math.Clamp(100 * done / total, 0, 100) : 0;
            if (busy && transfer.ValueKind == JsonValueKind.Object)
                status.Text = total > 0
                    ? $"{Text(transfer, "phase")}  ·  {done / 1e6:N1} / {total / 1e6:N1} MB  ·  {Number(transfer, "rate") / 1e6:N2} MB/s"
                    : Text(transfer, "phase");
            var account = Text(state, "username");
            if (account != user)
            {
                user = account;
                directory = ".";
                if (user.Length == 0) ShowLogin();
                else ShowWorkspace();
            }
            else if (previouslyBusy && !busy && user.Length > 0 && selectedPage is 0 or 1 or 4)
                if (selectedPage == 0) await RefreshSpace(); else await ShowPage(selectedPage);
        }
        catch (Exception error)
        {
            if (target != endpoint) return;
            connection.Foreground = Brushes.DimGray;
            connection.Text = "●  等待服务器连接";
            if (!starting)
            {
                starting = true;
                try
                {
                    var command = new ProcessStartInfo("python.exe") { WorkingDirectory = root, CreateNoWindow = true, UseShellExecute = false };
                    command.ArgumentList.Add("-B");
                    command.ArgumentList.Add("linux/cloud-client.py");
                    if (address == Wsl) command.ArgumentList.Add("--wsl");
                    using var process = Process.Start(command);
                }
                catch (Exception startError) { connection.Text = startError.Message; }
            }
            else if (user.Length > 0) status.Text = error.Message;
        }
        finally { polling = false; }
    }

    Grid Frame()
    {
        var frame = new Grid();
        frame.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        frame.RowDefinitions.Add(new RowDefinition());
        frame.Children.Add(new TitleBar { Title = "", ShowMaximize = user.Length > 0 });
        Content = frame;
        return frame;
    }

    void ShowLogin()
    {
        WindowState = WindowState.Normal;
        ResizeMode = ResizeMode.CanMinimize;
        MinWidth = 0;
        MinHeight = 0;
        Width = 650;
        Height = 395;
        var frame = Frame();
        var split = new Grid();
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.15, GridUnitType.Star) });
        split.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetRow(split, 1);
        frame.Children.Add(split);
        var left = new StackPanel { Margin = new Thickness(30, 24, 30, 20) };
        split.Children.Add(left);
        left.Children.Add(Heading("账号登录"));
        var name = Field(left, "账号");
        var password = Secret(left, "密码");
        var login = Action("登录", async () =>
        {
            await Call("login", new { username = name.Text.Trim(), password = password.Password });
            password.Clear();
            await Poll();
        }, true);
        left.Children.Add(login);
        password.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter) login.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); };

        var right = new StackPanel { Margin = new Thickness(24, 20, 24, 16) };
        var rightSurface = new Border { Background = new SolidColorBrush(Color.FromRgb(244, 247, 252)), Child = right };
        Grid.SetColumn(rightSurface, 1);
        split.Children.Add(rightSurface);
        var register = Action("创建账号", Register);
        register.HorizontalAlignment = HorizontalAlignment.Right;
        right.Children.Add(register);
        right.Children.Add(Heading("文件备份助手"));
        AddServerControls(right);
    }

    void AddServerControls(Panel parent)
    {
        parent.Children.Add(Caption("服务器地址"));
        var choices = new ComboBox { IsEditable = true, ItemsSource = new[] { Cloud, Wsl }, Text = address, Margin = new Thickness(0, 5, 0, 8) };
        choices.PreviewMouseLeftButtonDown += (_, e) =>
        {
            if (e.OriginalSource is not DependencyObject source) return;
            var input = choices.Template.FindName("PART_EditableTextBox", choices) as System.Windows.Controls.TextBox;
            if (input == null || (source != input && !input.IsAncestorOf(source))) return;
            input.Focus();
            choices.IsDropDownOpen = true;
        };
        parent.Children.Add(choices);
        parent.Children.Add(Action("连接并保存", async () =>
        {
            var target = choices.Text.Trim().TrimEnd('/');
            if (target is not (Cloud or Wsl)) throw new InvalidOperationException("请选择腾讯云或本地 WSL。");
            if (address == target && user.Length > 0) return;
            if (user.Length > 0) await Call("logout", new { });
            address = target;
            starting = false;
            File.WriteAllText(config, address);
            user = "";
            ShowLogin();
            await Poll();
        }));
        Detach(connection);
        parent.Children.Add(connection);
    }

    Task Register()
    {
        if (!connection.Text.EndsWith("已连接", StringComparison.Ordinal))
            throw new InvalidOperationException("请先连接服务器。");
        var fields = new StackPanel();
        var dialog = Dialog("创建备份账号", fields, 370);
        var username = Field(fields, "账号（字母、数字、下划线或连字符）");
        var password = Secret(fields, "密码（至少 8 个字符）");
        TextBox? email = null, code = null;
        if (Flag(state, "email_verification"))
        {
            email = Field(fields, "接收验证码的邮箱");
            code = Field(fields, "邮箱验证码");
            fields.Children.Add(Action("获取验证码", async () =>
            {
                await Call("email-code", new { username = username.Text.Trim(), email = email.Text.Trim() });
                MessageBox.Show(dialog, "验证码已发送，5 分钟内有效。", "邮箱验证");
            }));
        }
        fields.Children.Add(Action("注册", async () =>
        {
            await Call("register", new { username = username.Text.Trim(), password = password.Password, email = email?.Text.Trim(), code = code?.Text.Trim() });
            dialog.Close();
            MessageBox.Show(this, "注册成功，请登录。", Title);
        }, true));
        dialog.ShowDialog();
        return Task.CompletedTask;
    }

    void ShowWorkspace()
    {
        ResizeMode = ResizeMode.CanResize;
        MinWidth = 850;
        MinHeight = 600;
        Width = 1040;
        Height = 730;
        var layout = new Grid();
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(188) });
        layout.ColumnDefinitions.Add(new ColumnDefinition());
        Content = layout;
        var navigation = new ListBox { BorderThickness = new Thickness(0), Background = Brushes.Transparent };
        SymbolRegular[] symbols = [SymbolRegular.Folder24, SymbolRegular.Clock24, SymbolRegular.Delete24, SymbolRegular.Settings24, SymbolRegular.Person24];
        Color[] colors = [Color.FromRgb(0,103,192), Color.FromRgb(121,75,177), Color.FromRgb(170,83,47), Color.FromRgb(83,96,114), Color.FromRgb(16,122,103)];
        for (var i = 0; i < Pages.Length; i++)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(3, 5, 0, 5) };
            row.Children.Add(new SymbolIcon { Symbol = symbols[i], FontSize = 19, Foreground = new SolidColorBrush(colors[i]), Margin = new Thickness(0, 0, 9, 0) });
            row.Children.Add(new TextBlock { Text = Pages[i], VerticalAlignment = VerticalAlignment.Center });
            navigation.Items.Add(new ListBoxItem { Content = row });
        }
        navigation.SelectedIndex = 0;
        var sidebar = new StackPanel();
        var brand = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(9, 6, 0, 16) };
        brand.Children.Add(new System.Windows.Controls.Image { Source = Icon, Width = 24, Height = 24, Margin = new Thickness(0, 0, 8, 0) });
        brand.Children.Add(new TextBlock { Text = "文件备份助手", FontSize = 18, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        sidebar.Children.Add(brand);
        sidebar.Children.Add(navigation);
        layout.Children.Add(new Border { Child = sidebar, Padding = new Thickness(12), Background = new SolidColorBrush(Color.FromRgb(239, 239, 239)) });
        var right = new DockPanel { Background = new SolidColorBrush(Color.FromRgb(247, 247, 247)) };
        Grid.SetColumn(right, 1);
        layout.Children.Add(right);
        var windowBar = new TitleBar { Title = "", Background = Brushes.Transparent };
        DockPanel.SetDock(windowBar, Dock.Top);
        right.Children.Add(windowBar);
        var content = new DockPanel { Margin = new Thickness(24, 12, 24, 16) };
        right.Children.Add(content);
        var feedback = new StackPanel();
        feedback.Children.Add(new TextBlock { Text = "任务状态", FontWeight = FontWeights.SemiBold });
        Detach(status);
        Detach(progress);
        feedback.Children.Add(status);
        feedback.Children.Add(progress);
        var statusCard = new Border
        {
            Child = feedback, Margin = new Thickness(0, 12, 0, 0), Padding = new Thickness(0, 12, 0, 0),
            BorderBrush = new SolidColorBrush(Color.FromRgb(225, 225, 225)), BorderThickness = new Thickness(0, 1, 0, 0)
        };
        DockPanel.SetDock(statusCard, Dock.Bottom);
        content.Children.Add(statusCard);
        Detach(page);
        content.Children.Add(new ScrollViewer { Content = page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        navigation.SelectionChanged += async (_, _) =>
        {
            if (navigation.SelectedIndex >= 0) await ShowPage(navigation.SelectedIndex);
        };
        _ = ShowPage(0);
    }

    async Task ShowPage(int index)
    {
        CancelRename();
        EndSelection();
        selectedPage = index;
        var request = ++revision;
        page.Children.Clear();
        page.Children.Add(Heading(Pages[index]));
        try
        {
            switch (index)
            {
                case 0: await Space(request); break;
                case 1: ShowJobs(); break;
                case 2: await Trash(request); break;
                case 3: AddServerControls(page); break;
                case 4:
                    page.Children.Add(Caption("账号  " + user));
                    var quota = await Call("quota", new { });
                    if (request != revision) return;
                    var used = Number(quota, "used");
                    var limit = Number(quota, "limit");
                    page.Children.Add(Caption($"已用 {used / 1e9:N2} GB / {limit / 1e9:N0} GB（含回收站）"));
                    page.Children.Add(new ProgressBar { Height = 8, Maximum = Math.Max(limit, 1), Value = used, Margin = new Thickness(0, 8, 0, 12) });
                    page.Children.Add(Action("退出登录", async () => { await Call("logout", new { }); await Poll(); }));
                    break;
            }
        }
        catch (Exception error) { if (request == revision) status.Text = error.Message; }
    }

    async Task Space(int request)
    {
        Detach(crumb);
        page.Children.Add(crumb);
        var tools = Toolbar(page);
        tools.Children.Add(Action("上一级", OpenParent));
        tools.Children.Add(Action("刷新", () => RefreshSpace()));
        tools.Children.Add(Action("新建文件夹", async () =>
        {
            var name = Prompt("新建文件夹", "文件夹名称");
            if (name != null) { await Call("space-folder", new { path = directory, name }); await RefreshSpace(); }
        }));
        tools.Children.Add(Action("上传", () => Upload(), true));
        tools.Children.Add(Action("下载", () => Download()));
        tools.Children.Add(Action("删除", RemoveSelection));
        tools.Children.Add(Action("重命名", RenameSelection));
        Detach(entries);
        entries.ContextMenu = new ContextMenu();
        foreach (var (label, action) in new (string, Func<Task>)[] { ("下载", Download), ("归档内容与版本", ShowArchiveCatalog), ("重命名", RenameSelection), ("删除", RemoveSelection) })
        {
            var item = new MenuItem { Header = label };
            item.Click += async (_, _) => await Run(action);
            entries.ContextMenu.Items.Add(item);
        }
        page.Children.Add(entries);
        Detach(emptySpace);
        emptySpace.Visibility = Visibility.Collapsed;
        page.Children.Add(emptySpace);
        await RefreshSpace(request: request);
    }

    async Task RefreshSpace(string? path = null, int? request = null, string? selectName = null)
    {
        if (selectedPage != 0) return;
        var version = request ?? ++revision;
        var listing = await Call("space", new { path = path ?? directory });
        if (version != revision || selectedPage != 0) return;
        CancelRename();
        EndSelection();
        directory = Text(listing, "path");
        parentDirectory = Text(listing, "parent");
        var rootPath = Text(listing, "root");
        var relative = directory.StartsWith(rootPath, StringComparison.Ordinal) ? directory[rootPath.Length..].Trim('/') : directory;
        crumb.Text = relative.Length == 0 ? "全部文件" : "全部文件 / " + relative;
        var rows = Items(listing, "entries").Select(item => new Entry(item)).ToArray();
        entries.ItemsSource = rows;
        emptySpace.Visibility = rows.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (selectName != null && rows.FirstOrDefault(row => row.Name == selectName) is { } selected)
        {
            entries.SelectedItem = selected;
            entries.ScrollIntoView(selected);
        }
    }

    async Task RemoveSelection()
    {
        var names = entries.SelectedItems.Cast<Entry>().Select(item => item.Name).ToArray();
        if (names.Length == 0 || MessageBox.Show(this, "将选中项目移入回收站？", Title, MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
        await Call("space-trash", new { path = directory, names });
        await RefreshSpace();
    }

    Task RenameSelection()
    {
        if (editor != null || entries.SelectedItems.Count != 1 || entries.SelectedItem is not Entry item) return Task.CompletedTask;
        entries.ScrollIntoView(item);
        entries.UpdateLayout();
        if (entries.ItemContainerGenerator.ContainerFromItem(item) is not FrameworkElement row ||
            AdornerLayer.GetAdornerLayer(row) is not { } layer) return Task.CompletedTask;

        var input = new TextBox { Text = item.Name, Padding = new Thickness(6, 0, 6, 0) };
        editor = new EditorOverlay(row, input, ((Wpf.Ui.Controls.GridView)entries.View).Columns[0].ActualWidth);
        layer.Add(editor);
        var currentEditor = editor;
        var currentPath = directory;
        input.KeyDown += async (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                e.Handled = true;
                CancelRename();
                row.Focus();
            }
            else if (e.Key == Key.Enter)
            {
                e.Handled = true;
                var name = input.Text.Trim();
                if (name.Length == 0 || name.IndexOfAny([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar]) >= 0)
                {
                    await Run(() => throw new InvalidOperationException("请输入有效的文件名。"));
                    return;
                }
                if (editor != currentEditor) return;
                CancelRename();
                row.Focus();
                if (name == item.Name) return;
                await Run(async () =>
                {
                    await Call("space-rename", new { path = currentPath, old = item.Name, @new = name });
                    if (directory == currentPath) await RefreshSpace(selectName: name);
                });
            }
        };
        input.LostKeyboardFocus += (_, _) => { if (editor == currentEditor) CancelRename(); };
        input.Focus();
        var extension = item.Folder ? 0 : Path.GetExtension(item.Name).Length;
        input.Select(0, item.Name.Length - extension);
        return Task.CompletedTask;
    }

    void CancelRename()
    {
        if (editor is not { } current) return;
        editor = null;
        AdornerLayer.GetAdornerLayer(current.AdornedElement)?.Remove(current);
    }

    async Task OpenSelection()
    {
        if (entries.SelectedItems.Count != 1 || entries.SelectedItem is not Entry item) return;
        if (!item.Folder) { await Download(); return; }
        await RefreshSpace(item.Path);
    }

    Task OpenParent() => parentDirectory.Length == 0 ? Task.CompletedTask : RefreshSpace(parentDirectory);

    void EnableExplorerSelection(Wpf.Ui.Controls.ListView list)
    {
        list.PreviewMouseLeftButtonDown += BeginSelection;
        list.PreviewMouseMove += MoveSelection;
        list.PreviewMouseLeftButtonUp += (_, _) => EndSelection();
        list.LostMouseCapture += (_, _) => EndSelection();
        list.PreviewMouseRightButtonDown += (_, e) =>
        {
            if (e.OriginalSource is not DependencyObject source) return;
            if (ItemsControl.ContainerFromElement(list, source) is System.Windows.Controls.ListViewItem row)
            {
                if (!row.IsSelected)
                {
                    list.SelectedItems.Clear();
                    row.IsSelected = true;
                }
                row.Focus();
            }
            else list.SelectedItems.Clear();
        };
    }

    Wpf.Ui.Controls.ListView? dragList;

    void BeginSelection(object sender, MouseButtonEventArgs e)
    {
        if (sender is not Wpf.Ui.Controls.ListView list) return;
        if (e.OriginalSource is not DependencyObject source ||
            ItemsControl.ContainerFromElement(list, source) is System.Windows.Controls.ListViewItem) return;
        for (var element = source; element is Visual && element != list; element = VisualTreeHelper.GetParent(element))
            if (element is System.Windows.Controls.Primitives.ScrollBar or System.Windows.Controls.GridViewColumnHeader) return;
        dragList = list;
        dragOrigin = e.GetPosition(list);
        list.SelectedItems.Clear();
        list.Focus();
        list.CaptureMouse();
        e.Handled = true;
    }

    void MoveSelection(object sender, MouseEventArgs e)
    {
        if (dragList is not { } list || dragOrigin is not { } start || e.LeftButton != MouseButtonState.Pressed) return;
        var point = e.GetPosition(list);
        if (dragOutline == null)
        {
            if (Math.Abs(point.X - start.X) < SystemParameters.MinimumHorizontalDragDistance &&
                Math.Abs(point.Y - start.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            if (AdornerLayer.GetAdornerLayer(list) is not { } layer) return;
            dragOutline = new SelectionOutline(list);
            layer.Add(dragOutline);
        }
        var area = new Rect(start, point);
        dragOutline.Area = area;
        dragOutline.InvalidateVisual();
        foreach (var item in list.Items)
        {
            if (list.ItemContainerGenerator.ContainerFromItem(item) is not System.Windows.Controls.ListViewItem row) continue;
            var bounds = row.TransformToAncestor(list).TransformBounds(new Rect(row.RenderSize));
            row.IsSelected = bounds.IntersectsWith(area);
        }
    }

    void EndSelection()
    {
        if (dragList is not { } list) return;
        dragList = null;
        dragOrigin = null;
        if (dragOutline is { } outline)
        {
            dragOutline = null;
            AdornerLayer.GetAdornerLayer(list)?.Remove(outline);
        }
        if (list.IsMouseCaptured) list.ReleaseMouseCapture();
    }

    async Task ShowArchiveCatalog()
    {
        if (entries.SelectedItems.Count != 1 || entries.SelectedItem is not Entry item || item.Folder) return;
        var fields = new StackPanel();
        var dialog = Dialog("归档内容与版本", fields, 660);
        var version = new ComboBox { DisplayMemberPath = nameof(Entry.Name), Margin = new Thickness(0, 6, 0, 10) };
        var details = Caption("");
        var files = new ListBox { MaxHeight = 330 };
        var tools = new WrapPanel();
        fields.Children.Add(Caption("同目录中的历史归档"));
        fields.Children.Add(version);
        fields.Children.Add(details);
        fields.Children.Add(files);
        fields.Children.Add(tools);
        int offset = 0, total = 0, request = 0;
        string path = item.Path;
        Button previous = null!, next = null!;
        previous = Action("上一页", async () => { if (offset > 0) { offset -= 200; await Load(); } });
        next = Action("下一页", async () => { if (offset + 200 < total) { offset += 200; await Load(); } });
        tools.Children.Add(previous);
        tools.Children.Add(next);
        await Load();
        version.SelectionChanged += async (_, _) => await Run(async () =>
        {
            if (version.SelectedItem is not Entry selected) return;
            path = selected.Path;
            offset = 0;
            await Load();
        });
        dialog.ShowDialog();

        async Task Load()
        {
            var current = ++request;
            var result = await Call("archive-catalog", new { path, offset, limit = 200 });
            if (current != request) return;
            if (version.ItemsSource == null)
            {
                var versions = Items(result, "versions").Select(value => new Entry(value)).ToArray();
                version.ItemsSource = versions;
                version.SelectedItem = versions.FirstOrDefault(value => value.Path == path);
            }
            total = (int)Number(result, "total");
            previous.IsEnabled = offset > 0;
            next.IsEnabled = offset + 200 < total;
            details.Text = Flag(result, "encrypted") ? "此归档已加密，服务器无法读取文件清单。"
                : $"{Text(result, "root")}  ·  第 {offset + 1}–{Math.Min(offset + 200, total)} 项，共 {total} 项";
            files.ItemsSource = Items(result, "entries").Select(value =>
            {
                var kind = (int)Number(value, "kind");
                var label = kind switch { 1 => "目录", 2 => "软链接", 3 => "管道", 4 => "硬链接", _ => "文件" };
                return $"{label}   {Text(value, "name")}   {Number(value, "bytes"):N0} 字节";
            }).ToArray();
        }
    }

    Task Download()
    {
        if (entries.SelectedItem is not Entry item || item.Folder) return Task.CompletedTask;
        var fields = new StackPanel();
        var dialog = Dialog("下载并还原", fields);
        var destination = Folder(fields, "还原位置", Text(Property(state, "example"), "destination"));
        var password = Secret(fields, "归档密码（加密归档需要）");
        fields.Children.Add(Action("下载并还原", async () =>
        {
            await Call("restore", new { archive = item.Path, destination = destination.Text, password = password.Password });
            dialog.Close();
        }, true));
        dialog.ShowDialog();
        return Task.CompletedTask;
    }

    Task Upload(string[]? dropped = null)
    {
        var fields = new StackPanel();
        var dialog = Dialog("上传备份", fields, 500);
        var source = Folder(fields, "源文件夹", Text(Property(state, "example"), "source"));
        if (dropped is { Length: > 0 }) { source.Text = string.Join("; ", dropped); source.IsReadOnly = true; }
        var timestamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
        string DefaultName()
        {
            var path = dropped is { Length: 1 } ? dropped[0] : source.Text.Trim();
            var basename = Path.GetFileName(Path.TrimEndingDirectorySeparator(path));
            if (string.IsNullOrWhiteSpace(basename) || basename.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
                basename = "backup";
            return $"{basename}-{timestamp}.sbackup";
        }
        var generated = DefaultName();
        var name = Field(fields, "归档文件名", generated);
        if (dropped is { Length: > 1 }) { name.Text = "按各源名称自动命名"; name.IsReadOnly = true; }
        else source.TextChanged += (_, _) =>
        {
            if (name.Text != generated && name.Text.Length > 0) return;
            generated = DefaultName();
            name.Text = generated;
        };
        var password = Secret(fields, "归档密码（选填）");
        var compression = new CheckBox { Content = "Huffman 压缩", IsChecked = true, Margin = new Thickness(0, 8, 0, 8) };
        fields.Children.Add(compression);
        var filterPanel = new StackPanel();
        fields.Children.Add(new Expander { Header = "筛选条件", Content = filterPanel });
        var filters = new (string Key, TextBox Field)[] {
            ("name", Field(filterPanel,"文件名")), ("path", Field(filterPanel,"相对路径")),
            ("extensions", Field(filterPanel,"扩展名")), ("min-size", Field(filterPanel,"最小字节数")),
            ("max-size", Field(filterPanel,"最大字节数")), ("after", Field(filterPanel,"起始日期 YYYY-MM-DD")),
            ("before", Field(filterPanel,"结束日期 YYYY-MM-DD"))
        };
        fields.Children.Add(Action("开始上传", async () =>
        {
            var filename = name.Text.Trim();
            if (dropped is not { Length: > 1 } && (filename.Length == 0 || filename.Contains('/') || filename.Contains('\\')))
                throw new InvalidOperationException("请输入有效的归档文件名。");
            if (!filename.EndsWith(".sbackup", StringComparison.OrdinalIgnoreCase)) filename += ".sbackup";
            var options = new Dictionary<string, object> {
                ["source"] = source.Text, ["archive"] = directory.TrimEnd('/') + "/" + filename,
                ["password"] = password.Password, ["compression"] = compression.IsChecked == true
            };
            foreach (var filter in filters) options[filter.Key] = filter.Field.Text;
            if (dropped is { Length: > 0 })
                await Call("drop-upload", new { paths = dropped, directory, options, archive_name = dropped.Length == 1 ? filename : null });
            else await Call("backup", options);
            dialog.Close();
        }, true));
        dialog.ShowDialog();
        return Task.CompletedTask;
    }

    async Task Trash(int request)
    {
        var list = new Wpf.Ui.Controls.ListView { SelectionMode = SelectionMode.Extended, MinHeight = 300 };
        var columns = new Wpf.Ui.Controls.GridView();
        columns.Columns.Add(new Wpf.Ui.Controls.GridViewColumn { Header = "名称", Width = 300, MinWidth = 150, DisplayMemberBinding = new System.Windows.Data.Binding(nameof(Entry.DisplayName)) });
        columns.Columns.Add(new Wpf.Ui.Controls.GridViewColumn { Header = "原位置", Width = 150, DisplayMemberBinding = new System.Windows.Data.Binding(nameof(Entry.Origin)) });
        columns.Columns.Add(new Wpf.Ui.Controls.GridViewColumn { Header = "删除时间", Width = 155, DisplayMemberBinding = new System.Windows.Data.Binding(nameof(Entry.Deleted)) });
        list.View = columns;
        EnableExplorerSelection(list);

        var hint = Caption("回收站保留 7 天，可以恢复到原位置。");
        page.Children.Add(hint);
        var tools = Toolbar(page);
        tools.Children.Add(Action("刷新", Reload));
        tools.Children.Add(Action("恢复", Restore));
        tools.Children.Add(Action("彻底删除", Delete));
        tools.Children.Add(Action("清空回收站", async () =>
        {
            if (MessageBox.Show(this, "彻底删除回收站里的所有项目？", Title, MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
            await Call("trash-empty", new { });
            await Reload();
        }));
        list.ContextMenu = new ContextMenu();
        foreach (var (label, action) in new (string, Func<Task>)[] { ("恢复", Restore), ("彻底删除", Delete) })
        {
            var item = new MenuItem { Header = label };
            item.Click += async (_, _) => await Run(action);
            list.ContextMenu.Items.Add(item);
        }
        list.ContextMenuOpening += (_, e) => e.Handled = list.SelectedItems.Count == 0;
        list.PreviewKeyDown += async (_, e) =>
        {
            if (e.Key == Key.A && Keyboard.Modifiers == ModifierKeys.Control)
            {
                list.SelectAll();
                e.Handled = true;
                return;
            }
            Func<Task>? action = e.Key switch { Key.Delete => Delete, Key.F5 => Reload, _ => null };
            if (action == null) return;
            e.Handled = true;
            await Run(action);
        };
        page.Children.Add(list);
        await Reload();

        async Task Reload()
        {
            var result = await Call("trash-list", new { });
            if (request != revision) return;
            EndSelection();
            list.ItemsSource = Items(result).Select(x => new Entry(x)).ToArray();
            hint.Text = list.Items.Count == 0 ? "回收站为空。" : "回收站保留 7 天，可以恢复到原位置。";
        }

        async Task Restore()
        {
            foreach (var item in list.SelectedItems.Cast<Entry>().ToArray())
                await Call("trash-restore", new { batch = Text(item.Data, "batch"), name = item.Name });
            await Reload();
        }

        async Task Delete()
        {
            var items = list.SelectedItems.Cast<Entry>().Select(x => new { batch = Text(x.Data, "batch"), name = x.Name }).ToArray();
            if (items.Length == 0 || MessageBox.Show(this, "彻底删除选中项目？", Title, MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
            await Call("trash-delete", new { items });
            await Reload();
        }
    }

    void ShowJobs()
    {
        var jobs = new ListBox { ItemsSource = Items(state, "jobs").Select(x => new Entry(x)).ToArray(), MinHeight = 180 };
        var tools = Toolbar(page);
        tools.Children.Add(Action("新建任务", () =>
        {
            var fields = new StackPanel();
            var dialog = Dialog("新建自动备份", fields);
            var source = Folder(fields, "源文件夹", Text(Property(state, "example"), "source"));
            var mode = new ComboBox { ItemsSource = new[] { "定时备份", "实时备份" }, SelectedIndex = 0 };
            fields.Children.Add(mode);
            var interval = Field(fields, "间隔秒数（5–604800）", "60");
            var keep = Field(fields, "保留份数（1–100）", "5");
            fields.Children.Add(Action("保存任务", async () =>
            {
                if (!int.TryParse(interval.Text, out var period) || !int.TryParse(keep.Text, out var count))
                    throw new InvalidOperationException("间隔和保留份数须为整数。");
                await Call("job", new { mode = mode.SelectedIndex == 0 ? "schedule" : "watch", source = source.Text, output = directory, period, keep = count });
                dialog.Close();
                await Poll();
                await ShowPage(1);
            }, true));
            dialog.ShowDialog();
            return Task.CompletedTask;
        }, true));
        tools.Children.Add(Action("移除任务", async () =>
        {
            if (jobs.SelectedItem is not Entry job) return;
            await Call("remove", new { id = Text(job.Data, "id") });
            await Poll();
            await ShowPage(1);
        }));
        page.Children.Add(jobs);
    }

    FluentWindow Dialog(string title, StackPanel fields, double width = 420)
    {
        var dialog = new FluentWindow
        {
            Title = title, Owner = this, Width = width, MaxHeight = 720, SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false, ExtendsContentIntoTitleBar = true
        };
        var container = new DockPanel();
        var bar = new TitleBar { Title = "", ShowMinimize = false, ShowMaximize = false };
        DockPanel.SetDock(bar, Dock.Top);
        container.Children.Add(bar);
        fields.Margin = new Thickness(24, 4, 24, 24);
        fields.Children.Add(Heading(title));
        container.Children.Add(new ScrollViewer { Content = fields, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        dialog.Content = container;
        return dialog;
    }

    string? Prompt(string title, string label, string initial = "")
    {
        var fields = new StackPanel();
        var dialog = Dialog(title, fields);
        var input = Field(fields, label, initial);
        fields.Children.Add(Action("确定", () => { dialog.DialogResult = true; return Task.CompletedTask; }, true));
        return dialog.ShowDialog() == true ? input.Text.Trim() : null;
    }

    TextBox Folder(Panel parent, string label, string value)
    {
        var field = Field(parent, label, value);
        parent.Children.Add(Action("浏览文件夹…", () =>
        {
            var picker = new Microsoft.Win32.OpenFolderDialog();
            if (Directory.Exists(field.Text)) picker.InitialDirectory = field.Text;
            if (picker.ShowDialog(Window.GetWindow(field)) == true) field.Text = picker.FolderName;
            return Task.CompletedTask;
        }));
        return field;
    }

    Button Action(string label, Func<Task> action, bool primary = false)
    {
        var button = new Button { Content = label, Margin = new Thickness(0, 4, 7, 4), Appearance = primary ? ControlAppearance.Primary : ControlAppearance.Secondary };
        var symbol = label switch
        {
            "上传" or "开始上传" => SymbolRegular.ArrowUpload24,
            "下载" or "下载并还原" => SymbolRegular.ArrowDownload24,
            "刷新" => SymbolRegular.ArrowClockwise24,
            "上一级" => SymbolRegular.ArrowUp24,
            "新建文件夹" => SymbolRegular.FolderAdd24,
            "删除" or "彻底删除" or "清空回收站" => SymbolRegular.Delete24,
            "重命名" => SymbolRegular.Edit24,
            _ => SymbolRegular.Empty
        };
        if (symbol != SymbolRegular.Empty) button.Icon = new SymbolIcon { Symbol = symbol };
        button.Click += async (_, _) =>
        {
            button.IsEnabled = false;
            try { await Run(action); }
            finally { button.IsEnabled = true; }
        };
        return button;
    }

    async Task Run(Func<Task> action)
    {
        try { await action(); }
        catch (Exception error) { MessageBox.Show(this, error.Message, Title, MessageBoxButton.OK, MessageBoxImage.Warning); }
    }

    static WrapPanel Toolbar(Panel panel)
    {
        var bar = new WrapPanel { Margin = new Thickness(0, 6, 0, 8) };
        panel.Children.Add(bar);
        return bar;
    }

    static TextBlock Heading(string text) => new() { Text = text, FontSize = 25, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 14) };
    static TextBlock Caption(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 4) };
    static TextBox Field(Panel panel, string label, string text = "")
    {
        panel.Children.Add(Caption(label));
        var field = new TextBox { Text = text, Margin = new Thickness(0, 0, 0, 7) };
        panel.Children.Add(field);
        return field;
    }
    static PasswordBox Secret(Panel panel, string label)
    {
        panel.Children.Add(Caption(label));
        var field = new PasswordBox { Margin = new Thickness(0, 0, 0, 7) };
        panel.Children.Add(field);
        return field;
    }

    static void Detach(FrameworkElement element)
    {
        if (element.Parent is Panel panel) panel.Children.Remove(element);
        else if (element.Parent is ContentControl content) content.Content = null;
    }

    static JsonElement Property(JsonElement json, string key) => json.ValueKind == JsonValueKind.Object && json.TryGetProperty(key, out var value) ? value : default;
    static string Text(JsonElement json, string key) => Property(json, key).ToString() ?? "";
    static double Number(JsonElement json, string key) => Property(json, key) is { ValueKind: JsonValueKind.Number } value ? value.GetDouble() : 0;
    static bool Flag(JsonElement json, string key) => Property(json, key).ValueKind == JsonValueKind.True;
    static IEnumerable<JsonElement> Items(JsonElement json, string? key = null)
    {
        var collection = key == null ? json : Property(json, key);
        return collection.ValueKind == JsonValueKind.Array ? collection.EnumerateArray().ToArray() : [];
    }

    sealed class SelectionOutline(UIElement target) : Adorner(target)
    {
        static readonly Brush Fill = new SolidColorBrush(Color.FromArgb(38, 0, 103, 192));
        static readonly Pen Stroke = new(new SolidColorBrush(Color.FromRgb(0, 103, 192)), 1);
        public Rect Area { get; set; }
        protected override void OnRender(DrawingContext drawing)
        {
            IsHitTestVisible = false;
            drawing.PushClip(new RectangleGeometry(new Rect(RenderSize)));
            drawing.DrawRectangle(Fill, Stroke, Area);
            drawing.Pop();
        }
    }

    sealed class EditorOverlay : Adorner
    {
        readonly TextBox input;
        readonly double width;

        public EditorOverlay(UIElement target, TextBox input, double width) : base(target)
        {
            this.input = input;
            this.width = width;
            AddVisualChild(input);
        }

        protected override int VisualChildrenCount => 1;
        protected override Visual GetVisualChild(int index) => input;
        protected override Size MeasureOverride(Size constraint)
        {
            input.Measure(new Size(Math.Max(80, width - 12), AdornedElement.RenderSize.Height));
            return AdornedElement.RenderSize;
        }
        protected override Size ArrangeOverride(Size size)
        {
            input.Arrange(new Rect(6, 0, Math.Max(80, width - 12), size.Height));
            return size;
        }
    }

    sealed record Entry(JsonElement Data)
    {
        public string Name => Text(Data, "name");
        public string Path => Text(Data, "path");
        public bool Folder => Flag(Data, "folder");
        public string DisplayName => (Folder ? "📁  " : "📄  ") + Name;
        public string Size => Folder ? "—" : $"{Number(Data, "bytes") / 1024:N1} KB";
        public string Origin => Text(Data, "origin") is "." or "" ? "备份空间" : "备份空间 / " + Text(Data, "origin");
        public string Modified => FormatDate("modified");
        public string Deleted => FormatDate("deleted");
        string FormatDate(string field) => Number(Data, field) is var value && value > 0
            ? DateTimeOffset.FromUnixTimeSeconds((long)value).LocalDateTime.ToString("yyyy-MM-dd HH:mm") : "—";
        public override string ToString() => Name.Length > 0
            ? DisplayName
            : $"{(Text(Data, "mode") == "watch" ? "实时" : "定时")}  ·  {Text(Data, "source")}  ·  {Text(Data, "status")}";
    }
}
