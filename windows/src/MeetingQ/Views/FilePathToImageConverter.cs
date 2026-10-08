using System.Globalization;
using System.IO;
using System.Windows.Data;
using System.Windows.Media.Imaging;
using MeetingQ.ViewModels;

namespace MeetingQ.Views;

[ValueConversion(typeof(object), typeof(BitmapImage))]
public class FilePathToImageConverter : IValueConverter
{
    public object? Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        var path = value switch
        {
            string s                     => s,
            ScreenshotItem si => si.FilePath,
            _                            => null
        };
        if (path is null || !File.Exists(path)) return null;
        try
        {
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.UriSource   = new Uri(path);
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.DecodePixelWidth = 320; // thumbnail — avoid loading full-res into WrapPanel
            bmp.EndInit();
            bmp.Freeze();
            return bmp;
        }
        catch { return null; }
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
