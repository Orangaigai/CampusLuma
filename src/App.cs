using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace CampusLuma {
    public sealed class Desktop {
        static readonly string Project=AppDomain.CurrentDomain.BaseDirectory;
        Window window;
        Settings loadedSettings;
        List<string> times=new List<string>();
        bool busy,scheduleEnabled,settingsDirty,passwordSyncing,serviceSyncing;
        string activeTimes="";
        bool rememberDataRoot;
        Dictionary<string,object> scheduleSnapshot;
        FileSystemWatcher resultWatcher;
        T Find<T>(string name) where T:class { return window.FindName(name) as T; }
        string Text(string name) { return Find<TextBox>(name).Text.Trim(); }
        void Say(string text,bool error=true) {
            var label=Find<TextBlock>("Toast"); label.Text=text;
            label.Foreground=(Brush)new BrushConverter().ConvertFromString(error?"#9B2525":"#666666");
        }

        [STAThread]
        public static void Main(string[] args) {
            try {
                int data=Array.IndexOf(args,"--data-directory");
                if(data>=0 && data+1<args.Length) Store.Root=Path.GetFullPath(args[data+1]);
                else Store.Root=Store.UserRoot();
                bool render=args.Contains("--render-preview"),smoke=args.Contains("--ui-test");
                var app=new Application(); var desktop=new Desktop(); desktop.rememberDataRoot=data<0; desktop.Build(render||smoke);
                if(render||smoke) {
                    if(smoke) desktop.SmokeTest();
                    if(args.Contains("--schedule-page") || args.Contains("--interval-mode")) desktop.Find<RadioButton>("IntervalMode").IsChecked=true;
                    if(args.Contains("--history-preview")) desktop.window=desktop.CreateHistoryWindow(RunJournal.Feedback(Store.Root,null,DateTime.Now));
                    int index=Array.IndexOf(args,"--output");
                    string output=index>=0 && index+1<args.Length?args[index+1]:Path.Combine(Project,"artifacts","simple-window.png");
                    desktop.Render(output);
                    if(smoke) Store.Atomic(Path.Combine(Path.GetDirectoryName(output),"ui-smoke-result.json"),"{\"Code\":\"SIMPLE_WINDOW_INTERACTIONS_VERIFIED\",\"Passed\":true}");
                    return;
                }
                app.Run(desktop.window);
            } catch(Exception error) {
                try { Store.Atomic(Store.FilePath("startup-error.txt"),error.GetType().Name+": "+error.Message); } catch {}
                MessageBox.Show("窗口未能启动："+error.Message,"校园网自动连接",MessageBoxButton.OK,MessageBoxImage.Error);
                Environment.ExitCode=1;
            }
        }

        void Build(bool preview) {
            if(!preview && rememberDataRoot && File.Exists(Store.FilePath("settings.json"))) Store.RememberRoot();
            using(var reader=File.OpenRead(Path.Combine(Project,"ui","MainWindow.xaml"))) window=(Window)XamlReader.Load(reader);
            try { loadedSettings=Store.Load(); }
            catch { loadedSettings=SchoolRegistry.Defaults(); Say("设置读取失败，请核对后重新保存。"); }
            var schools=SchoolRegistry.Available();
            var selected=schools.FirstOrDefault(item=>item.id==loadedSettings.Adapter);
            if(selected==null) throw new InvalidOperationException("已保存的学校尚未启用，请核对学校规则。");
            Find<ComboBox>("SchoolBox").ItemsSource=schools;Find<ComboBox>("SchoolBox").SelectedItem=selected;
            BindServices(selected,loadedSettings.Service);
            Find<ComboBox>("SchoolBox").SelectionChanged+=(sender,e)=>{
                var school=Find<ComboBox>("SchoolBox").SelectedItem as SchoolRule;
                if(school==null || school.id==loadedSettings.Adapter) return;
                SchoolRegistry.Apply(loadedSettings,school);Find<TextBox>("SsidBox").Text=school.defaultSsid;
                BindServices(school,null);
                Find<TextBox>("UsernameBox").Clear();
                passwordSyncing=true;Find<PasswordBox>("PasswordBox").Clear();Find<TextBox>("VisiblePasswordBox").Clear();passwordSyncing=false;
                Find<ToggleButton>("PasswordToggle").IsChecked=false;PasswordHint();
                UpdatePreview();MarkDirty();
            };
            if(Store.Development && !preview) window.Title+=Store.TrialSchool!=null?"（"+selected.name+"试验版）":"（开发版）";
            // Network adapter and portal details stay internal to the school
            // configuration. Choose an actual wireless adapter on this PC.
            var adapters=NetworkInterface.GetAllNetworkInterfaces().Where(item=>item.NetworkInterfaceType==NetworkInterfaceType.Wireless80211).ToList();
            if(adapters.Count>0 && !adapters.Any(item=>item.Name==loadedSettings.Interface))
                loadedSettings.Interface=(adapters.FirstOrDefault(item=>item.OperationalStatus==OperationalStatus.Up)??adapters[0]).Name;
            Find<TextBox>("SsidBox").Text=loadedSettings.Ssid;
            Find<TextBox>("UsernameBox").Text=loadedSettings.Username;
            Find<TextBox>("StartBox").Text=loadedSettings.Start;
            Find<TextBox>("EndBox").Text=loadedSettings.End;
            Find<TextBox>("HoursBox").Text=(loadedSettings.IntervalMinutes/60.0).ToString("0.####",CultureInfo.InvariantCulture);
            times=new List<string>(loadedSettings.Times??new List<string>());
            Find<CheckBox>("CatchUpBox").IsChecked=loadedSettings.CatchUpOnLogon;
            Find<CheckBox>("CatchUpBox").Checked+=(sender,e)=>MarkDirty();
            Find<CheckBox>("CatchUpBox").Unchecked+=(sender,e)=>MarkDirty();
            Find<RadioButton>(loadedSettings.Mode=="interval"?"IntervalMode":"CustomMode").IsChecked=true;
            Find<RadioButton>("CustomMode").Checked+=(sender,e)=>{ UpdatePreview(); MarkDirty(); };
            Find<RadioButton>("IntervalMode").Checked+=(sender,e)=>{ UpdatePreview(); MarkDirty(); };
            foreach(string field in new[]{"StartBox","EndBox","HoursBox"}) Find<TextBox>(field).TextChanged+=(sender,e)=>{ UpdatePreview(); MarkDirty(); };
            Find<TextBox>("SsidBox").TextChanged+=(sender,e)=>MarkDirty();
            Find<TextBox>("UsernameBox").TextChanged+=(sender,e)=>{ MarkDirty(); PasswordHint(); };
            Find<ComboBox>("ServiceBox").SelectionChanged+=(sender,e)=>{ if(!serviceSyncing) MarkDirty(); };
            Find<PasswordBox>("PasswordBox").PasswordChanged+=(sender,e)=>{
                if(passwordSyncing) return;
                if(Find<ToggleButton>("PasswordToggle").IsChecked==true) {
                    passwordSyncing=true; Find<TextBox>("VisiblePasswordBox").Text=Find<PasswordBox>("PasswordBox").Password; passwordSyncing=false;
                }
                MarkDirty(); PasswordHint();
            };
            Find<TextBox>("VisiblePasswordBox").TextChanged+=(sender,e)=>{
                if(passwordSyncing || Find<ToggleButton>("PasswordToggle").IsChecked!=true) return;
                passwordSyncing=true; Find<PasswordBox>("PasswordBox").Password=Find<TextBox>("VisiblePasswordBox").Text; passwordSyncing=false;
                MarkDirty(); PasswordHint();
            };
            Find<ToggleButton>("PasswordToggle").Checked+=(sender,e)=>PasswordVisibility(true);
            Find<ToggleButton>("PasswordToggle").Unchecked+=(sender,e)=>PasswordVisibility(false);
            Find<Button>("AddTimeButton").Click+=(sender,e)=>AddTime();
            Find<Button>("HistoryButton").Click+=async (sender,e)=>await Operate(async ()=>{
                try { await RefreshSchedule(); } catch { scheduleSnapshot=null; }
                var dialog=CreateHistoryWindow(RunJournal.Feedback(Store.Root,scheduleSnapshot,DateTime.Now));
                dialog.Owner=window; dialog.ShowDialog();
            });
            Find<Button>("EnableButton").Click+=async (sender,e)=>await Operate(async ()=>{ await Save(true); Say("已保存并启用。",false); });
            Find<Button>("PauseButton").Click+=async (sender,e)=>await Operate(async ()=>{
                RequireSuccess(await Script("schedule.ps1","-Action","Disable")); await RefreshSchedule();
            });
            Find<Button>("ConnectButton").Click+=async (sender,e)=>await Operate(async ()=>{
                await Save(false); Say("正在连接…",false);
                var reply=await Script("run-once.ps1"); ShowResult(reply); Say(Bool(reply,"Success")?"":Describe(Code(reply)));
            });
            DrawTimes(); UpdatePreview(); PasswordHint(); RefreshResult();
            if(!preview) {
                window.Loaded+=async (sender,e)=>await Operate(async ()=>{ await RefreshSchedule(); WatchResult(); });
                window.Closed+=(sender,e)=>{ if(resultWatcher!=null) resultWatcher.Dispose(); };
            }
        }

        void BindServices(SchoolRule rule,string selected) {
            serviceSyncing=true;
            var options=SchoolRegistry.Services(rule);
            var box=Find<ComboBox>("ServiceBox");box.ItemsSource=options;box.SelectedItem=options.FirstOrDefault(item=>selected!=null && item.value==selected);
            var visibility=options.Length>0?Visibility.Visible:Visibility.Collapsed;
            box.Visibility=visibility;Find<TextBlock>("ServiceLabel").Visibility=visibility;
            serviceSyncing=false;
        }
        Settings Collect() {
            int interval=loadedSettings.IntervalMinutes;
            if(Find<RadioButton>("IntervalMode").IsChecked==true) {
                double hours;
                if(!Double.TryParse(Text("HoursBox"),NumberStyles.Float,CultureInfo.InvariantCulture,out hours) || Double.IsNaN(hours) || Double.IsInfinity(hours) || hours<5.0/60 || hours>24)
                    throw new ArgumentException("间隔请输入 5 分钟至 24 小时对应的小时数，例如 0.5、2。");
                if(Math.Abs(hours*60-Math.Round(hours*60))>0.001) throw new ArgumentException("间隔最小为一分钟，可填写 0.5、1、2.5 小时。");
                interval=(int)Math.Round(hours*60);
            }
            var customTimes=times.Select(NormalizeTime).ToList();
            if(Find<RadioButton>("CustomMode").IsChecked==true) {
                foreach(string time in customTimes) Schedule.Minute(time);
                string duplicate=customTimes.GroupBy(value=>value).Where(group=>group.Count()>1).Select(group=>group.Key).FirstOrDefault();
                if(duplicate!=null) throw new ArgumentException("时间重复："+duplicate+"，请修改或删除。");
            }
            return new Settings { Adapter=loadedSettings.Adapter,School=loadedSettings.School,Portal=loadedSettings.Portal,Interface=loadedSettings.Interface,
                Ssid=Text("SsidBox"),Username=Text("UsernameBox"),Service=(Find<ComboBox>("ServiceBox").SelectedItem as ServiceRule)==null?null:((ServiceRule)Find<ComboBox>("ServiceBox").SelectedItem).value,
                Mode=Find<RadioButton>("IntervalMode").IsChecked==true?"interval":"custom",
                Start=Text("StartBox"),End=Text("EndBox"),IntervalMinutes=interval,Times=customTimes,CatchUpOnLogon=Find<CheckBox>("CatchUpBox").IsChecked==true };
        }

        static string NormalizeTime(string value) {
            value=(value??"").Trim().Replace('：',':'); DateTime parsed;
            return DateTime.TryParseExact(value,new[]{"H:m","H:mm","HH:m","HH:mm"},CultureInfo.InvariantCulture,DateTimeStyles.None,out parsed)?parsed.ToString("HH:mm"):value;
        }
        void AddTime() {
            var used=new HashSet<int>(); int last=7*60+1;
            foreach(string value in times) { try { last=Schedule.Minute(NormalizeTime(value)); used.Add(last); } catch(ArgumentException) {} }
            int start=times.Count==0?7*60+1:(last+60)%1440;
            for(int offset=0;offset<1440;offset++) {
                int minute=(start+offset)%1440;
                if(used.Contains(minute)) continue;
                times.Add((minute/60).ToString("00")+":"+(minute%60).ToString("00"));
                DrawTimes(); UpdatePreview(); MarkDirty(); Say("");
                var row=(StackPanel)Find<WrapPanel>("TimeChips").Children[times.Count-1];
                var editor=(TextBox)row.Children[0]; editor.Focus(); editor.SelectAll(); editor.BringIntoView();
                return;
            }
            Say("一天的所有时间都已添加。");
        }
        void DrawTimes() {
            var panel=Find<WrapPanel>("TimeChips"); panel.Children.Clear();
            for(int position=0;position<times.Count;position++) {
                int index=position;
                var row=new StackPanel { Orientation=Orientation.Horizontal,Margin=new Thickness(0,0,8,8) };
                var editor=new TextBox { Text=times[index],Width=74,MaxLength=5,ToolTip="连接时间（24 小时制）" };
                AutomationProperties.SetAutomationId(editor,"TimeBox"+index);
                AutomationProperties.SetName(editor,"连接时间 "+(index+1));
                var remove=new Button { Content="×",Width=26,Padding=new Thickness(0),Margin=new Thickness(6,0,0,0),ToolTip="删除这个时间" };
                AutomationProperties.SetAutomationId(remove,"RemoveTime"+index);
                editor.TextChanged+=(sender,e)=>{ if(panel.Children.Contains(row)) { times[index]=editor.Text; UpdatePreview(); MarkDirty(); Say(""); } };
                Action commit=()=>{ if(panel.Children.Contains(row)) editor.Text=NormalizeTime(editor.Text); };
                editor.LostKeyboardFocus+=(sender,e)=>commit();
                editor.PreviewKeyDown+=(sender,e)=>{ if(e.Key==Key.Enter) { commit(); e.Handled=true; } };
                remove.Click+=(sender,e)=>{ times.RemoveAt(index); DrawTimes(); UpdatePreview(); MarkDirty(); Say(""); };
                row.Children.Add(editor); row.Children.Add(remove); panel.Children.Add(row);
            }
        }

        void UpdatePreview() {
            bool custom=Find<RadioButton>("CustomMode").IsChecked==true;
            Find<StackPanel>("CustomPanel").Visibility=custom?Visibility.Visible:Visibility.Collapsed;
            Find<StackPanel>("IntervalPanel").Visibility=custom?Visibility.Collapsed:Visibility.Visible;
            try {
                var expanded=Schedule.Expand(Collect());
                Find<TextBlock>("PreviewText").Text="每天 "+String.Join("、",expanded.Take(5))+(expanded.Count>5?"等 "+expanded.Count+" 次":"，共 "+expanded.Count+" 次");
                Find<TextBlock>("PreviewText").Foreground=(Brush)new BrushConverter().ConvertFromString("#666666");
            } catch(Exception error) {
                Find<TextBlock>("PreviewText").Text=error.Message;
                Find<TextBlock>("PreviewText").Foreground=(Brush)new BrushConverter().ConvertFromString("#9B2525");
            }
        }

        async Task Save(bool enable) {
            var settings=Collect(); Schedule.Validate(settings);
            var current=await Script("schedule.ps1","-Action","Inspect"); RequireSuccess(current);
            bool apply=enable||Bool(current,"Enabled");
            string config=Store.FilePath("settings.json"),credential=Store.FilePath("credential.json");
            string oldConfig=File.Exists(config)?File.ReadAllText(config):null,oldCredential=File.Exists(credential)?File.ReadAllText(credential):null;
            Exception saveError=null;
            try {
                Store.Save(settings,Find<PasswordBox>("PasswordBox").Password);
                if(rememberDataRoot) Store.RememberRoot();
                if(apply) RequireSuccess(await Script("schedule.ps1","-Action","Apply"));
            } catch(Exception error) {
                bool restored=true;
                try { RestoreFile(config,oldConfig); } catch { restored=false; }
                try { RestoreFile(credential,oldCredential); } catch { restored=false; }
                string detail=error is UnauthorizedAccessException?"配置文件无法写入，请确认数据目录可写。":error.Message;
                saveError=new InvalidOperationException(restored?"保存失败，修改尚未生效。"+detail:"保存失败，部分设置未能恢复，请重试。"+detail,error);
            }
            if(saveError!=null) { MarkDirty(); try { await RefreshSchedule(); } catch {} throw saveError; }
            loadedSettings=settings; times=new List<string>(settings.Times); DrawTimes();
            passwordSyncing=true; Find<PasswordBox>("PasswordBox").Clear(); Find<TextBox>("VisiblePasswordBox").Clear(); passwordSyncing=false;
            Find<ToggleButton>("PasswordToggle").IsChecked=false;
            settingsDirty=false; PasswordHint(); await RefreshSchedule(); WatchResult();
        }
        static void RestoreFile(string path,string text) {
            if(text==null) { if(File.Exists(path)) File.Delete(path); }
            else if(!File.Exists(path) || File.ReadAllText(path)!=text) Store.Atomic(path,text);
        }
        void PasswordVisibility(bool visible) {
            var password=Find<PasswordBox>("PasswordBox"); var clear=Find<TextBox>("VisiblePasswordBox");
            passwordSyncing=true;
            if(visible) clear.Text=password.Password;
            password.Visibility=visible?Visibility.Collapsed:Visibility.Visible;
            clear.Visibility=visible?Visibility.Visible:Visibility.Collapsed;
            if(!visible) clear.Clear();
            passwordSyncing=false;
            var toggle=Find<ToggleButton>("PasswordToggle"); string label=visible?"隐藏密码":"显示密码";
            toggle.ToolTip=label; AutomationProperties.SetName(toggle,label);
            Find<System.Windows.Shapes.Line>("PasswordEyeSlash").Visibility=visible?Visibility.Visible:Visibility.Collapsed;
            if(visible) { clear.Focus(); clear.CaretIndex=clear.Text.Length; }
            else password.Focus();
        }
        void PasswordHint() {
            string hint="密码加密保存在本机。";
            try {
                var credential=Store.Credential();
                if(Find<PasswordBox>("PasswordBox").Password.Length>0) hint="保存后更新密码。";
                else if(credential!=null) hint=(credential.SchoolId??"xtu")!=loadedSettings.Adapter?"学校已更改，请重新填写账号密码。":
                    credential.Username==Text("UsernameBox")?"密码已保存，修改时间无需重填。":"账号已更改，请重新填写密码。";
            } catch { hint="密码读取失败，请重新输入后保存。"; }
            Find<TextBlock>("PasswordHint").Text=hint;
        }
        void MarkDirty() { settingsDirty=true; ScheduleLabel(); }
        void ScheduleLabel() {
            var label=Find<TextBlock>("ScheduleStatus");
            label.Text=settingsDirty?(scheduleEnabled?"原计划已启用，修改尚未保存":"修改尚未保存"):
                (scheduleEnabled?"已启用"+(String.IsNullOrEmpty(activeTimes)?"":"："+activeTimes):"尚未启用");
        }
        async Task RefreshSchedule() {
            var reply=await Script("schedule.ps1","-Action","Inspect"); RequireSuccess(reply); scheduleEnabled=Bool(reply,"Enabled");
            scheduleSnapshot=reply;
            activeTimes="";
            if(reply.ContainsKey("Times") && reply["Times"] is System.Collections.IEnumerable) {
                var actual=((System.Collections.IEnumerable)reply["Times"]).Cast<object>().Select(value=>Convert.ToString(value)).ToList();
                activeTimes=String.Join("、",actual.Take(5))+(actual.Count>5?" 等 "+actual.Count+" 次":"");
            }
            if(Bool(reply,"CatchUpEnabled")) activeTimes+="；登录后可补连";
            ScheduleLabel();
            string next=Value(reply,"NextRun");
            DateTime when;
            string display=String.IsNullOrEmpty(next)?"等待系统更新":next.Replace('T',' ');
            if(DateTime.TryParse(next,out when)) display=(when.Date==DateTime.Today?"今天 ":when.Date==DateTime.Today.AddDays(1)?"明天 ":when.ToString("yyyy-MM-dd "))+when.ToString("HH:mm");
            Find<TextBlock>("NextRunText").Text=scheduleEnabled?"下次连接："+display:"填写信息后，点击“保存并启用”。";
            RefreshResult();
        }
        void WatchResult() {
            if(resultWatcher!=null || !Directory.Exists(Store.Root)) return;
            resultWatcher=new FileSystemWatcher(Store.Root,"last-run.json") { NotifyFilter=NotifyFilters.LastWrite|NotifyFilters.FileName };
            FileSystemEventHandler update=(sender,e)=>{ if(!window.Dispatcher.HasShutdownStarted) window.Dispatcher.BeginInvoke(new Action(RefreshResult)); };
            resultWatcher.Changed+=update; resultWatcher.Created+=update; resultWatcher.EnableRaisingEvents=true;
            resultWatcher.Renamed+=(sender,e)=>update(sender,e);
        }
        void RefreshResult() {
            try {
                var result=Store.ReadResult();
                string notice=ResultText.ScheduleNotice(scheduleSnapshot,result,DateTime.Now);
                if(notice!=null) {
                    var label=Find<TextBlock>("LastResult"); label.Visibility=Visibility.Visible;
                    label.Text=notice;
                    label.Foreground=(Brush)new BrushConverter().ConvertFromString(notice.Contains("未正常完成")?"#9B2525":"#666666");
                } else if(result!=null) ShowResult(result);
            } catch {}
        }
        void ShowResult(Dictionary<string,object> reply) {
            var label=Find<TextBlock>("LastResult"); label.Visibility=Visibility.Visible;
            string time=Value(reply,"Time"); DateTime parsed;
            string when=DateTime.TryParse(time,out parsed)?parsed.ToString("MM-dd HH:mm"):"";
            label.Text="上次执行："+when+" "+Describe(Code(reply));
            label.Foreground=(Brush)new BrushConverter().ConvertFromString(!Bool(reply,"Success") && Code(reply)!="CAMPUS_NOT_VISIBLE" && Code(reply)!="RUN_SKIPPED"?"#9B2525":"#666666");
        }
        static string Describe(string code) { return ResultText.Describe(code); }
        Window CreateHistoryWindow(Dictionary<string,object> report) {
            var dialog=new Window { Title="运行记录",Width=540,Height=440,MinWidth=420,MinHeight=300,
                WindowStartupLocation=WindowStartupLocation.CenterOwner,Background=(Brush)new BrushConverter().ConvertFromString("#FAFAFA"),
                FontFamily=new FontFamily("Microsoft YaHei UI"),FontSize=12 };
            var panel=new DockPanel { Margin=new Thickness(16) };
            var actions=new StackPanel { Orientation=Orientation.Horizontal,HorizontalAlignment=HorizontalAlignment.Right,Margin=new Thickness(0,12,0,0) };
            var export=new Button { Content="导出反馈",Padding=new Thickness(12,5,12,5),Margin=new Thickness(0,0,8,0) };
            var close=new Button { Content="关闭",Padding=new Thickness(12,5,12,5) };
            actions.Children.Add(export);actions.Children.Add(close); DockPanel.SetDock(actions,Dock.Bottom);panel.Children.Add(actions);
            var note=new TextBlock { Text="仅保留最近 100 次。反馈不包含账号、密码、Wi-Fi 名称、IP、MAC、网页会话或本机路径。",TextWrapping=TextWrapping.Wrap,Foreground=Brushes.DimGray,Margin=new Thickness(0,0,0,10) };
            DockPanel.SetDock(note,Dock.Top);panel.Children.Add(note);
            var text=new StringBuilder();
            text.AppendLine("生成时间："+RunJournal.Time(report,"GeneratedAt").ToString("yyyy-MM-dd HH:mm:ss"));
            var task=(Dictionary<string,object>)report["Schedule"];
            if(scheduleSnapshot==null) text.AppendLine("计划状态：本次未取得，不能据此判断是否启用。");
            else {
                text.AppendLine("计划状态："+(Bool(task,"Enabled")?"已启用":"未启用"));
                text.AppendLine("登录后补连："+(Bool(task,"CatchUpEnabled")?"已启用，限错过后 2 小时":"未启用"));
                text.AppendLine("下次执行："+Value(task,"NextRun").Replace('T',' '));
                text.AppendLine("系统上次启动任务："+Value(task,"LastRun").Replace('T',' '));
                if(task.ContainsKey("LastExitCode")) text.AppendLine("系统返回码：0x"+unchecked((uint)Convert.ToInt64(task["LastExitCode"])).ToString("X8"));
            }
            text.AppendLine("系统返回码仅说明任务执行状态；联网结果以下方记录为准。");
            text.AppendLine();
            if(report.ContainsKey("LastRun")) AppendRun(text,(Dictionary<string,object>)report["LastRun"],"最近一次：");
            text.AppendLine();text.AppendLine("最近记录（新版本启用后开始累积）：");
            var runs=(List<Dictionary<string,object>>)report["Runs"];
            foreach(var run in runs.AsEnumerable().Reverse()) AppendRun(text,run,"");
            if(runs.Count==0) text.AppendLine("暂无记录。没有记录不能证明认证失败。");
            if(Value(report,"HistoryStatus")!="OK" && Value(report,"HistoryStatus")!="NOT_YET_RECORDED") text.AppendLine("记录文件暂时无法读取；本次反馈不包含历史记录。");
            var body=new TextBox { Text=text.ToString(),IsReadOnly=true,TextWrapping=TextWrapping.Wrap,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,Padding=new Thickness(10),Background=Brushes.White };
            panel.Children.Add(body);dialog.Content=panel;
            close.Click+=(s,e)=>dialog.Close();
            export.Click+=(s,e)=>{
                var picker=new Microsoft.Win32.SaveFileDialog { Title="保存脱敏反馈",FileName="校园网反馈-"+DateTime.Now.ToString("yyyyMMdd-HHmmss")+".json",Filter="反馈文件 (*.json)|*.json",DefaultExt=".json",AddExtension=true };
                if(picker.ShowDialog(dialog)!=true) return;
                try { Store.Atomic(picker.FileName,Store.Json.Serialize(report));export.Content="已导出"; }
                catch { MessageBox.Show(dialog,"无法保存，请选择可写入的文件夹。","运行记录",MessageBoxButton.OK,MessageBoxImage.Error); }
            };
            return dialog;
        }
        static void AppendRun(StringBuilder text,Dictionary<string,object> run,string prefix) {
            DateTime time=RunJournal.Time(run,"Time"); string code=Value(run,"Code");
            text.Append(prefix).Append(time==DateTime.MinValue?"时间未知":time.ToString("MM-dd HH:mm:ss")).Append("  ").Append(Describe(code));
            if(Value(run,"Origin")=="LogonCatchUp") text.Append("（登录后补连）");
            if(code=="ALREADY_ONLINE") text.Append("（认证前已联网，未提交密码）");
            else if(code=="ONLINE_AFTER_AUTH") text.Append(Bool(run,"AuthenticationAttempted")?"（已提交认证，并核实外网可用）":"（恢复后外网可用）");
            var startup=new Dictionary<string,string>{{"EDGE_NOT_FOUND","找不到 Edge"},{"EDGE_ACCESS_DENIED","浏览器启动被拒绝"},{"EDGE_STARTUP_TIMEOUT","浏览器启动超时"},{"EDGE_PROCESS_CLOSED","浏览器提前退出"},{"EDGE_STARTUP_ERROR","浏览器初始化异常"}};
            string detail=Value(run,"ErrorCode");if(startup.ContainsKey(detail)) text.Append("；").Append(startup[detail]);
            if(run.ContainsKey("WifiErrorCode")) text.Append("；系统网络错误码 ").Append(Value(run,"WifiErrorCode"));
            if(run.ContainsKey("StartupAttempts")) text.Append("；初始化 ").Append(Value(run,"StartupAttempts")).Append(" 次");
            if(run.ContainsKey("DurationMs")) text.Append("  ").Append((Convert.ToDouble(run["DurationMs"])/1000).ToString("0.0",CultureInfo.InvariantCulture)).Append(" 秒");
            text.AppendLine();
        }
        async Task Operate(Func<Task> action) {
            if(busy) return; busy=true; Say(""); SetEnabled(false);
            try { await action(); } catch(Exception error) { Say(error.Message); }
            finally { busy=false; SetEnabled(true); }
        }
        void SetEnabled(bool enabled) {
            foreach(string name in new[]{"EnableButton","PauseButton","ConnectButton","AddTimeButton","HistoryButton"}) Find<Button>(name).IsEnabled=enabled;
            foreach(string name in new[]{"SsidBox","UsernameBox","StartBox","EndBox","HoursBox"}) Find<TextBox>(name).IsEnabled=enabled;
            Find<PasswordBox>("PasswordBox").IsEnabled=enabled;
            Find<ComboBox>("SchoolBox").IsEnabled=enabled;
            Find<ComboBox>("ServiceBox").IsEnabled=enabled;
            Find<TextBox>("VisiblePasswordBox").IsEnabled=enabled; Find<ToggleButton>("PasswordToggle").IsEnabled=enabled;
            Find<RadioButton>("CustomMode").IsEnabled=enabled; Find<RadioButton>("IntervalMode").IsEnabled=enabled;
            Find<CheckBox>("CatchUpBox").IsEnabled=enabled;
            Find<WrapPanel>("TimeChips").IsEnabled=enabled;
        }
        static bool Bool(Dictionary<string,object> reply,string field) { return reply.ContainsKey(field)&&Convert.ToBoolean(reply[field],CultureInfo.InvariantCulture); }
        static string Value(Dictionary<string,object> reply,string field) { return reply.ContainsKey(field)?Convert.ToString(reply[field],CultureInfo.InvariantCulture):""; }
        static string Code(Dictionary<string,object> reply) { return Value(reply,"Code"); }
        static void RequireSuccess(Dictionary<string,object> reply) { if(Code(reply)=="SCHEDULE_ERROR" || Code(reply)=="PROCESS_ERROR") throw new InvalidOperationException("保存计划失败，原有设置已保留。"); }
        static string Quote(string value) {
            var result=new StringBuilder("\""); int slashes=0;
            foreach(char c in value) {
                if(c=='\\') { slashes++; continue; }
                if(c=='"') { result.Append('\\',slashes*2+1); result.Append(c); }
                else { result.Append('\\',slashes); result.Append(c); }
                slashes=0;
            }
            result.Append('\\',slashes*2); result.Append('"'); return result.ToString();
        }
        static async Task<Dictionary<string,object>> Script(string file,params string[] args) {
            return await Task.Run(async ()=>{
                string executable=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"System32","WindowsPowerShell","v1.0","powershell.exe");
                var list=new List<string>{"-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",Path.Combine(Project,"scripts",file),"-DataDirectory",Store.Root};
                if(file=="schedule.ps1") { list.Add("-TaskPrefix");list.Add(Store.TaskPrefix); }
                list.AddRange(args);
                using(var process=new Process()) {
                    process.StartInfo=new ProcessStartInfo(executable,String.Join(" ",list.Select(Quote))) { UseShellExecute=false,CreateNoWindow=true,
                        RedirectStandardOutput=true,RedirectStandardError=true,StandardOutputEncoding=Encoding.UTF8,StandardErrorEncoding=Encoding.UTF8,WorkingDirectory=Project };
                    process.Start(); var output=process.StandardOutput.ReadToEndAsync(); var errors=process.StandardError.ReadToEndAsync();
                    if(!process.WaitForExit(210000)) {
                        using(var killer=Process.Start(new ProcessStartInfo("taskkill.exe","/PID "+process.Id+" /T /F") { UseShellExecute=false,CreateNoWindow=true })) killer.WaitForExit(5000);
                        throw new TimeoutException("本次操作超时，请稍后重试。");
                    }
                    string stdout=await output; await errors;
                    string last=stdout.Split('\n').LastOrDefault(line=>line.TrimStart().StartsWith("{"));
                    return last==null?new Dictionary<string,object>{{"Code","PROCESS_ERROR"}}:Store.Json.Deserialize<Dictionary<string,object>>(last);
                }
            });
        }
        void Render(string path) {
            window.ShowInTaskbar=false; window.WindowStartupLocation=WindowStartupLocation.Manual;
            window.Left=-30000; window.Top=-30000; window.Show();
            window.Dispatcher.Invoke(DispatcherPriority.ApplicationIdle,new Action(()=>{}));
            var content=(FrameworkElement)window.Content; content.UpdateLayout();
            int width=(int)Math.Ceiling(content.ActualWidth+content.Margin.Left+content.Margin.Right),height=(int)Math.Ceiling(content.ActualHeight+content.Margin.Top+content.Margin.Bottom);
            var drawing=new DrawingVisual();
            using(var context=drawing.RenderOpen()) {
                context.DrawRectangle(Brushes.White,null,new Rect(0,0,width,height));
                var brush=new VisualBrush(content) { ViewboxUnits=BrushMappingMode.Absolute,Viewbox=new Rect(content.Margin.Left,content.Margin.Top,content.ActualWidth,content.ActualHeight) };
                context.DrawRectangle(brush,null,new Rect(content.Margin.Left,content.Margin.Top,content.ActualWidth,content.ActualHeight));
            }
            var bitmap=new RenderTargetBitmap(width,height,96,96,PixelFormats.Pbgra32); bitmap.Render(drawing);
            var encoder=new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))); using(var stream=File.Create(path)) encoder.Save(stream);
            window.Close();
        }
        void SmokeTest() {
            if(window.Width>500 || window.Height>680 || window.Title!="校园网自动连接") throw new Exception("Simple window size/title mismatch.");
            if(window.FindName("NavConnection")!=null || window.FindName("EnvironmentButton")!=null || window.FindName("InterfaceBox")!=null) throw new Exception("Advanced controls remain visible.");
            if(Find<Button>("HistoryButton")==null) throw new Exception("Run history entry is missing.");
            bool initialRecovery=loadedSettings.CatchUpOnLogon;
            Find<CheckBox>("CatchUpBox").IsChecked=true;
            if(!Collect().CatchUpOnLogon) throw new Exception("Logon recovery option was not collected.");
            Find<CheckBox>("CatchUpBox").IsChecked=false;
            if(Collect().CatchUpOnLogon) throw new Exception("Logon recovery option cannot be disabled.");
            Find<CheckBox>("CatchUpBox").IsChecked=initialRecovery;
            var originalTimes=new List<string>(times); times=new List<string>{"07:01"}; DrawTimes();
            Find<Button>("AddTimeButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            if(times.Count!=2 || times[1]!="08:01") throw new Exception("Plus must add an editable time without typing first.");
            var row=(StackPanel)Find<WrapPanel>("TimeChips").Children[1]; var editor=(TextBox)row.Children[0];
            editor.Text="7：30";
            if(Collect().Times[1]!="07:30") throw new Exception("Time edit/normalization failed.");
            editor.Text="07:01"; bool rejected=false;
            try { Collect(); } catch(ArgumentException) { rejected=true; }
            if(!rejected || !Find<TextBlock>("PreviewText").Text.Contains("重复")) throw new Exception("Duplicate time must be explained.");
            editor.Text="24:00";
            if(!Find<TextBlock>("PreviewText").Text.Contains("时间请用")) throw new Exception("Invalid time must be explained.");
            editor.Text="12:30"; ((Button)row.Children[1]).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            if(times.Count!=1 || times.Contains("12:30")) throw new Exception("Remove-time interaction failed.");
            row=(StackPanel)Find<WrapPanel>("TimeChips").Children[0]; ((Button)row.Children[1]).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Find<Button>("AddTimeButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            if(times.Count!=1 || times[0]!="07:01") throw new Exception("Adding to an empty list failed.");
            Find<RadioButton>("IntervalMode").IsChecked=true; Find<TextBox>("StartBox").Text="22:00"; Find<TextBox>("EndBox").Text="02:00";
            if(Schedule.Expand(Collect()).Count!=3 || Find<StackPanel>("IntervalPanel").Visibility!=Visibility.Visible) throw new Exception("Interval interaction failed.");
            Find<RadioButton>("CustomMode").IsChecked=true;
            if(Find<StackPanel>("CustomPanel").Visibility!=Visibility.Visible || String.IsNullOrEmpty(Collect().Portal) || String.IsNullOrEmpty(Collect().Interface)) throw new Exception("Hidden settings lost.");
            times=originalTimes; DrawTimes(); UpdatePreview();
            settingsDirty=false; ScheduleLabel();
            Say("");
        }
    }
}
