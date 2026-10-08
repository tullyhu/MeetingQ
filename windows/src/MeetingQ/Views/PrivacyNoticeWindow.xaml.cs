using MeetingQ.Infrastructure;
using System.Windows;

namespace MeetingQ.Views;

public partial class PrivacyNoticeWindow : Window
{
    public PrivacyNoticeWindow() => InitializeComponent();

    private void AcceptButton_Click(object sender, RoutedEventArgs e)
    {
        SecureStorage.Save(SecureStorageKeys.PrivacyAccepted, "true");
        DialogResult = true;
        Close();
    }
}
