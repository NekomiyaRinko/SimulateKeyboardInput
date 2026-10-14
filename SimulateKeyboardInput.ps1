param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('SimulateKeyboardInput.KeyboardInput' -as [type])) {
    $source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Drawing;

namespace SimulateKeyboardInput
{
    public sealed class Stroke
    {
        public ushort VirtualKey { get; private set; }
        public ushort ScanCode { get; private set; }
        public uint Flags { get; private set; }

        internal Stroke(ushort virtualKey, ushort scanCode, uint flags)
        {
            VirtualKey = virtualKey;
            ScanCode = scanCode;
            Flags = flags;
        }
    }

    public sealed class ShortcutConfiguration
    {
        public const uint ModifierAlt = 0x0001;
        public const uint ModifierControl = 0x0002;
        public const uint ModifierShift = 0x0004;

        public uint Modifiers { get; private set; }
        public uint VirtualKey { get; private set; }

        private static string SettingsPath
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "SimulateKeyboardInput",
                    "shortcut.conf");
            }
        }

        internal ShortcutConfiguration(uint modifiers, uint virtualKey)
        {
            if (!IsValid(modifiers, virtualKey))
                throw new ArgumentException("The shortcut must include a modifier and a non-modifier key.");
            Modifiers = modifiers;
            VirtualKey = virtualKey;
        }

        public static ShortcutConfiguration CreateDefault()
        {
            return new ShortcutConfiguration(ModifierControl | ModifierAlt, (uint)Keys.I);
        }

        public static ShortcutConfiguration Load()
        {
            return LoadFrom(SettingsPath);
        }

        public static ShortcutConfiguration LoadFrom(string path)
        {
            try
            {
                if (File.Exists(path))
                {
                    ShortcutConfiguration saved = Parse(File.ReadAllText(path));
                    if (saved != null)
                        return saved;
                }
            }
            catch
            {
                // A missing or unreadable settings file falls back to the default shortcut.
            }
            return CreateDefault();
        }

        public static ShortcutConfiguration Parse(string value)
        {
            if (String.IsNullOrWhiteSpace(value))
                return null;
            string[] parts = value.Trim().Split('|');
            uint modifiers;
            uint virtualKey;
            if (parts.Length != 2 ||
                !UInt32.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out modifiers) ||
                !UInt32.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out virtualKey) ||
                !IsValid(modifiers, virtualKey))
                return null;
            return new ShortcutConfiguration(modifiers, virtualKey);
        }

        public void Save()
        {
            SaveTo(SettingsPath);
        }

        public void SaveTo(string path)
        {
            if (String.IsNullOrWhiteSpace(path))
                throw new ArgumentException("A settings path is required.", "path");
            path = Path.GetFullPath(path);
            string directory = Path.GetDirectoryName(path);
            Directory.CreateDirectory(directory);
            string temporaryPath = path + ".tmp";
            try
            {
                string value = Modifiers.ToString(CultureInfo.InvariantCulture) + "|" +
                    VirtualKey.ToString(CultureInfo.InvariantCulture);
                File.WriteAllText(temporaryPath, value, new UTF8Encoding(false));
                if (File.Exists(path))
                    File.Replace(temporaryPath, path, null);
                else
                    File.Move(temporaryPath, path);
            }
            finally
            {
                if (File.Exists(temporaryPath))
                    File.Delete(temporaryPath);
            }
        }

        public string DisplayText()
        {
            List<string> parts = new List<string>();
            if ((Modifiers & ModifierControl) != 0)
                parts.Add("Ctrl");
            if ((Modifiers & ModifierAlt) != 0)
                parts.Add("Alt");
            if ((Modifiers & ModifierShift) != 0)
                parts.Add("Shift");
            parts.Add(((Keys)VirtualKey).ToString());
            return String.Join("+", parts.ToArray());
        }

        private static bool IsValid(uint modifiers, uint virtualKey)
        {
            uint validModifiers = ModifierAlt | ModifierControl | ModifierShift;
            if (modifiers == 0 || (modifiers & ~validModifiers) != 0 || virtualKey == 0 || virtualKey > 255)
                return false;

            Keys key = (Keys)virtualKey;
            return key != Keys.ControlKey && key != Keys.ShiftKey && key != Keys.Menu &&
                key != Keys.LControlKey && key != Keys.RControlKey &&
                key != Keys.LShiftKey && key != Keys.RShiftKey &&
                key != Keys.LMenu && key != Keys.RMenu;
        }
    }

    public static class KeyboardInput
    {
        public const uint KeyEventKeyUp = 0x0002;
        public const uint KeyEventUnicode = 0x0004;
        private const uint InputKeyboard = 1;
        private const ushort VkTab = 0x09;
        private const ushort VkReturn = 0x0D;
        private const int BatchSize = 512;

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeInput
        {
            public uint Type;
            public InputUnion Union;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct InputUnion
        {
            [FieldOffset(0)]
            public MouseData Mouse;

            [FieldOffset(0)]
            public KeyboardData Keyboard;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MouseData
        {
            public int X;
            public int Y;
            public uint MouseDataValue;
            public uint Flags;
            public uint Time;
            public UIntPtr ExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KeyboardData
        {
            public ushort VirtualKey;
            public ushort ScanCode;
            public uint Flags;
            public uint Time;
            public UIntPtr ExtraInfo;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint inputCount, NativeInput[] inputs, int inputSize);

        public static string ReadText(string path)
        {
            return DecodeBytes(File.ReadAllBytes(path));
        }

        public static string DecodeBytes(byte[] bytes)
        {
            if (bytes == null)
                throw new ArgumentNullException("bytes");

            if (StartsWith(bytes, 0xFF, 0xFE, 0x00, 0x00))
                return Encoding.UTF32.GetString(bytes, 4, bytes.Length - 4);
            if (StartsWith(bytes, 0x00, 0x00, 0xFE, 0xFF))
                return new UTF32Encoding(true, false, true).GetString(bytes, 4, bytes.Length - 4);
            if (StartsWith(bytes, 0xEF, 0xBB, 0xBF))
                return new UTF8Encoding(false, true).GetString(bytes, 3, bytes.Length - 3);
            if (StartsWith(bytes, 0xFF, 0xFE))
                return Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);
            if (StartsWith(bytes, 0xFE, 0xFF))
                return Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2);

            try
            {
                return new UTF8Encoding(false, true).GetString(bytes);
            }
            catch (DecoderFallbackException)
            {
                return Encoding.Default.GetString(bytes);
            }
        }

        private static bool StartsWith(byte[] bytes, params byte[] prefix)
        {
            if (bytes.Length < prefix.Length)
                return false;
            for (int i = 0; i < prefix.Length; i++)
            {
                if (bytes[i] != prefix[i])
                    return false;
            }
            return true;
        }

        public static List<Stroke> BuildStrokes(string text)
        {
            List<Stroke> result = new List<Stroke>();
            ForEachKey(text, delegate(ushort virtualKey, ushort scanCode, uint flags)
            {
                result.Add(new Stroke(virtualKey, scanCode, flags));
                result.Add(new Stroke(virtualKey, scanCode, flags | KeyEventKeyUp));
            });
            return result;
        }

        public static void SendText(string text)
        {
            List<NativeInput> batch = new List<NativeInput>(BatchSize);
            ForEachKey(text, delegate(ushort virtualKey, ushort scanCode, uint flags)
            {
                batch.Add(CreateInput(virtualKey, scanCode, flags));
                batch.Add(CreateInput(virtualKey, scanCode, flags | KeyEventKeyUp));
                if (batch.Count >= BatchSize)
                    SendBatch(batch);
            });
            SendBatch(batch);
        }

        public static bool SendTextWithInterval(string text, int intervalMilliseconds, Func<bool> cancellationRequested)
        {
            return ForEachCharacterWithInterval(text, intervalMilliseconds, cancellationRequested,
                delegate(char first, char second, int codeUnitCount)
            {
                List<NativeInput> inputs = new List<NativeInput>(4);
                if (first == '\r')
                {
                    AddKeyPair(inputs, VkReturn, 0, 0);
                }
                else if (first == '\t')
                {
                    AddKeyPair(inputs, VkTab, 0, 0);
                }
                else
                {
                    for (int i = 0; i < codeUnitCount; i++)
                    {
                        char current = i == 0 ? first : second;
                        AddKeyPair(inputs, 0, current, KeyEventUnicode);
                    }
                }

                SendBatch(inputs);
            },
                delegate(int milliseconds) { Thread.Sleep(milliseconds); });
        }

        private static bool ForEachCharacterWithInterval(string text, int intervalMilliseconds,
            Func<bool> cancellationRequested, Action<char, char, int> emitCharacter, Action<int> wait)
        {
            if (intervalMilliseconds < 1 || intervalMilliseconds > 1000)
                throw new ArgumentOutOfRangeException("intervalMilliseconds", "The character interval must be between 1 and 1000 milliseconds.");
            if (cancellationRequested == null)
                cancellationRequested = delegate { return false; };
            if (emitCharacter == null)
                throw new ArgumentNullException("emitCharacter");
            if (wait == null)
                throw new ArgumentNullException("wait");

            int sentCharacters = 0;
            return ForEachCharacter(text, delegate(char first, char second, int codeUnitCount)
            {
                if (cancellationRequested())
                    return false;
                if (sentCharacters > 0)
                {
                    wait(intervalMilliseconds);
                    if (cancellationRequested())
                        return false;
                }

                emitCharacter(first, second, codeUnitCount);
                sentCharacters++;
                return true;
            });
        }

        private static void AddKeyPair(List<NativeInput> inputs, ushort virtualKey, ushort scanCode, uint flags)
        {
            inputs.Add(CreateInput(virtualKey, scanCode, flags));
            inputs.Add(CreateInput(virtualKey, scanCode, flags | KeyEventKeyUp));
        }

        private static bool ForEachCharacter(string text, Func<char, char, int, bool> emit)
        {
            if (text == null)
                throw new ArgumentNullException("text");

            for (int i = 0; i < text.Length; i++)
            {
                char current = text[i];
                if (current == '\r')
                {
                    if (i + 1 < text.Length && text[i + 1] == '\n')
                        i++;
                    if (!emit('\r', '\0', 1))
                        return false;
                }
                else if (current == '\n')
                {
                    if (!emit('\r', '\0', 1))
                        return false;
                }
                else if (current == '\t')
                {
                    if (!emit('\t', '\0', 1))
                        return false;
                }
                else if (Char.IsHighSurrogate(current) && i + 1 < text.Length && Char.IsLowSurrogate(text[i + 1]))
                {
                    if (!emit(current, text[++i], 2))
                        return false;
                }
                else if (!emit(current, '\0', 1))
                {
                    return false;
                }
            }
            return true;
        }

        private static int CountLogicalCharacters(string text)
        {
            int count = 0;
            ForEachCharacter(text, delegate(char first, char second, int codeUnitCount)
            {
                count++;
                return true;
            });
            return count;
        }

        private static void ForEachKey(string text, Action<ushort, ushort, uint> emit)
        {
            if (text == null)
                throw new ArgumentNullException("text");

            for (int i = 0; i < text.Length; i++)
            {
                char current = text[i];
                if (current == '\r')
                {
                    if (i + 1 < text.Length && text[i + 1] == '\n')
                        i++;
                    emit(VkReturn, 0, 0);
                }
                else if (current == '\n')
                {
                    emit(VkReturn, 0, 0);
                }
                else if (current == '\t')
                {
                    emit(VkTab, 0, 0);
                }
                else
                {
                    emit(0, current, KeyEventUnicode);
                }
            }
        }

        private static NativeInput CreateInput(ushort virtualKey, ushort scanCode, uint flags)
        {
            NativeInput input = new NativeInput();
            input.Type = InputKeyboard;
            input.Union.Keyboard = new KeyboardData
            {
                VirtualKey = virtualKey,
                ScanCode = scanCode,
                Flags = flags,
                Time = 0,
                ExtraInfo = UIntPtr.Zero
            };
            return input;
        }

        private static void SendBatch(List<NativeInput> batch)
        {
            if (batch.Count == 0)
                return;

            NativeInput[] inputs = batch.ToArray();
            uint inserted = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(NativeInput)));
            if (inserted != inputs.Length)
            {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error,
                    "Windows did not accept all simulated keyboard input. The target may be elevated or may block injected input.");
            }
            batch.Clear();
        }

        public static string RunSelfTests()
        {
            int expectedInputSize = IntPtr.Size == 8 ? 40 : 28;
            Assert(Marshal.SizeOf(typeof(NativeInput)) == expectedInputSize,
                "Native INPUT structure has an unexpected size for this architecture.");

            List<Stroke> strokes = BuildStrokes("A\tB\r\nC\nD\rE");
            Assert(strokes.Count == 18, "CRLF must produce one Enter; LF and CR must each produce one Enter.");
            AssertKey(strokes, 0, 0, (ushort)'A', KeyEventUnicode);
            AssertKey(strokes, 1, VkTab, 0, 0);
            AssertKey(strokes, 2, 0, (ushort)'B', KeyEventUnicode);
            AssertKey(strokes, 3, VkReturn, 0, 0);
            AssertKey(strokes, 4, 0, (ushort)'C', KeyEventUnicode);
            AssertKey(strokes, 5, VkReturn, 0, 0);
            AssertKey(strokes, 6, 0, (ushort)'D', KeyEventUnicode);
            AssertKey(strokes, 7, VkReturn, 0, 0);
            AssertKey(strokes, 8, 0, (ushort)'E', KeyEventUnicode);

            string supplementaryCharacter = new string(new char[] { (char)0xD83D, (char)0xDE00 });
            List<Stroke> unicodeStrokes = BuildStrokes("A" + supplementaryCharacter + "Z");
            Assert(unicodeStrokes.Count == 8, "UTF-16 surrogate pairs must be preserved.");
            AssertKey(unicodeStrokes, 1, 0, 0xD83D, KeyEventUnicode);
            AssertKey(unicodeStrokes, 2, 0, 0xDE00, KeyEventUnicode);
            Assert(CountLogicalCharacters("A\tB\r\nC\nD\rE") == 9,
                "Tabs and line endings must each count as one delayed character.");
            Assert(CountLogicalCharacters("A" + supplementaryCharacter + "Z") == 3,
                "A surrogate pair must count as one delayed character.");
            int emittedCharacters = 0;
            List<int> requestedIntervals = new List<int>();
            bool intervalSendCompleted = ForEachCharacterWithInterval("A" + supplementaryCharacter + "B", 25,
                delegate { return false; },
                delegate(char first, char second, int codeUnitCount) { emittedCharacters++; },
                delegate(int milliseconds) { requestedIntervals.Add(milliseconds); });
            Assert(intervalSendCompleted && emittedCharacters == 3 && requestedIntervals.Count == 2 &&
                requestedIntervals[0] == 25 && requestedIntervals[1] == 25,
                "The configured delay must run exactly once between logical characters, not after the final character.");
            Assert(!SendTextWithInterval("A", 1, delegate { return true; }),
                "A cancellation request must stop before sending the first character.");
            bool invalidIntervalRejected = false;
            try
            {
                SendTextWithInterval("", 0, null);
            }
            catch (ArgumentOutOfRangeException)
            {
                invalidIntervalRejected = true;
            }
            Assert(invalidIntervalRejected, "Character intervals outside 1-1000 ms must be rejected.");

            string sample = "\u6587\u672c\t\u503c\r\n";
            Assert(DecodeBytes(Encoding.UTF8.GetBytes(sample)) == sample, "BOM-less UTF-8 decoding failed.");
            Assert(DecodeBytes(WithBom(Encoding.UTF8, sample)) == sample, "UTF-8 BOM decoding failed.");
            Assert(DecodeBytes(WithBom(Encoding.Unicode, sample)) == sample, "UTF-16 BOM decoding failed.");

            ShortcutConfiguration savedShortcut = ShortcutConfiguration.Parse("3|73");
            Assert(savedShortcut != null && savedShortcut.DisplayText() == "Ctrl+Alt+I",
                "Saved shortcut settings did not round-trip.");
            Assert(ShortcutConfiguration.Parse("0|73") == null,
                "A shortcut without a modifier must be rejected.");

            string temporarySettings = Path.Combine(Path.GetTempPath(),
                "SimulateKeyboardInput-selftest-" + Guid.NewGuid().ToString("N") + ".conf");
            try
            {
                savedShortcut.SaveTo(temporarySettings);
                ShortcutConfiguration updatedShortcut = new ShortcutConfiguration(
                    ShortcutConfiguration.ModifierControl | ShortcutConfiguration.ModifierShift,
                    (uint)Keys.K);
                updatedShortcut.SaveTo(temporarySettings);
                ShortcutConfiguration loadedShortcut = ShortcutConfiguration.LoadFrom(temporarySettings);
                Assert(loadedShortcut != null && loadedShortcut.DisplayText() == "Ctrl+Shift+K",
                    "Persisted shortcut settings did not survive a save and reload.");
            }
            finally
            {
                if (File.Exists(temporarySettings))
                    File.Delete(temporarySettings);
            }

            return "Self-test passed: native INPUT size, text decoding, Unicode, tabs, line endings, shortcut persistence, and character interval handling.";
        }

        private static byte[] WithBom(Encoding encoding, string text)
        {
            byte[] prefix = encoding.GetPreamble();
            byte[] content = encoding.GetBytes(text);
            byte[] result = new byte[prefix.Length + content.Length];
            Buffer.BlockCopy(prefix, 0, result, 0, prefix.Length);
            Buffer.BlockCopy(content, 0, result, prefix.Length, content.Length);
            return result;
        }

        private static void AssertKey(List<Stroke> strokes, int keyIndex, ushort virtualKey, ushort scanCode, uint flags)
        {
            int index = keyIndex * 2;
            Assert(strokes[index].VirtualKey == virtualKey, "Unexpected virtual key at index " + keyIndex + ".");
            Assert(strokes[index].ScanCode == scanCode, "Unexpected scan code at index " + keyIndex + ".");
            Assert(strokes[index].Flags == flags, "Unexpected key-down flags at index " + keyIndex + ".");
            Assert(strokes[index + 1].VirtualKey == virtualKey, "Unexpected key-up virtual key at index " + keyIndex + ".");
            Assert(strokes[index + 1].ScanCode == scanCode, "Unexpected key-up scan code at index " + keyIndex + ".");
            Assert(strokes[index + 1].Flags == (flags | KeyEventKeyUp), "Unexpected key-up flags at index " + keyIndex + ".");
        }

        private static void Assert(bool condition, string message)
        {
            if (!condition)
                throw new InvalidOperationException(message);
        }
    }

    public sealed class ShortcutDialog : Form
    {
        private readonly TextBox _captureBox;
        private readonly Label _messageLabel;
        private readonly Button _saveButton;

        public ShortcutConfiguration SelectedShortcut { get; private set; }

        public ShortcutDialog(ShortcutConfiguration current)
        {
            Text = "\u4fee\u6539\u5feb\u6377\u952e";
            ClientSize = new Size(430, 190);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterParent;
            KeyPreview = true;

            Label instruction = new Label();
            instruction.AutoSize = false;
            instruction.Location = new Point(20, 18);
            instruction.Size = new Size(390, 32);
            instruction.Text = "\u8bf7\u6309\u4e0b\u65b0\u7684\u5feb\u6377\u952e\u7ec4\u5408\uff08\u81f3\u5c11\u5305\u542b Ctrl\u3001Alt \u6216 Shift\uff09";

            _captureBox = new TextBox();
            _captureBox.ReadOnly = true;
            _captureBox.Location = new Point(20, 57);
            _captureBox.Size = new Size(390, 24);
            _captureBox.BackColor = SystemColors.Window;
            _captureBox.Text = current.DisplayText();

            _messageLabel = new Label();
            _messageLabel.AutoSize = false;
            _messageLabel.Location = new Point(20, 92);
            _messageLabel.Size = new Size(390, 30);
            _messageLabel.Text = "\u7b49\u5f85\u6309\u952e\u2026";

            _saveButton = new Button();
            _saveButton.Text = "\u4fdd\u5b58";
            _saveButton.Location = new Point(240, 140);
            _saveButton.Size = new Size(80, 28);
            _saveButton.Enabled = false;
            _saveButton.Click += delegate
            {
                if (SelectedShortcut != null)
                {
                    DialogResult = DialogResult.OK;
                    Close();
                }
            };

            Button cancelButton = new Button();
            cancelButton.Text = "\u53d6\u6d88";
            cancelButton.Location = new Point(330, 140);
            cancelButton.Size = new Size(80, 28);
            cancelButton.DialogResult = DialogResult.Cancel;

            Controls.Add(instruction);
            Controls.Add(_captureBox);
            Controls.Add(_messageLabel);
            Controls.Add(_saveButton);
            Controls.Add(cancelButton);
            CancelButton = cancelButton;
            Shown += delegate { _captureBox.Focus(); };
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                DialogResult = DialogResult.Cancel;
                Close();
                e.Handled = true;
                e.SuppressKeyPress = true;
                return;
            }

            if (IsModifierKey(e.KeyCode))
            {
                e.Handled = true;
                e.SuppressKeyPress = true;
                return;
            }

            uint modifiers = 0;
            if (e.Control)
                modifiers |= ShortcutConfiguration.ModifierControl;
            if (e.Alt)
                modifiers |= ShortcutConfiguration.ModifierAlt;
            if (e.Shift)
                modifiers |= ShortcutConfiguration.ModifierShift;

            if (modifiers == 0)
            {
                _messageLabel.Text = "\u8bf7\u81f3\u5c11\u4f7f\u7528 Ctrl\u3001Alt \u6216 Shift \u4e2d\u7684\u4e00\u4e2a\u4fee\u9970\u952e\u3002";
            }
            else
            {
                SelectedShortcut = new ShortcutConfiguration(modifiers, (uint)e.KeyCode);
                _captureBox.Text = SelectedShortcut.DisplayText();
                _messageLabel.Text = "\u6309\u201c\u4fdd\u5b58\u201d\u4f7f\u7528\u8be5\u5feb\u6377\u952e\u3002";
                _saveButton.Enabled = true;
            }

            e.Handled = true;
            e.SuppressKeyPress = true;
        }

        private static bool IsModifierKey(Keys key)
        {
            return key == Keys.ControlKey || key == Keys.ShiftKey || key == Keys.Menu ||
                key == Keys.LControlKey || key == Keys.RControlKey ||
                key == Keys.LShiftKey || key == Keys.RShiftKey ||
                key == Keys.LMenu || key == Keys.RMenu;
        }
    }

    public sealed class KeyboardForm : Form
    {
        private const int HotkeyId = 0x534B;
        private const int WmHotkey = 0x0312;
        private const uint ModNoRepeat = 0x4000;
        private const int VkControl = 0x11;
        private const int VkMenu = 0x12;
        private const int VkShift = 0x10;

        private readonly TextBox _pathBox;
        private readonly Label _hotkeyValueLabel;
        private readonly Label _statusLabel;
        private readonly CheckBox _intervalCheckBox;
        private readonly NumericUpDown _intervalMillisecondsInput;
        private string _selectedPath;
        private ShortcutConfiguration _shortcut;
        private bool _hotkeyRegistered;
        private bool _isSending;
        private volatile bool _cancelSending;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr windowHandle, int id, uint modifiers, uint virtualKey);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnregisterHotKey(IntPtr windowHandle, int id);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int virtualKey);

        public KeyboardForm()
        {
            _shortcut = ShortcutConfiguration.Load();
            Text = "\u6587\u4ef6\u8f6c\u952e\u76d8\u8f93\u5165";
            ClientSize = new Size(540, 225);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;

            Label fileLabel = new Label();
            fileLabel.AutoSize = true;
            fileLabel.Location = new Point(20, 22);
            fileLabel.Text = "\u6587\u672c\u6587\u4ef6";

            _pathBox = new TextBox();
            _pathBox.ReadOnly = true;
            _pathBox.Location = new Point(95, 18);
            _pathBox.Size = new Size(325, 24);
            _pathBox.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;

            Button browseButton = new Button();
            browseButton.Text = "\u9009\u62e9\u6587\u4ef6...";
            browseButton.Location = new Point(430, 17);
            browseButton.Size = new Size(90, 27);
            browseButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            browseButton.Click += BrowseForFile;

            Label hotkeyLabel = new Label();
            hotkeyLabel.AutoSize = true;
            hotkeyLabel.Location = new Point(20, 66);
            hotkeyLabel.Text = "\u5168\u5c40\u5feb\u6377\u952e";

            _hotkeyValueLabel = new Label();
            _hotkeyValueLabel.AutoSize = true;
            _hotkeyValueLabel.Location = new Point(120, 66);
            _hotkeyValueLabel.Text = _shortcut.DisplayText();

            Button changeShortcutButton = new Button();
            changeShortcutButton.Text = "\u4fee\u6539\u5feb\u6377\u952e";
            changeShortcutButton.Location = new Point(250, 61);
            changeShortcutButton.Size = new Size(115, 27);
            changeShortcutButton.Click += ChangeShortcut;

            _intervalCheckBox = new CheckBox();
            _intervalCheckBox.AutoSize = true;
            _intervalCheckBox.Location = new Point(20, 101);
            _intervalCheckBox.Text = "\u6309\u5b57\u7b26\u95f4\u9694\u8f93\u51fa";

            _intervalMillisecondsInput = new NumericUpDown();
            _intervalMillisecondsInput.Location = new Point(165, 98);
            _intervalMillisecondsInput.Size = new Size(65, 24);
            _intervalMillisecondsInput.Minimum = 1;
            _intervalMillisecondsInput.Maximum = 1000;
            _intervalMillisecondsInput.Value = 50;
            _intervalMillisecondsInput.Enabled = false;
            _intervalCheckBox.CheckedChanged += delegate
            {
                _intervalMillisecondsInput.Enabled = _intervalCheckBox.Checked;
            };

            Label intervalUnitLabel = new Label();
            intervalUnitLabel.AutoSize = true;
            intervalUnitLabel.Location = new Point(238, 102);
            intervalUnitLabel.Text = "\u6beb\u79d2 / \u5b57\u7b26\uff081\u20131000\uff09";

            Label instructions = new Label();
            instructions.AutoSize = false;
            instructions.Location = new Point(20, 137);
            instructions.Size = new Size(500, 40);
            instructions.Text = "\u5148\u9009\u62e9\u6587\u672c\u6587\u4ef6\uff0c\u518d\u5207\u6362\u5230\u76ee\u6807\u8f93\u5165\u4f4d\u7f6e\uff0c\u7136\u540e\u6309\u5feb\u6377\u952e\u3002";

            _statusLabel = new Label();
            _statusLabel.AutoSize = false;
            _statusLabel.Location = new Point(20, 190);
            _statusLabel.Size = new Size(500, 24);
            _statusLabel.Text = "\u7b49\u5f85\u9009\u62e9\u6587\u4ef6";

            Controls.Add(fileLabel);
            Controls.Add(_pathBox);
            Controls.Add(browseButton);
            Controls.Add(hotkeyLabel);
            Controls.Add(_hotkeyValueLabel);
            Controls.Add(changeShortcutButton);
            Controls.Add(_intervalCheckBox);
            Controls.Add(_intervalMillisecondsInput);
            Controls.Add(intervalUnitLabel);
            Controls.Add(instructions);
            Controls.Add(_statusLabel);
            FormClosing += delegate { _cancelSending = true; };
        }

        public static void Run()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new KeyboardForm());
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            if (RegisterShortcut(_shortcut))
                SetStatus("\u5feb\u6377\u952e\u5df2\u5c31\u7eea\uff08" + _shortcut.DisplayText() + "\uff09\uff1b\u8bf7\u9009\u62e9\u6587\u4ef6\u3002");
            else
                SetStatus("\u5feb\u6377\u952e\u6ce8\u518c\u5931\u8d25\uff08Windows \u9519\u8bef\u7801: " + Marshal.GetLastWin32Error() + "\uff09\uff0c\u53ef\u80fd\u5df2\u88ab\u5360\u7528\u3002");
        }

        protected override void OnHandleDestroyed(EventArgs e)
        {
            UnregisterCurrentShortcut();
            base.OnHandleDestroyed(e);
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == WmHotkey && message.WParam.ToInt32() == HotkeyId)
            {
                HandleHotkey();
                return;
            }
            base.WndProc(ref message);
        }

        private void BrowseForFile(object sender, EventArgs e)
        {
            using (OpenFileDialog dialog = new OpenFileDialog())
            {
                dialog.Title = "\u9009\u62e9\u8981\u8f93\u5165\u7684\u6587\u672c\u6587\u4ef6";
                dialog.Filter = "\u6587\u672c\u6587\u4ef6 (*.txt;*.text;*.md;*.csv;*.log)|*.txt;*.text;*.md;*.csv;*.log|\u6240\u6709\u6587\u4ef6 (*.*)|*.*";
                dialog.Multiselect = false;
                dialog.CheckFileExists = true;
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    _selectedPath = dialog.FileName;
                    _pathBox.Text = _selectedPath;
                    if (_hotkeyRegistered)
                        SetStatus("\u6587\u4ef6\u5df2\u9009\u4e2d\uff1b\u5207\u6362\u5230\u76ee\u6807\u7a97\u53e3\u540e\u6309 " + _shortcut.DisplayText() + "\u3002");
                    else
                        SetStatus("\u6587\u4ef6\u5df2\u9009\u4e2d\uff0c\u4f46\u5168\u5c40\u5feb\u6377\u952e\u4e0d\u53ef\u7528\u3002");
                }
            }
        }

        private bool RegisterShortcut(ShortcutConfiguration shortcut)
        {
            _hotkeyRegistered = RegisterHotKey(Handle, HotkeyId,
                shortcut.Modifiers | ModNoRepeat, shortcut.VirtualKey);
            return _hotkeyRegistered;
        }

        private void UnregisterCurrentShortcut()
        {
            if (_hotkeyRegistered)
            {
                UnregisterHotKey(Handle, HotkeyId);
                _hotkeyRegistered = false;
            }
        }

        private void ChangeShortcut(object sender, EventArgs e)
        {
            ShortcutConfiguration previous = _shortcut;
            UnregisterCurrentShortcut();
            bool saved = false;
            try
            {
                using (ShortcutDialog dialog = new ShortcutDialog(previous))
                {
                    if (dialog.ShowDialog(this) != DialogResult.OK)
                    {
                        SetStatus("\u5feb\u6377\u952e\u672a\u66f4\u6539\u3002");
                        return;
                    }

                    ShortcutConfiguration updated = dialog.SelectedShortcut;
                    if (!RegisterShortcut(updated))
                    {
                        int error = Marshal.GetLastWin32Error();
                        SetStatus("\u65b0\u5feb\u6377\u952e\u4e0d\u53ef\u7528\uff08Windows \u9519\u8bef\u7801: " + error + "\uff09\uff1b\u53ef\u80fd\u5df2\u88ab\u5360\u7528\u3002");
                        return;
                    }

                    try
                    {
                        updated.Save();
                    }
                    catch (Exception ex)
                    {
                        SetStatus("\u4fdd\u5b58\u5feb\u6377\u952e\u5931\u8d25\uff1a" + ex.Message);
                        return;
                    }

                    _shortcut = updated;
                    _hotkeyValueLabel.Text = _shortcut.DisplayText();
                    saved = true;
                    SetStatus("\u5feb\u6377\u952e\u5df2\u66f4\u65b0\u5e76\u4fdd\u5b58\u3002");
                }
            }
            catch (Exception ex)
            {
                SetStatus("\u8bbe\u7f6e\u5feb\u6377\u952e\u5931\u8d25\uff1a" + ex.Message);
            }
            finally
            {
                if (!saved)
                {
                    UnregisterCurrentShortcut();
                    _shortcut = previous;
                    _hotkeyValueLabel.Text = _shortcut.DisplayText();
                    if (!RegisterShortcut(previous))
                        SetStatus("\u65e0\u6cd5\u6062\u590d\u539f\u5feb\u6377\u952e\uff08Windows \u9519\u8bef\u7801: " + Marshal.GetLastWin32Error() + "\uff09\u3002");
                }
            }
        }

        private void HandleHotkey()
        {
            if (!_hotkeyRegistered)
                return;
            if (_isSending)
            {
                SetStatus("\u6b63\u5728\u9010\u5b57\u7b26\u8f93\u5165\uff0c\u8bf7\u7a0d\u5019\u3002");
                return;
            }
            if (String.IsNullOrEmpty(_selectedPath))
            {
                SetStatus("\u8bf7\u5148\u9009\u62e9\u6587\u672c\u6587\u4ef6\u3002");
                return;
            }

            string text;
            try
            {
                text = KeyboardInput.ReadText(_selectedPath);
            }
            catch (Exception ex)
            {
                SetStatus("\u8bfb\u53d6\u5931\u8d25\uff1a" + ex.Message);
                return;
            }

            if (text.Length == 0)
            {
                SetStatus("\u6587\u4ef6\u5185\u5bb9\u4e3a\u7a7a\u3002");
                return;
            }

            if (!WaitForHotkeyRelease())
            {
                SetStatus("\u8bf7\u5148\u677e\u5f00\u5feb\u6377\u952e\u540e\u91cd\u8bd5\u3002");
                return;
            }

            try
            {
                if (_intervalCheckBox.Checked)
                    StartIntervalSend(text, (int)_intervalMillisecondsInput.Value);
                else
                {
                    KeyboardInput.SendText(text);
                    SetStatus("\u8f93\u5165\u5b8c\u6210\u3002");
                }
            }
            catch (Exception ex)
            {
                SetStatus("\u8f93\u5165\u5931\u8d25\uff1a" + ex.Message);
            }
        }

        private void StartIntervalSend(string text, int intervalMilliseconds)
        {
            _isSending = true;
            _cancelSending = false;
            Thread worker = new Thread(delegate()
            {
                string finalStatus;
                try
                {
                    bool completed = KeyboardInput.SendTextWithInterval(text, intervalMilliseconds,
                        delegate { return _cancelSending; });
                    finalStatus = completed ? "\u8f93\u5165\u5b8c\u6210\u3002" : "\u8f93\u5165\u5df2\u53d6\u6d88\u3002";
                }
                catch (Exception ex)
                {
                    finalStatus = "\u8f93\u5165\u5931\u8d25\uff1a" + ex.Message;
                }

                if (!IsDisposed && IsHandleCreated)
                {
                    try
                    {
                        BeginInvoke(new MethodInvoker(delegate
                        {
                            _isSending = false;
                            SetStatus(finalStatus);
                        }));
                    }
                    catch (ObjectDisposedException)
                    {
                        // The form may be disposed while the background sender exits.
                    }
                    catch (InvalidOperationException)
                    {
                        // The form may be closing while the background sender exits.
                    }
                }
            });
            worker.IsBackground = true;
            try
            {
                worker.Start();
            }
            catch
            {
                _isSending = false;
                throw;
            }
            SetStatus("\u6b63\u5728\u9010\u5b57\u7b26\u8f93\u5165\u2026");
        }

        private bool WaitForHotkeyRelease()
        {
            DateTime deadline = DateTime.UtcNow.AddSeconds(2);
            while (DateTime.UtcNow < deadline)
            {
                bool controlDown = (_shortcut.Modifiers & ShortcutConfiguration.ModifierControl) != 0 &&
                    (GetAsyncKeyState(VkControl) & 0x8000) != 0;
                bool altDown = (_shortcut.Modifiers & ShortcutConfiguration.ModifierAlt) != 0 &&
                    (GetAsyncKeyState(VkMenu) & 0x8000) != 0;
                bool shiftDown = (_shortcut.Modifiers & ShortcutConfiguration.ModifierShift) != 0 &&
                    (GetAsyncKeyState(VkShift) & 0x8000) != 0;
                bool triggerDown = (GetAsyncKeyState((int)_shortcut.VirtualKey) & 0x8000) != 0;
                if (!controlDown && !altDown && !shiftDown && !triggerDown)
                {
                    Thread.Sleep(30);
                    return true;
                }
                Thread.Sleep(10);
            }
            return false;
        }

        private void SetStatus(string text)
        {
            _statusLabel.Text = text;
        }
    }
}
'@

    Add-Type -TypeDefinition $source -ReferencedAssemblies @(
        'System.Windows.Forms.dll',
        'System.Drawing.dll'
    )
}

if ($SelfTest) {
    [SimulateKeyboardInput.KeyboardInput]::RunSelfTests()
    exit 0
}

[SimulateKeyboardInput.KeyboardForm]::Run()
