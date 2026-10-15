using MeetingQ.Infrastructure;
using System.Diagnostics;
using System.Windows;
using System.Windows.Navigation;

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

    private void PrivacyLink_RequestNavigate(object sender, RequestNavigateEventArgs e)
    {
        var url = LocalizationManager.Instance.IsEnglish
            ? "https://clydris.com/meetingq/win/privacy#en"
            : "https://clydris.com/meetingq/win/privacy";
        Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        e.Handled = true;
    }
}
