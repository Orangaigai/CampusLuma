using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace CampusLuma {
    public sealed class Settings {
        public int Version = 1;
        public string Adapter = "xtu";
        public string School = "";
        public string Ssid = "";
        public string Interface = "WLAN";
        public string Portal = "";
        public string Username = "";
        public string Service = null;
        public string Mode = "custom";
        public string Start = "07:01";
        public string End = "23:00";
        public int IntervalMinutes = 120;
        public List<string> Times = new List<string> { "07:01" };
        public bool CatchUpOnLogon = false;
    }

    public static class Schedule {
        public static int Minute(string value) {
            DateTime result;
            if (value == null || value.Length != 5 || !DateTime.TryParseExact(value, "HH:mm",
                CultureInfo.InvariantCulture, DateTimeStyles.None, out result))
                throw new ArgumentException("时间请用两位小时和分钟，例如 07:01、18:30。");
            return result.Hour * 60 + result.Minute;
        }

        public static List<string> Expand(Settings settings) {
            var result = new SortedSet<int>();
            if (settings.Mode == "custom") {
                if (settings.Times == null || settings.Times.Count == 0)
                    throw new ArgumentException("请至少添加一个认证时间。");
                foreach (var time in settings.Times) result.Add(Minute(time));
            } else if (settings.Mode == "interval") {
                int start = Minute(settings.Start), end = Minute(settings.End);
                if (settings.IntervalMinutes < 5 || settings.IntervalMinutes > 1440)
                    throw new ArgumentException("间隔请设为 5 分钟至 24 小时。");
                // The end is inclusive when it falls on an interval. An earlier
                // end means the following day. Equal times mean one daily run.
                int duration = (end - start + 1440) % 1440;
                for (int offset = 0; offset <= duration; offset += settings.IntervalMinutes)
                    result.Add((start + offset) % 1440);
            } else throw new ArgumentException("不支持的时间模式。");
            // Windows Task Scheduler supports at most 48 triggers per task.
            // The installer splits this list into independent task batches.
            return result.Select(value => (value / 60).ToString("00") + ":" + (value % 60).ToString("00")).ToList();
        }

        public static DateTime Next(Settings settings, DateTime now) {
            return Expand(settings).Select(time => now.Date.AddMinutes(Minute(time)))
                .Select(time => time > now ? time : time.AddDays(1)).Min();
        }

        public static void Validate(Settings settings) {
            var school=SchoolRegistry.Load(settings.Adapter);
            if (String.IsNullOrWhiteSpace(settings.Ssid) || System.Text.Encoding.UTF8.GetByteCount(settings.Ssid) > 32 ||
                settings.Ssid.IndexOfAny(new[] { '\r', '\n', '"', '\0' }) >= 0)
                throw new ArgumentException("校园网名称不能为空、过长，或包含引号和换行。");
            if (String.IsNullOrWhiteSpace(settings.Interface) || settings.Interface.IndexOfAny(new[] { '\r', '\n', '"' }) >= 0)
                throw new ArgumentException("请填写有效的无线网卡名称，例如 WLAN、Wi-Fi。");
            if (!SchoolRegistry.Allows(school,settings.Portal))
                throw new ArgumentException("认证网址不在所选学校的可信地址中。");
            if (String.IsNullOrWhiteSpace(settings.Username)) throw new ArgumentException("请填写校园网账号。");
            var services=SchoolRegistry.Services(school);
            if (services.Length>0 && (settings.Service==null || !services.Any(item=>item.value==settings.Service)))
                throw new ArgumentException("请选择本人已开通的运营商或校园网服务。");
            Expand(settings);
        }
    }
}
