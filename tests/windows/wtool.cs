// Windows helper for the release test, built on the runner with the .NET Framework
// compiler (C# 5): see setup-runner.ps1. One exe, several commands:
//
//   wtool keys down|up|tap NAME     press or release a key the way a keyboard does (SendInput)
//   wtool keys chord ctrl+win+space press keys in order, release in reverse
//   wtool watch SECONDS             print key events a low-level keyboard hook sees
//   wtool target FILE               a window with a text box; its text is mirrored to FILE.
//                                   FILE.clear (created by the test) empties it.
//   wtool focus TITLE               bring the window with that title to the front
//   wtool windows PROCESS           visible top-level window titles of a process
//   wtool uia-text PROCESS          the text of every element in the process's windows
//   wtool uia-press PROCESS LABEL   invoke the first button whose name contains LABEL
//   wtool screenshot FILE           PNG of the whole screen
//   wtool speak-file FILE TEXT      synthesize TEXT (Windows' built-in voice) to a WAV file
//   wtool play FILE                 play a WAV on the default output and wait until it ends
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Automation;
using System.Windows.Forms;

static class WTool
{
    // ---- keyboard ---------------------------------------------------------------
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    struct INPUTUNION { [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public INPUTUNION u; }
    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);

    const uint KEYEVENTF_EXTENDEDKEY = 0x1, KEYEVENTF_KEYUP = 0x2;
    static readonly Dictionary<string, ushort> Vk = new Dictionary<string, ushort> {
        { "ctrl", 0xA2 }, { "win", 0x5B }, { "shift", 0xA0 }, { "alt", 0xA4 },
        { "space", 0x20 }, { "escape", 0x1B }, { "return", 0x0D }, { "tab", 0x09 },
        { "a", 0x41 }, { "v", 0x56 }, { "z", 0x5A }, { "delete", 0x2E },
    };

    static void Key(string name, bool down)
    {
        ushort vk;
        if (!Vk.TryGetValue(name, out vk)) throw new ArgumentException("unknown key: " + name);
        var input = new INPUT { type = 1 };
        input.u.ki.wVk = vk;
        input.u.ki.wScan = (ushort)MapVirtualKey(vk, 0);
        input.u.ki.dwFlags = (down ? 0 : KEYEVENTF_KEYUP) | (vk == 0x5B ? KEYEVENTF_EXTENDEDKEY : 0);
        if (SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT))) != 1)
            throw new Exception("SendInput failed: " + Marshal.GetLastWin32Error());
        Thread.Sleep(40);
    }

    // ---- low-level keyboard hook (what Blip's key listener uses) -----------------
    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, HookProc proc, IntPtr mod, uint thread);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
    static HookProc keepAlive;

    static void Watch(double seconds)
    {
        keepAlive = (code, wParam, lParam) => {
            if (code >= 0) {
                int vk = Marshal.ReadInt32(lParam);
                int flags = Marshal.ReadInt32(lParam, 8);
                Console.WriteLine("event msg=0x" + wParam.ToInt32().ToString("x") + " vk=0x" + vk.ToString("x") + " injected=" + ((flags & 0x10) != 0));
            }
            return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
        };
        if (SetWindowsHookEx(13, keepAlive, GetModuleHandle(null), 0) == IntPtr.Zero) { Console.WriteLine("HOOK_FAILED"); Environment.Exit(3); }
        Console.WriteLine("HOOK_READY");
        var timer = new System.Windows.Forms.Timer { Interval = (int)(seconds * 1000) };
        timer.Tick += (s, e) => Application.Exit();
        timer.Start();
        Application.Run();
    }

    // ---- target window -------------------------------------------------------------
    static void Target(string file)
    {
        var form = new Form { Text = "Blip Test Target", Width = 900, Height = 500, TopMost = true, StartPosition = FormStartPosition.CenterScreen };
        var box = new TextBox { Multiline = true, Dock = DockStyle.Fill, Font = new Font("Segoe UI", 14) };
        form.Controls.Add(box);
        File.WriteAllText(file, "");
        box.TextChanged += (s, e) => { try { File.WriteAllText(file, box.Text); } catch { } };
        var timer = new System.Windows.Forms.Timer { Interval = 200 };
        timer.Tick += (s, e) => {
            if (File.Exists(file + ".clear")) {
                try { File.Delete(file + ".clear"); } catch { }
                box.Clear();
                form.Activate();
                box.Focus();
            }
        };
        timer.Start();
        form.Shown += (s, e) => { form.Activate(); box.Focus(); };
        Application.Run(form);
    }

    // ---- windows and focus ---------------------------------------------------------
    delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);

    static List<KeyValuePair<IntPtr, string>> TopWindows(HashSet<uint> pids)
    {
        var found = new List<KeyValuePair<IntPtr, string>>();
        EnumWindows((hwnd, l) => {
            uint pid; GetWindowThreadProcessId(hwnd, out pid);
            if ((pids == null || pids.Contains(pid)) && IsWindowVisible(hwnd)) {
                var sb = new StringBuilder(512); GetWindowText(hwnd, sb, 512);
                if (sb.Length > 0) found.Add(new KeyValuePair<IntPtr, string>(hwnd, sb.ToString()));
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    static HashSet<uint> Pids(string process)
    {
        var set = new HashSet<uint>();
        foreach (var p in Process.GetProcessesByName(process)) set.Add((uint)p.Id);
        return set;
    }

    static void Focus(string title)
    {
        foreach (var w in TopWindows(null)) {
            if (w.Value.IndexOf(title, StringComparison.OrdinalIgnoreCase) < 0) continue;
            uint pid;
            uint fg = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
            uint me = GetCurrentThreadId();
            keybd_event(0xA4, 0, 0, IntPtr.Zero); keybd_event(0xA4, 0, 2, IntPtr.Zero); // Alt lifts the foreground lock
            AttachThreadInput(me, fg, true);
            ShowWindow(w.Key, 9);
            bool ok = SetForegroundWindow(w.Key);
            AttachThreadInput(me, fg, false);
            Console.WriteLine((ok ? "focused " : "focus refused ") + w.Value);
            return;
        }
        Console.WriteLine("no window titled " + title); Environment.Exit(2);
    }

    // ---- UI Automation (Electron exposes its page through it) ----------------------
    static IEnumerable<AutomationElement> Roots(string process)
    {
        var pids = Pids(process);
        foreach (var w in TopWindows(pids)) {
            AutomationElement el = null;
            try { el = AutomationElement.FromHandle(w.Key); } catch { }
            if (el != null) yield return el;
        }
    }

    static void UiaText(string process)
    {
        foreach (var root in Roots(process)) {
            Console.WriteLine("== window: " + root.Current.Name);
            AutomationElementCollection all;
            try { all = root.FindAll(TreeScope.Descendants, Condition.TrueCondition); } catch { continue; }
            foreach (AutomationElement e in all) {
                string text = "";
                try { text = e.Current.Name; } catch { }
                if (string.IsNullOrEmpty(text)) {
                    object vp;
                    if (e.TryGetCurrentPattern(ValuePattern.Pattern, out vp)) { try { text = ((ValuePattern)vp).Current.Value; } catch { } }
                }
                if (!string.IsNullOrEmpty(text)) Console.WriteLine(text);
            }
        }
    }

    static void UiaPress(string process, string label)
    {
        var buttons = new AndCondition(
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
            new PropertyCondition(AutomationElement.IsEnabledProperty, true));
        foreach (var root in Roots(process)) {
            AutomationElementCollection all;
            try { all = root.FindAll(TreeScope.Descendants, buttons); } catch { continue; }
            foreach (AutomationElement b in all) {
                string name = "";
                try { name = b.Current.Name ?? ""; } catch { }
                if (name.IndexOf(label, StringComparison.OrdinalIgnoreCase) < 0) continue;
                object ip;
                if (b.TryGetCurrentPattern(InvokePattern.Pattern, out ip)) {
                    ((InvokePattern)ip).Invoke();
                    Console.WriteLine("pressed \"" + name + "\" in " + root.Current.Name);
                    return;
                }
            }
        }
        Console.WriteLine("no button \"" + label + "\" in " + process); Environment.Exit(2);
    }

    static void Screenshot(string file)
    {
        var bounds = SystemInformation.VirtualScreen;
        using (var bmp = new Bitmap(bounds.Width, bounds.Height))
        using (var g = Graphics.FromImage(bmp)) {
            g.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bounds.Size);
            bmp.Save(file, ImageFormat.Png);
        }
    }

    [STAThread]
    static int Main(string[] a)
    {
        try {
            string cmd = a.Length > 0 ? a[0] : "";
            if (cmd == "keys" && a.Length == 3) {
                if (a[1] == "down") Key(a[2], true);
                else if (a[1] == "up") Key(a[2], false);
                else if (a[1] == "tap") { Key(a[2], true); Key(a[2], false); }
                else if (a[1] == "chord") {
                    var names = a[2].Split('+');
                    foreach (var n in names) Key(n, true);
                    Thread.Sleep(80);
                    for (int i = names.Length - 1; i >= 0; i--) Key(names[i], false);
                } else throw new ArgumentException("keys down|up|tap|chord");
            }
            else if (cmd == "watch" && a.Length == 2) Watch(double.Parse(a[1]));
            else if (cmd == "target" && a.Length == 2) Target(a[1]);
            else if (cmd == "focus" && a.Length == 2) Focus(a[1]);
            else if (cmd == "windows" && a.Length == 2) { foreach (var w in TopWindows(Pids(a[1]))) Console.WriteLine(w.Value); }
            else if (cmd == "uia-text" && a.Length == 2) UiaText(a[1]);
            else if (cmd == "uia-press" && a.Length == 3) UiaPress(a[1], a[2]);
            else if (cmd == "screenshot" && a.Length == 2) Screenshot(a[1]);
            else if (cmd == "speak-file" && a.Length == 3) {
                using (var s = new System.Speech.Synthesis.SpeechSynthesizer()) {
                    s.SetOutputToWaveFile(a[1]);
                    s.Speak(a[2]);
                }
            }
            else if (cmd == "play" && a.Length == 2) {
                using (var p = new System.Media.SoundPlayer(a[1])) p.PlaySync();
            }
            else { Console.Error.WriteLine("usage: see the header of wtool.cs"); return 2; }
            return 0;
        } catch (Exception e) {
            Console.Error.WriteLine(e.Message);
            return 1;
        }
    }
}
