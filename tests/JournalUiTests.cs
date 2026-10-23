using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using CampusLuma;

public static class JournalUiTests {
    static readonly BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    [STAThread]
    public static void Main(string[] args) {
        string root=Path.GetFullPath(args[0]);Directory.CreateDirectory(root);Store.Root=root;
        var application=new Application();var desktop=new Desktop();var type=typeof(Desktop);
        type.GetMethod("Build",Private).Invoke(desktop,new object[]{true});
        var window=(Window)type.GetField("window",Private).GetValue(desktop);
        type.GetMethod("WatchResult",Private).Invoke(desktop,new object[0]);
        try {
            foreach(string code in new[]{"CAMPUS_NOT_VISIBLE","BROWSER_START_FAILED"}) {
                Store.Atomic(Path.Combine(root,"last-run.json"),Store.Json.Serialize(new Dictionary<string,object>{{"Time",DateTime.Now.ToString("o")},{"Code",code},{"Success",false}}));
                DateTime deadline=DateTime.Now.AddSeconds(3);bool received=false;
                do {
                    var frame=new DispatcherFrame();var timer=new DispatcherTimer { Interval=TimeSpan.FromMilliseconds(25) };
                    timer.Tick+=(s,e)=>{timer.Stop();frame.Continue=false;};timer.Start();Dispatcher.PushFrame(frame);
                    received=((TextBlock)window.FindName("LastResult")).Text.Contains(ResultText.Describe(code));
                } while(!received && DateTime.Now<deadline);
                if(!received) throw new Exception("Atomic file result did not reach WPF: "+code);
                Console.WriteLine("PASS native file watcher updates WPF: "+code);
            }
            ((TextBox)window.FindName("UsernameBox")).Text="fixture-ui-account";
            ((CheckBox)window.FindName("CatchUpBox")).IsChecked=true;
            var saved=(Settings)type.GetMethod("Collect",Private).Invoke(desktop,new object[0]);
            Store.Save(saved,"fixture-ui-password-not-real");
            var reopened=new Desktop();type.GetMethod("Build",Private).Invoke(reopened,new object[]{true});
            var reopenedWindow=(Window)type.GetField("window",Private).GetValue(reopened);
            if(((CheckBox)reopenedWindow.FindName("CatchUpBox")).IsChecked!=true)throw new Exception("Recovery option did not survive save and reopen.");
            reopenedWindow.Close();Console.WriteLine("PASS native checkbox save and reopen");
            ((CheckBox)window.FindName("CatchUpBox")).IsChecked=false;
            saved=(Settings)type.GetMethod("Collect",Private).Invoke(desktop,new object[0]);
            Store.Save(saved,"");
            if(Store.Load().CatchUpOnLogon)throw new Exception("Recovery option stayed enabled after saving off.");
            Console.WriteLine("PASS native checkbox disabling preserves existing credential");
        } finally { ((FileSystemWatcher)type.GetField("resultWatcher",Private).GetValue(desktop)).Dispose();window.Close();application.Shutdown(); }
    }
}
