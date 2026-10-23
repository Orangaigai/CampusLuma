using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
namespace CampusLuma {
    public static class ResultText {
        static readonly Dictionary<string,string> Messages=new Dictionary<string,string> {
                {"ALREADY_ONLINE","已经联网"},{"ONLINE_AFTER_AUTH","连接成功"},{"CAMPUS_NOT_VISIBLE","附近没有校园网，已跳过"},
                {"CREDENTIAL_NOT_SET","请填写账号密码"},{"LOGIN_REJECTED","账号或密码错误，请重新填写并保存"},
                {"LOGIN_BLOCKED_AFTER_REJECTION","请重新保存正确密码"},{"AUTH_TIME_RESTRICTED","学校尚未开放认证"},
                {"NODE_NOT_FOUND","缺少运行环境，请查看使用说明"},{"BROWSER_DEPENDENCIES_MISSING","缺少运行文件，请查看使用说明"},
                {"BROWSER_AUTH_ERROR","认证程序异常，请查看运行记录"},{"BROWSER_START_FAILED","浏览器未能启动，请查看运行记录"},{"UNKNOWN_RESULT","未识别的运行结果，请反馈问题"},{"PORTAL_TIMEOUT","认证网页响应超时"},
                {"CATCHUP_DISABLED","未开启登录后补连，已跳过"},{"CATCHUP_OUTSIDE_WINDOW","已超出补连时段，已跳过"},
                {"CATCHUP_ALREADY_HANDLED","该时段已执行，无需补连"},{"CATCHUP_STATE_UNAVAILABLE","补连记录无法读取，请手动连接并查看运行记录"},
                {"WIFI_STATUS_UNAVAILABLE","无法读取 Wi-Fi 状态，请查看运行记录"},{"WIFI_STATUS_UNRECOGNIZED","当前系统的 Wi-Fi 信息格式未识别，请反馈问题"},
                {"WIFI_SCAN_FAILED","无法搜索附近 Wi-Fi，请检查无线网络和系统权限"},{"WIFI_CONNECT_FAILED","校园 Wi-Fi 连接请求失败，请先在系统中连接一次"},
                {"WIFI_CONNECT_TIMEOUT","等待连接校园 Wi-Fi 超时"},{"WIFI_CHANGED_BEFORE_AUTH","认证前 Wi-Fi 已切换，已停止本次连接"},
                {"WIFI_CHANGED_DURING_AUTH","认证期间 Wi-Fi 已切换，未确认校园网恢复"},
                {"SETTINGS_OR_RUNTIME_ERROR","设置或运行异常，请核对信息"},{"RUN_SKIPPED","已跳过本次连接"},{"RECOVERY_FAILED","连接未成功"},
                {"CREDENTIAL_ACCOUNT_MISMATCH","账号已更改，请重新填写密码"},{"CREDENTIAL_OR_PROVIDER_ERROR","账号信息或认证程序异常，请重新保存密码"},
                {"CREDENTIAL_SCHOOL_MISMATCH","学校已更改，请重新填写账号密码"},
                {"DEVICE_LIMIT","在线设备已达学校上限"},{"LOGIN_FORM_NOT_FOUND","学校认证页面发生变化，请反馈问题"},
                {"SERVICE_REQUIRED","请选择本人已开通的运营商或校园网服务"},{"SERVICE_REJECTED","所选服务认证失败，请核对已开通的运营商"},
                {"SERVICE_MISMATCH","当前在线出口与所选运营商不一致"},{"SERVICE_UNAVAILABLE","网页中没有所选运营商，请反馈页面变化"},
                {"CAPTCHA_REQUIRED","学校要求验证码，请手动认证一次"},{"ACCOUNT_ARREARS","学校提示欠费、流量耗尽或套餐到期"},
                {"PORTAL_SESSION_OFFLINE","校园网显示在线，但外网仍未恢复"},{"OTHER_PORTAL_SESSION","检测到其他账号的网络会话，请手动核对"},
                {"CREDENTIAL_ENCODING_UNSUPPORTED","密码含当前门户编码不支持的字符"},{"CREDENTIAL_FORMAT_UNSUPPORTED","当前门户不接受密码中的分号"},
                {"CREDENTIAL_LENGTH_UNSUPPORTED","账号或密码超过当前网页登录框的长度限制"},{"AUTH_TRANSPORT_ERROR","认证请求中断，请稍后重试"},
                {"AUTH_DEPENDENCIES_MISSING","认证组件缺失，请重新安装依赖"},{"UNSUPPORTED_LOGIN_FORM","认证表单发生变化，请反馈问题"},
                {"PORTAL_UNREACHABLE","暂时无法访问学校认证入口"},{"PREFLIGHT_BUDGET_EXHAUSTED","限时内未找到可用认证入口"},
                {"PORTAL_VERSION_UNRECOGNIZED","当前认证页面与已适配版本不同，请反馈问题"},{"PORTAL_CONFIG_UNRECOGNIZED","当前门户配置发生变化，请反馈问题"},
                {"PORTAL_RESPONSE_UNRECOGNIZED","学校返回了未识别的认证结果"},{"CAMPUS_INTERFACE_REQUIRED","无法确认校园网网卡，请核对所选无线网卡"},
                {"PORTAL_ENDPOINT_CHANGED","当前认证服务器已改变，请反馈更新学校规则"},
                {"PORTAL_CONTEXT_MISSING","未取得本次校园网认证入口，请连接本校网络后重试"},{"SERVICE_SELECTION_AMBIGUOUS","网页运营商选项不明确，已停止操作"},
                {"PORTAL_VERSION_UNVERIFIED","校园网入口版本待核对，请运行试验包中的入口采集"},
                {"CAMPUS_IP_MISMATCH","认证页面与当前网卡地址不一致，请重新连接校园网"},{"UNTRUSTED_PORTAL","认证地址超出已核对范围"},
                {"UNTRUSTED_REDIRECT","认证跳转超出已核对范围，请反馈问题"},{"UNTRUSTED_FORM_ACTION","认证提交地址发生变化，请反馈问题"},
                {"UNKNOWN_SERVICE_VALUES","学校运营商选项发生变化，请反馈问题"},{"UNEXPECTED_FORM_METHOD","认证表单方式发生变化，请反馈问题"},
                {"AUTH_REDIRECT_UNSUPPORTED","认证跳转异常，本次不会重复提交密码"},{"SCHOOL_NOT_ENABLED","该学校尚待现场验收，暂未开放"},
                {"LOGIN_SUBMITTED_OFFLINE","已提交认证，但网络仍未恢复"},{"PROVIDER_TIMEOUT","本次连接超时"},{"PROVIDER_PROCESS_ERROR","认证程序运行失败"}
            };
        public static bool Known(string code) { return code!=null && Messages.ContainsKey(code); }
        public static string Describe(string code) { return Known(code)?Messages[code]:"连接未完成，请查看运行记录。"; }
        public static string ScheduleNotice(IDictionary<string,object> task,IDictionary<string,object> result,DateTime now) {
            if(task==null || !task.ContainsKey("Enabled") || !Object.Equals(task["Enabled"],true)) return null;
            long state=task.ContainsKey("State")?Convert.ToInt64(task["State"]):0;
            if(state==4) return "定时任务正在执行，请稍候。";
            DateTime recorded=RunJournal.Time(result,"Time"),lastTask=RunJournal.Time(task,"LastRun");
            long exit=task.ContainsKey("LastExitCode")?Convert.ToInt64(task["LastExitCode"]):0;
            if(lastTask.Year>=2010 && lastTask>recorded && exit!=0)
                return "上次定时："+lastTask.ToString("MM-dd HH:mm")+" 未正常完成（0x"+unchecked((uint)exit).ToString("X8")+"），请查看运行记录。";
            object raw; DateTime due=DateTime.MinValue;
            if(task.TryGetValue("Times",out raw) && raw is IEnumerable && !(raw is string))
                foreach(object item in (IEnumerable)raw) {
                    try { DateTime candidate=now.Date.AddMinutes(Schedule.Minute(Convert.ToString(item))); if(candidate<=now.AddMinutes(-5) && candidate>due) due=candidate; }
                    catch(ArgumentException) {}
                }
            if(due!=DateTime.MinValue && recorded<due)
                return "今天 "+due.ToString("HH:mm")+" 后没有执行记录。请确认当时已开机并登录；"+
                    (task.ContainsKey("CatchUpEnabled") && Object.Equals(task["CatchUpEnabled"],true)?"已开启登录后补连（限错过后 2 小时）。":"错过不会补跑。");
            return null;
        }
    }
}
