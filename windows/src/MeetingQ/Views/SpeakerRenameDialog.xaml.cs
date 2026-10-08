using CommunityToolkit.Mvvm.ComponentModel;
using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;

namespace MeetingQ.Views;

public partial class SpeakerRenameDialog : Window
{
    public partial class SpeakerRow : ObservableObject
    {
        [ObservableProperty] private string _oldName;
        [ObservableProperty] private string _newName;

        public SpeakerRow(string name)
        {
            _oldName = name;
            _newName = name;
        }
    }

    private readonly ObservableCollection<SpeakerRow> _rows = new();
    private readonly Func<string, string, Task<bool>> _rename;

    public SpeakerRenameDialog(IEnumerable<string> speakers, Func<string, string, Task<bool>> rename)
    {
        InitializeComponent();
        _rename = rename;
        foreach (var s in speakers)
            _rows.Add(new SpeakerRow(s));
        SpeakerRows.ItemsSource = _rows;
        EmptyHint.Visibility = _rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void Apply_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button btn || btn.DataContext is not SpeakerRow row) return;
        var newName = row.NewName.Trim();
        if (string.IsNullOrWhiteSpace(newName))
        {
            HintText.Text = "名称不能为空";
            return;
        }
        if (newName == row.OldName)
        {
            HintText.Text = "名称未变化，无需修改";
            return;
        }

        btn.IsEnabled = false;
        HintText.Text = string.Empty;
        try
        {
            var ok = await _rename(row.OldName, newName);
            if (!ok)
            {
                HintText.Text = "修正失败，请查看历史窗口状态栏";
                return;
            }

            // Merge: if another row already has this name, drop this row
            var existing = _rows.FirstOrDefault(r => r != row && r.OldName == newName);
            if (existing is not null)
            {
                _rows.Remove(row);
                existing.NewName = existing.OldName;
            }
            else
            {
                row.OldName = newName;
                row.NewName = newName;
            }
        }
        finally
        {
            btn.IsEnabled = true;
        }
    }

    private void Close_Click(object sender, RoutedEventArgs e) => Close();
}
