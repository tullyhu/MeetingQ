using System.Windows;
using System.Windows.Input;

namespace MeetingQ.Views;

public partial class QuickSummaryPopup : Window
{
    public event Action? RefreshRequested;

    public QuickSummaryPopup()
    {
        InitializeComponent();
        CenterOnScreen();
    }

    /// <summary>Shows skeleton UI immediately, then populates with full content once available.</summary>
    public void ShowSkeleton()
    {
        SkeletonPanel.Visibility = Visibility.Visible;
        ContentPanel.Visibility = Visibility.Collapsed;
        CopyButton.IsEnabled = false;
        Show();
        Activate();
    }

    public void ShowContent(string topic, string summary, string[] decisions,
                            string[]? actionItems = null)
    {
        TopicTextBlock.Text = topic;
        SummaryTextBlock.Text = summary;
        DecisionsItemsControl.ItemsSource = decisions;

        if (actionItems is { Length: > 0 })
        {
            ActionItemsHeader.Visibility   = Visibility.Visible;
            ActionItemsControl.ItemsSource = actionItems;
        }
        else
        {
            ActionItemsHeader.Visibility   = Visibility.Collapsed;
            ActionItemsControl.ItemsSource = null;
        }

        SkeletonPanel.Visibility = Visibility.Collapsed;
        ContentPanel.Visibility = Visibility.Visible;
        CopyButton.IsEnabled = true;
    }

    private void CenterOnScreen()
    {
        var workArea = SystemParameters.WorkArea;
        Left = (workArea.Width - Width) / 2 + workArea.Left;
        Top = (workArea.Height - Height) / 2 + workArea.Top;
    }

    private void TitleBar_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed)
            DragMove();
    }

    private void RefreshButton_Click(object sender, RoutedEventArgs e)
    {
        RefreshRequested?.Invoke();
    }

    private async void CopyButton_Click(object sender, RoutedEventArgs e)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine($"会议纪要 — {TopicTextBlock.Text}");
        sb.AppendLine();
        sb.AppendLine(SummaryTextBlock.Text);

        if (DecisionsItemsControl.ItemsSource is System.Collections.IEnumerable decisions)
        {
            var list = decisions.Cast<object>().Select(d => d.ToString()).Where(d => !string.IsNullOrWhiteSpace(d)).ToList();
            if (list.Count > 0)
            {
                sb.AppendLine();
                sb.AppendLine("决策：");
                foreach (var d in list) sb.AppendLine($"• {d}");
            }
        }

        if (ActionItemsControl.ItemsSource is System.Collections.IEnumerable actionItems)
        {
            var list = actionItems.Cast<object>().Select(a => a.ToString()).Where(a => !string.IsNullOrWhiteSpace(a)).ToList();
            if (list.Count > 0)
            {
                sb.AppendLine();
                sb.AppendLine("行动项：");
                foreach (var a in list) sb.AppendLine($"→ {a}");
            }
        }

        Clipboard.SetText(sb.ToString());

        CopyButton.IsEnabled = false;
        CopyButton.Content = "✓ 已复制";
        await Task.Delay(1500);
        CopyButton.Content = "📋 复制摘要";
        CopyButton.IsEnabled = true;
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e)
    {
        Hide();
    }

    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
            Hide();
    }
}
