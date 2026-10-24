using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CampusLuma;

public static class UiLayoutTests {
    static readonly BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    static readonly Type DesktopType=typeof(Desktop);
    static int passed;
    static void Check(bool condition,string description) { if(!condition)throw new Exception(description);passed++;Console.WriteLine("PASS "+description); }
    static object Call(Desktop desktop,string method,params object[] args) { return DesktopType.GetMethod(method,Private).Invoke(desktop,args); }
    static T Control<T>(Window window,string name) where T:class { return window.FindName(name) as T; }
    static void Layout(Window window) { window.UpdateLayout();window.Dispatcher.Invoke(DispatcherPriority.ApplicationIdle,new Action(()=>{}));window.UpdateLayout(); }
    static void Show(Window window) {
        window.ShowInTaskbar=false;window.ShowActivated=false;window.WindowStartupLocation=WindowStartupLocation.Manual;
        window.Left=-30000;window.Top=-30000;window.Show();Layout(window);
    }
    static Rect Bounds(Window window,FrameworkElement element) {
        return element.TransformToAncestor((Visual)window.Content).TransformBounds(new Rect(new Point(0,0),element.RenderSize));
    }
    static bool FooterVisible(Window window) {
        var root=(FrameworkElement)window.Content;
        return new[]{"EnableButton","PauseButton","ConnectButton"}.All(name=>{
            var button=Control<Button>(window,name);var bounds=Bounds(window,button);
            return bounds.Top>=0&&bounds.Bottom<=root.ActualHeight+1&&bounds.Left>=0&&bounds.Right<=root.ActualWidth+1&&bounds.Width>=85&&bounds.Height>=34;
        });
    }
    static bool HistoryActionsVisible(Window history) {
        var root=(FrameworkElement)history.Content;
        return new[]{"HistoryExportButton","HistoryCloseButton"}.All(name=>{var bounds=Bounds(history,Control<Button>(history,name));return bounds.Left>=0&&bounds.Top>=0&&bounds.Right<=root.ActualWidth&&bounds.Bottom<=root.ActualHeight;});
    }
    static void Capture(Window window,string path,double scale) {
        Layout(window);var root=(FrameworkElement)window.Content;
        var bitmap=new RenderTargetBitmap((int)Math.Ceiling(root.ActualWidth*scale),(int)Math.Ceiling(root.ActualHeight*scale),96*scale,96*scale,PixelFormats.Pbgra32);
        bitmap.Render(root);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using(var stream=File.Create(path))encoder.Save(stream);
    }
    [STAThread] public static int Main(string[] args) {
        var app=new Application { ShutdownMode=ShutdownMode.OnExplicitShutdown };
        Window window=null,history=null;
        try {
            string output=Path.GetFullPath(args[0]);Directory.CreateDirectory(output);Store.Root=Path.Combine(output,"state");Directory.CreateDirectory(Store.Root);
            var desktop=new Desktop();Call(desktop,"Build",true);window=(Window)DesktopType.GetField("window",Private).GetValue(desktop);Show(window);
            var scroll=Control<ScrollViewer>(window,"BodyScroll");
            Console.WriteLine("LAYOUT default: viewport="+scroll.ViewportHeight+", extent="+scroll.ExtentHeight+", scroll="+scroll.ScrollableHeight);
            Check(FooterVisible(window),"default window keeps all three actions fully visible");
            Check(scroll.ScrollableHeight<1,"default setup fits without a redundant vertical scrollbar");
            Check(new TextBoxAutomationPeer(Control<TextBox>(window,"UsernameBox")).GetName()=="账号","account input has its visible accessible label");
            Check(new ComboBoxAutomationPeer(Control<ComboBox>(window,"SchoolBox")).GetName()=="学校","school selector exposes its label");
            var combo=Control<ComboBox>(window,"SchoolBox");var peer=new ComboBoxAutomationPeer(combo);
            var expansion=(IExpandCollapseProvider)peer.GetPattern(PatternInterface.ExpandCollapse);
            expansion.Expand();Layout(window);
            Check(combo.IsDropDownOpen&&((Popup)combo.Template.FindName("PART_Popup",combo)).IsOpen,"restyled combo opens through the native automation pattern");
            expansion.Collapse();Check(!combo.IsDropDownOpen,"restyled combo closes through the native automation pattern");
            Capture(window,Path.Combine(output,"main.png"),1);Capture(window,Path.Combine(output,"main-150.png"),1.5);Capture(window,Path.Combine(output,"main-200.png"),2);

            Control<PasswordBox>(window,"PasswordBox").Password="fixture-ui-password-not-real";
            Control<ToggleButton>(window,"PasswordToggle").IsChecked=true;
            typeof(Window).GetMethod("OnDeactivated",Private).Invoke(window,new object[]{EventArgs.Empty});
            Check(Control<ToggleButton>(window,"PasswordToggle").IsChecked==false&&Control<TextBox>(window,"VisiblePasswordBox").Text==""&&Control<PasswordBox>(window,"PasswordBox").Password=="fixture-ui-password-not-real","deactivation masks and clears visible text without losing the typed password");
            Control<PasswordBox>(window,"PasswordBox").Clear();
            var chips=Control<WrapPanel>(window,"TimeChips");var first=(TextBox)((StackPanel)chips.Children[0]).Children[0];
            first.Text="24:00";
            Check((string)first.Tag=="Invalid"&&Control<TextBlock>(window,"PreviewText").Text.Contains("时间请用"),"invalid time is identified at its input and explained");
            first.Text="07:01";Control<Button>(window,"AddTimeButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            ((TextBox)((StackPanel)chips.Children[1]).Children[0]).Text="07:01";
            Check(chips.Children.Cast<StackPanel>().All(row=>(string)((TextBox)row.Children[0]).Tag=="Invalid"),"both duplicate time inputs are identified");
            ((Button)((StackPanel)chips.Children[1]).Children[1]).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(((TextBox)((StackPanel)chips.Children[0]).Children[0]).Tag==null,"removing a duplicate clears the remaining time error");

            Control<RadioButton>(window,"IntervalMode").IsChecked=true;
            Control<TextBox>(window,"StartBox").Text="22:00";Control<TextBox>(window,"EndBox").Text="02:00";Layout(window);
            Check(FooterVisible(window)&&Control<TextBlock>(window,"PreviewText").Text.Contains("00:00"),"cross-midnight mode retains preview and accessible actions");
            Console.WriteLine("LAYOUT interval: viewport="+scroll.ViewportHeight+", extent="+scroll.ExtentHeight+", scroll="+scroll.ScrollableHeight);
            Check(scroll.ScrollableHeight<1,"interval mode fits its instructions and status without clipping at the default size");
            Capture(window,Path.Combine(output,"interval.png"),1);
            Control<RadioButton>(window,"CustomMode").IsChecked=true;
            var many=Enumerable.Range(0,24).Select(hour=>hour.ToString("00")+":00").ToList();
            DesktopType.GetField("times",Private).SetValue(desktop,many);Call(desktop,"DrawTimes");Call(desktop,"UpdatePreview");
            window.Width=420;window.Height=460;Layout(window);
            var timeScroll=Control<ScrollViewer>(window,"TimeListScroll");
            Check(timeScroll.ScrollableHeight>0&&FooterVisible(window),"many times scroll independently while actions stay visible in a short window");
            Capture(window,Path.Combine(output,"compact.png"),1);
            Call(desktop,"Say","保存失败：这里是一段用于验证换行的测试提示。请核对时间与账号后重新保存；未保存的修改不会替换原计划。",true);Layout(window);
            scroll.ScrollToEnd();Layout(window);
            Check(Control<TextBlock>(window,"Toast").Visibility==Visibility.Visible&&FooterVisible(window)&&scroll.ScrollableWidth==0,"long errors wrap without hiding actions or creating horizontal scrolling");
            Capture(window,Path.Combine(output,"error.png"),1);
            Call(desktop,"Say","",false);
            Check(Control<TextBlock>(window,"Toast").Visibility==Visibility.Collapsed,"empty feedback does not reserve a blank message row");

            var report=RunJournal.Feedback(Store.Root,null,DateTime.Now);
            history=(Window)Call(desktop,"CreateHistoryWindow",report);Show(history);
            Check(Control<TextBlock>(history,"HistoryEmpty").Visibility==Visibility.Visible&&Control<ListBox>(history,"HistoryList").Items.Count==0,"history has a useful empty state");
            Capture(history,Path.Combine(output,"history-empty.png"),1);history.Close();history=null;
            foreach(var sample in new[]{
                new Dictionary<string,object>{{"Time",DateTime.Now.AddMinutes(-20).ToString("o")},{"RunId",Guid.NewGuid().ToString("N")},{"Code","ALREADY_ONLINE"},{"Success",true},{"Origin","Scheduled"},{"DurationMs",1800}},
                new Dictionary<string,object>{{"Time",DateTime.Now.AddMinutes(-10).ToString("o")},{"RunId",Guid.NewGuid().ToString("N")},{"Code","BROWSER_START_FAILED"},{"Success",false},{"ErrorCode","EDGE_PROCESS_CLOSED"},{"Origin","Manual"},{"DurationMs",20000}},
                new Dictionary<string,object>{{"Time",DateTime.Now.ToString("o")},{"RunId",Guid.NewGuid().ToString("N")},{"Code","ONLINE_AFTER_AUTH"},{"Success",true},{"AuthenticationAttempted",true},{"Origin","Scheduled"},{"DurationMs",8900}}
            }) RunJournal.Record(Store.Root,Store.Json.Serialize(sample));
            report=RunJournal.Feedback(Store.Root,null,DateTime.Now);history=(Window)Call(desktop,"CreateHistoryWindow",report);Show(history);
            var records=Control<ListBox>(history,"HistoryList");
            Check(records.Items.Count==3&&Control<TextBlock>(history,"HistoryEmpty").Visibility==Visibility.Collapsed,"history displays real sanitized records instead of the empty state");
            Check(HistoryActionsVisible(history),"history footer actions stay within the visible client area");
            Check(((string)((ListBoxItem)records.Items[0]).Tag).Contains("已提交认证")&&((string)((ListBoxItem)records.Items[2]).Tag).Contains("未提交密码"),"history preserves the distinction between password authentication and an existing connection");
            Capture(history,Path.Combine(output,"history.png"),1);
            history.Close();history=null;
            var legacy=new Dictionary<string,object>(report);legacy["Runs"]=new List<Dictionary<string,object>>();
            history=(Window)Call(desktop,"CreateHistoryWindow",legacy);Show(history);
            Check(Control<ListBox>(history,"HistoryList").Items.Count==1&&((List<Dictionary<string,object>>)legacy["Runs"]).Count==0,"legacy last result remains visible without mutating feedback history");
            history.Close();history=null;
            legacy["HistoryStatus"]="CORRUPT";
            var schedule=new Dictionary<string,object>{{"Enabled",true},{"CatchUpEnabled",true},{"NextRun","2026-10-25T07:01:00"},{"LastRun","2026-10-24T07:01:00"},{"LastExitCode",0}};
            DesktopType.GetField("scheduleSnapshot",Private).SetValue(desktop,schedule);legacy["Schedule"]=schedule;
            history=(Window)Call(desktop,"CreateHistoryWindow",legacy);Show(history);
            Check(Control<ListBox>(history,"HistoryList").Items.Count==1&&TextIn(history.Content as DependencyObject).Contains("历史记录暂时无法读取"),"unreadable history retains its warning when the last result is available");
            history.Width=420;history.Height=340;Control<Expander>(history,"HistoryDetails").IsExpanded=true;Layout(history);
            Check(HistoryActionsVisible(history),"expanded task details keep history actions visible in a compact window");
            File.WriteAllText(Path.Combine(output,"result.json"),Store.Json.Serialize(new Dictionary<string,object>{{"Passed",true},{"Checks",passed},{"RealNetworkChanged",false},{"TasksCreated",false},{"Scaling","synthetic 100/150/200 percent renders; no OS DPI changes"}}));
            Console.WriteLine("PASS UI layout and interaction checks: "+passed);return 0;
        } catch(Exception error) { Console.Error.WriteLine(error);return 1; }
        finally { if(history!=null)history.Close();if(window!=null)window.Close();app.Shutdown(); }
    }
    static string TextIn(DependencyObject root) {
        if(root==null)return "";
        var text=root as TextBlock;string result=text==null?"":text.Text;
        for(int index=0;index<VisualTreeHelper.GetChildrenCount(root);index++)result+="\n"+TextIn(VisualTreeHelper.GetChild(root,index));
        return result;
    }
}
