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
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Drawing;
using System.Drawing.Drawing2D;

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
            parts.Add(FormatKey((Keys)VirtualKey));
            return String.Join("+", parts.ToArray());
        }

        private static string FormatKey(Keys key)
        {
            int value = (int)key;
            if (value >= (int)Keys.D0 && value <= (int)Keys.D9)
                return ((char)('0' + value - (int)Keys.D0)).ToString();
            switch (value)
            {
                case 0xBA: return ";";
                case 0xBB: return "+";
                case 0xBC: return ",";
                case 0xBD: return "-";
                case 0xBE: return ".";
                case 0xBF: return "/";
                case 0xC0: return "`";
                case 0xDB: return "[";
                case 0xDC: return "\\";
                case 0xDD: return "]";
                case 0xDE: return "'";
                default: return key.ToString();
            }
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
        public const uint KeyEventExtended = 0x0001;
        public const uint KeyEventKeyUp = 0x0002;
        public const uint KeyEventUnicode = 0x0004;
        public const uint KeyEventScanCode = 0x0008;
        private const uint MapVirtualKeyToScanCodeEx = 4;
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

        [DllImport("user32.dll")]
        private static extern uint MapVirtualKey(uint virtualKey, uint mapType);

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

        public static bool SendTextCancellable(string text, Func<bool> cancellationRequested)
        {
            if (cancellationRequested == null)
                cancellationRequested = delegate { return false; };

            List<NativeInput> batch = new List<NativeInput>(BatchSize);
            bool completed = ForEachCharacter(text, delegate(char first, char second, int codeUnitCount)
            {
                if (cancellationRequested())
                    return false;

                if (first == '\r')
                    AddKeyPair(batch, VkReturn, 0, 0);
                else if (first == '\t')
                    AddKeyPair(batch, VkTab, 0, 0);
                else
                {
                    for (int i = 0; i < codeUnitCount; i++)
                    {
                        char current = i == 0 ? first : second;
                        AddKeyPair(batch, 0, current, KeyEventUnicode);
                    }
                }

                if (batch.Count >= BatchSize)
                    SendBatch(batch);
                return true;
            });
            if (!completed || cancellationRequested())
                return false;
            SendBatch(batch);
            return true;
        }

        public static void SendKeyChord(string chord)
        {
            List<Stroke> strokes = BuildKeyChordStrokes(chord);
            List<NativeInput> inputs = new List<NativeInput>(strokes.Count);
            for (int i = 0; i < strokes.Count; i++)
                inputs.Add(CreateInput(strokes[i].VirtualKey, strokes[i].ScanCode, strokes[i].Flags));
            SendBatch(inputs);
        }

        public static List<Stroke> BuildKeyChordStrokes(string chord)
        {
            List<Keys> keys = ManualProgramValidator.ParseKeyChord(chord);
            List<Stroke> strokes = new List<Stroke>(keys.Count * 2);
            for (int i = 0; i < keys.Count; i++)
                strokes.Add(BuildKeyStroke((ushort)keys[i], false));
            for (int i = keys.Count - 1; i >= 0; i--)
                strokes.Add(BuildKeyStroke((ushort)keys[i], true));
            return strokes;
        }

        private static Stroke BuildKeyStroke(ushort virtualKey, bool keyUp)
        {
            ushort extendedScanCode;
            if (TryGetExtendedScanCode(virtualKey, out extendedScanCode))
            {
                uint extendedFlags = KeyEventScanCode | KeyEventExtended;
                if (keyUp)
                    extendedFlags |= KeyEventKeyUp;
                return new Stroke(0, extendedScanCode, extendedFlags);
            }

            uint mappedScanCode = MapVirtualKey(virtualKey, MapVirtualKeyToScanCodeEx);
            uint prefix = mappedScanCode & 0xFF00;
            if (mappedScanCode != 0 && prefix == 0xE000)
            {
                uint flags = KeyEventScanCode | KeyEventExtended;
                if (keyUp)
                    flags |= KeyEventKeyUp;
                return new Stroke(0, (ushort)(mappedScanCode & 0xFF), flags);
            }

            uint virtualKeyFlags = IsExtendedVirtualKey(virtualKey) ? KeyEventExtended : 0;
            if (keyUp)
                virtualKeyFlags |= KeyEventKeyUp;
            return new Stroke(virtualKey, 0, virtualKeyFlags);
        }

        private static bool TryGetExtendedScanCode(ushort virtualKey, out ushort scanCode)
        {
            switch (virtualKey)
            {
                case 0x21: scanCode = 0x49; return true; // Page Up (E0 49)
                case 0x22: scanCode = 0x51; return true; // Page Down (E0 51)
                case 0x23: scanCode = 0x4F; return true; // End (E0 4F)
                case 0x24: scanCode = 0x47; return true; // Home (E0 47)
                case 0x25: scanCode = 0x4B; return true; // Left (E0 4B)
                case 0x26: scanCode = 0x48; return true; // Up (E0 48)
                case 0x27: scanCode = 0x4D; return true; // Right (E0 4D)
                case 0x28: scanCode = 0x50; return true; // Down (E0 50)
                case 0x2C: scanCode = 0x37; return true; // Print Screen (E0 37)
                case 0x2D: scanCode = 0x52; return true; // Insert (E0 52)
                case 0x2E: scanCode = 0x53; return true; // Delete (E0 53)
                case 0x5B: scanCode = 0x5B; return true; // Left Windows (E0 5B)
                case 0x5C: scanCode = 0x5C; return true; // Right Windows (E0 5C)
                case 0x5D: scanCode = 0x5D; return true; // Applications (E0 5D)
                case 0x6F: scanCode = 0x35; return true; // Keypad Divide (E0 35)
                case 0x90: scanCode = 0x45; return true; // Num Lock (E0 45)
                default:
                    scanCode = 0;
                    return false;
            }
        }

        private static bool IsExtendedVirtualKey(ushort virtualKey)
        {
            switch (virtualKey)
            {
                case 0x21: // Page Up
                case 0x22: // Page Down
                case 0x23: // End
                case 0x24: // Home
                case 0x25: // Left
                case 0x26: // Up
                case 0x27: // Right
                case 0x28: // Down
                case 0x2C: // Print Screen
                case 0x2D: // Insert
                case 0x2E: // Delete
                case 0x5B: // Left Windows
                case 0x5C: // Right Windows
                case 0x5D: // Applications
                case 0x6F: // Keypad Divide
                case 0x90: // Num Lock
                    return true;
                default:
                    return false;
            }
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

    [DataContract]
    public sealed class ManualProgram
    {
        [DataMember(Order = 1)]
        public int Version { get; set; }

        [DataMember(Order = 2)]
        public List<ManualBlock> Blocks { get; set; }

        public ManualProgram()
        {
            Version = 1;
            Blocks = new List<ManualBlock>();
        }
    }

    [DataContract]
    public sealed class ManualBlock
    {
        public const string Text = "text";
        public const string Key = "key";
        public const string Wait = "wait";
        public const string Loop = "loop";

        [DataMember(Order = 1)]
        public string Type { get; set; }

        [DataMember(Order = 2, EmitDefaultValue = false)]
        public string Value { get; set; }

        [DataMember(Order = 3, EmitDefaultValue = false)]
        public double Seconds { get; set; }

        [DataMember(Order = 4, EmitDefaultValue = false)]
        public int MaxIterations { get; set; }

        [DataMember(Order = 5, EmitDefaultValue = false)]
        public double MaxDurationSeconds { get; set; }

        [DataMember(Order = 6, EmitDefaultValue = false)]
        public List<ManualBlock> Children { get; set; }

        public ManualBlock()
        {
            Children = new List<ManualBlock>();
        }
    }

    public static class ManualProgramValidator
    {
        private const int MaximumBlocks = 1000;
        private const int MaximumDepth = 16;

        public static void Validate(ManualProgram program, bool forExecution)
        {
            if (program == null)
                throw new InvalidDataException("\u64cd\u4f5c\u6d41\u7a0b\u4e3a\u7a7a\u3002");
            if (program.Version != 1)
                throw new InvalidDataException("\u4e0d\u652f\u6301\u7684 JSON \u6d41\u7a0b\u7248\u672c\uff1a" + program.Version + "\u3002");
            if (program.Blocks == null)
                throw new InvalidDataException("JSON \u6d41\u7a0b\u7f3a\u5c11\u79ef\u6728\u5217\u8868\u3002");
            if (forExecution && program.Blocks.Count == 0)
                throw new InvalidDataException("\u8bf7\u5148\u6dfb\u52a0\u81f3\u5c11\u4e00\u4e2a\u64cd\u4f5c\u79ef\u6728\u3002");

            int blockCount = 0;
            ValidateBlocks(program.Blocks, 0, forExecution, ref blockCount);
        }

        private static void ValidateBlocks(List<ManualBlock> blocks, int depth, bool forExecution, ref int blockCount)
        {
            if (depth > MaximumDepth)
                throw new InvalidDataException("\u5faa\u73af\u5d4c\u5957\u4e0d\u80fd\u8d85\u8fc7 " + MaximumDepth + " \u5c42\u3002");

            for (int i = 0; i < blocks.Count; i++)
            {
                ManualBlock block = blocks[i];
                blockCount++;
                if (blockCount > MaximumBlocks)
                    throw new InvalidDataException("\u4e00\u4e2a\u6d41\u7a0b\u6700\u591a\u5305\u542b " + MaximumBlocks + " \u4e2a\u79ef\u6728\u3002");
                if (block == null)
                    throw new InvalidDataException("\u6d41\u7a0b\u4e2d\u5305\u542b\u7a7a\u79ef\u6728\u3002");

                if (block.Type == ManualBlock.Text)
                {
                    if (block.Value == null)
                        block.Value = String.Empty;
                    if (block.Value.Length > 100000)
                        throw new InvalidDataException("\u5355\u4e2a\u8f93\u5165\u5185\u5bb9\u4e0d\u80fd\u8d85\u8fc7 100000 \u4e2a\u5b57\u7b26\u3002");
                    if (forExecution && block.Value.Length == 0)
                        throw new InvalidDataException("\u8f93\u5165\u5185\u5bb9\u79ef\u6728\u4e0d\u80fd\u4e3a\u7a7a\u3002");
                    if (block.Children != null && block.Children.Count != 0)
                        throw new InvalidDataException("\u8f93\u5165\u5185\u5bb9\u79ef\u6728\u4e0d\u80fd\u5305\u542b\u5176\u4ed6\u79ef\u6728\u3002");
                }
                else if (block.Type == ManualBlock.Key)
                {
                    if (block.Value == null)
                        block.Value = String.Empty;
                    if (block.Value.Length > 100)
                        throw new InvalidDataException("\u6309\u952e\u7ec4\u5408\u5185\u5bb9\u8fc7\u957f\u3002");
                    if (forExecution || block.Value.Length > 0)
                    {
                        ParseKeyChord(block.Value);
                    }
                    if (block.Children != null && block.Children.Count != 0)
                        throw new InvalidDataException("\u6309\u952e\u79ef\u6728\u4e0d\u80fd\u5305\u542b\u5176\u4ed6\u79ef\u6728\u3002");
                }
                else if (block.Type == ManualBlock.Wait)
                {
                    if (Double.IsNaN(block.Seconds) || Double.IsInfinity(block.Seconds) ||
                        block.Seconds < 0.01 || block.Seconds > 3600)
                        throw new InvalidDataException("\u7b49\u5f85\u65f6\u95f4\u5fc5\u987b\u5728 0.01 \u5230 3600 \u79d2\u4e4b\u95f4\u3002");
                    if (block.Children != null && block.Children.Count != 0)
                        throw new InvalidDataException("\u7b49\u5f85\u79ef\u6728\u4e0d\u80fd\u5305\u542b\u5176\u4ed6\u79ef\u6728\u3002");
                }
                else if (block.Type == ManualBlock.Loop)
                {
                    if (block.MaxIterations < 0 || block.MaxIterations > 1000000)
                        throw new InvalidDataException("\u5faa\u73af\u6b21\u6570\u5fc5\u987b\u5728 0 \u5230 1000000 \u4e4b\u95f4\u3002");
                    if (Double.IsNaN(block.MaxDurationSeconds) || Double.IsInfinity(block.MaxDurationSeconds) ||
                        block.MaxDurationSeconds < 0 || block.MaxDurationSeconds > 86400)
                        throw new InvalidDataException("\u5faa\u73af\u8fd0\u884c\u65f6\u95f4\u5fc5\u987b\u5728 0 \u5230 86400 \u79d2\u4e4b\u95f4\u3002");
                    if (forExecution && block.MaxIterations == 0 && block.MaxDurationSeconds == 0)
                        throw new InvalidDataException("\u6bcf\u4e2a\u5faa\u73af\u81f3\u5c11\u8981\u8bbe\u7f6e\u5faa\u73af\u6b21\u6570\u6216\u6700\u957f\u8fd0\u884c\u65f6\u95f4\u3002");
                    if (forExecution && (block.Children == null || block.Children.Count == 0))
                        throw new InvalidDataException("\u5faa\u73af\u4f53\u4e0d\u80fd\u4e3a\u7a7a\uff0c\u8bf7\u5148\u628a\u79ef\u6728\u653e\u5165\u5faa\u73af\u4f53\u3002");
                    if (block.Children == null)
                        block.Children = new List<ManualBlock>();
                    ValidateBlocks(block.Children, depth + 1, forExecution, ref blockCount);
                }
                else
                    throw new InvalidDataException("\u9047\u5230\u4e0d\u652f\u6301\u7684\u79ef\u6728\u7c7b\u578b\u3002");
            }
        }

        public static List<Keys> ParseKeyChord(string value)
        {
            if (String.IsNullOrWhiteSpace(value))
                throw new InvalidDataException("\u8bf7\u586b\u5199\u6709\u6548\u7684\u6309\u952e\u6216\u7ec4\u5408\u952e\uff0c\u4f8b\u5982 Ctrl+C\u3002");

            string[] parts = value.Split('+');
            bool control = false;
            bool alt = false;
            bool shift = false;
            Keys mainKey = Keys.None;
            for (int i = 0; i < parts.Length; i++)
            {
                string part = parts[i].Trim();
                if (part.Length == 0)
                    throw new InvalidDataException("\u6309\u952e\u7ec4\u5408\u683c\u5f0f\u65e0\u6548\uff0c\u8bf7\u4f7f\u7528\u4f8b\u5982 Ctrl+Shift+A \u7684\u683c\u5f0f\u3002");
                if (String.Equals(part, "Ctrl", StringComparison.OrdinalIgnoreCase) ||
                    String.Equals(part, "Control", StringComparison.OrdinalIgnoreCase))
                {
                    if (control)
                        throw new InvalidDataException("\u6309\u952e\u7ec4\u5408\u4e2d\u4e0d\u80fd\u91cd\u590d Ctrl\u3002");
                    control = true;
                    continue;
                }
                if (String.Equals(part, "Alt", StringComparison.OrdinalIgnoreCase))
                {
                    if (alt)
                        throw new InvalidDataException("\u6309\u952e\u7ec4\u5408\u4e2d\u4e0d\u80fd\u91cd\u590d Alt\u3002");
                    alt = true;
                    continue;
                }
                if (String.Equals(part, "Shift", StringComparison.OrdinalIgnoreCase))
                {
                    if (shift)
                        throw new InvalidDataException("\u6309\u952e\u7ec4\u5408\u4e2d\u4e0d\u80fd\u91cd\u590d Shift\u3002");
                    shift = true;
                    continue;
                }

                Keys parsed;
                if (part.IndexOf(',') >= 0 || part.IndexOf('|') >= 0 ||
                    !Enum.TryParse<Keys>(part, true, out parsed) || parsed == Keys.None ||
                    !Enum.IsDefined(typeof(Keys), parsed) || (int)parsed < 1 || (int)parsed > 255 ||
                    (((int)parsed & (int)Keys.Modifiers) != 0) ||
                    parsed == Keys.ControlKey || parsed == Keys.ShiftKey || parsed == Keys.Menu ||
                    parsed == Keys.LControlKey || parsed == Keys.RControlKey ||
                    parsed == Keys.LShiftKey || parsed == Keys.RShiftKey ||
                    parsed == Keys.LMenu || parsed == Keys.RMenu || mainKey != Keys.None)
                    throw new InvalidDataException("\u65e0\u6cd5\u8bc6\u522b\u6309\u952e\u201c" + part + "\u201d\uff1b\u8bf7\u4f7f\u7528 A\u3001F1\u3001Enter\u3001Space \u7b49\u6309\u952e\u540d\u79f0\u3002");
                mainKey = parsed;
            }

            if (mainKey == Keys.None)
                throw new InvalidDataException("\u7ec4\u5408\u952e\u5fc5\u987b\u5305\u542b\u4e00\u4e2a\u975e\u4fee\u9970\u952e\u3002");

            List<Keys> result = new List<Keys>(4);
            if (control)
                result.Add(Keys.ControlKey);
            if (alt)
                result.Add(Keys.Menu);
            if (shift)
                result.Add(Keys.ShiftKey);
            result.Add(mainKey);
            return result;
        }
    }

    public static class ManualProgramStore
    {
        private const int MaximumJsonBytes = 1024 * 1024;

        private static DataContractJsonSerializer CreateSerializer()
        {
            return new DataContractJsonSerializer(typeof(ManualProgram),
                new DataContractJsonSerializerSettings { MaxItemsInObjectGraph = 10000 });
        }

        public static ManualProgram Load(string path)
        {
            if (String.IsNullOrWhiteSpace(path))
                throw new ArgumentException("JSON \u6587\u4ef6\u8def\u5f84\u4e0d\u80fd\u4e3a\u7a7a\u3002", "path");
            FileInfo info = new FileInfo(path);
            if (!info.Exists)
                throw new FileNotFoundException("\u627e\u4e0d\u5230 JSON \u6d41\u7a0b\u6587\u4ef6\u3002", path);
            if (info.Length > MaximumJsonBytes)
                throw new InvalidDataException("JSON \u6d41\u7a0b\u6587\u4ef6\u4e0d\u80fd\u8d85\u8fc7 1 MB\u3002");

            ManualProgram program;
            using (FileStream stream = File.OpenRead(path))
                program = CreateSerializer().ReadObject(stream) as ManualProgram;
            ManualProgramValidator.Validate(program, false);
            return program;
        }

        public static void Save(string path, ManualProgram program)
        {
            if (String.IsNullOrWhiteSpace(path))
                throw new ArgumentException("JSON \u6587\u4ef6\u8def\u5f84\u4e0d\u80fd\u4e3a\u7a7a\u3002", "path");
            ManualProgramValidator.Validate(program, false);
            byte[] bytes;
            using (MemoryStream stream = new MemoryStream())
            {
                CreateSerializer().WriteObject(stream, program);
                bytes = stream.ToArray();
            }
            if (bytes.Length > MaximumJsonBytes)
                throw new InvalidDataException("JSON \u6d41\u7a0b\u6587\u4ef6\u4e0d\u80fd\u8d85\u8fc7 1 MB\u3002");

            path = Path.GetFullPath(path);
            string directory = Path.GetDirectoryName(path);
            Directory.CreateDirectory(directory);
            string temporaryPath = null;
            try
            {
                for (int attempt = 0; attempt < 10 && temporaryPath == null; attempt++)
                {
                    string candidate = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                    FileStream temporaryStream;
                    try
                    {
                        temporaryStream = new FileStream(candidate, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                    }
                    catch (IOException)
                    {
                        if (File.Exists(candidate))
                            continue;
                        throw;
                    }

                    temporaryPath = candidate;
                    using (temporaryStream)
                        temporaryStream.Write(bytes, 0, bytes.Length);
                }
                if (temporaryPath == null)
                    throw new IOException("Could not create a unique temporary file for the JSON flow.");
                if (File.Exists(path))
                    File.Replace(temporaryPath, path, null);
                else
                    File.Move(temporaryPath, path);
                temporaryPath = null;
            }
            finally
            {
                if (temporaryPath != null && File.Exists(temporaryPath))
                    File.Delete(temporaryPath);
            }
        }
    }

    public static class ManualProgramRunner
    {
        private enum SignalKind { Completed, Cancelled, LoopTimeLimit }

        private sealed class LoopContext
        {
            public ManualBlock Block;
            public double StartedAt;
        }

        private sealed class RunSignal
        {
            public SignalKind Kind;
            public LoopContext Context;
        }

        private static readonly RunSignal Completed = new RunSignal { Kind = SignalKind.Completed };
        private static readonly RunSignal Cancelled = new RunSignal { Kind = SignalKind.Cancelled };

        public static bool Run(ManualProgram program, Func<string, Func<bool>, bool> sendText,
            Action<string> sendKey, Func<bool> cancellationRequested, Action<int> wait)
        {
            return Run(program, sendText, sendKey, cancellationRequested, wait,
                delegate { return (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency; });
        }

        public static bool Run(ManualProgram program, Func<string, Func<bool>, bool> sendText,
            Action<string> sendKey, Func<bool> cancellationRequested, Action<int> wait, Func<double> clock)
        {
            ManualProgramValidator.Validate(program, true);
            if (sendText == null || sendKey == null || cancellationRequested == null || wait == null || clock == null)
                throw new ArgumentNullException("Runner callbacks cannot be null.");

            List<LoopContext> loops = new List<LoopContext>();
            RunSignal signal = ExecuteBlocks(program.Blocks, loops, sendText, sendKey,
                cancellationRequested, wait, clock);
            return signal.Kind == SignalKind.Completed;
        }

        private static RunSignal ExecuteBlocks(List<ManualBlock> blocks, List<LoopContext> loops,
            Func<string, Func<bool>, bool> sendText, Action<string> sendKey,
            Func<bool> cancellationRequested, Action<int> wait, Func<double> clock)
        {
            for (int i = 0; i < blocks.Count; i++)
            {
                RunSignal signal = GetInterruption(loops, cancellationRequested, clock);
                if (signal.Kind != SignalKind.Completed)
                    return signal;

                ManualBlock block = blocks[i];
                if (block.Type == ManualBlock.Text)
                {
                    bool sent = sendText(block.Value, delegate
                    {
                        return GetInterruption(loops, cancellationRequested, clock).Kind != SignalKind.Completed;
                    });
                    if (!sent)
                        return GetInterruption(loops, cancellationRequested, clock).Kind == SignalKind.Completed ? Cancelled :
                            GetInterruption(loops, cancellationRequested, clock);
                }
                else if (block.Type == ManualBlock.Key)
                {
                    sendKey(block.Value);
                }
                else if (block.Type == ManualBlock.Wait)
                {
                    signal = WaitFor(block.Seconds, loops, cancellationRequested, wait, clock);
                    if (signal.Kind != SignalKind.Completed)
                        return signal;
                }
                else if (block.Type == ManualBlock.Loop)
                {
                    signal = ExecuteLoop(block, loops, sendText, sendKey, cancellationRequested, wait, clock);
                    if (signal.Kind != SignalKind.Completed)
                        return signal;
                }
            }
            return GetInterruption(loops, cancellationRequested, clock);
        }

        private static RunSignal ExecuteLoop(ManualBlock block, List<LoopContext> loops,
            Func<string, Func<bool>, bool> sendText, Action<string> sendKey,
            Func<bool> cancellationRequested, Action<int> wait, Func<double> clock)
        {
            LoopContext context = new LoopContext { Block = block, StartedAt = clock() };
            loops.Add(context);
            int iterations = 0;
            try
            {
                while (true)
                {
                    if (block.MaxIterations > 0 && iterations >= block.MaxIterations)
                        return Completed;

                    RunSignal signal = GetInterruption(loops, cancellationRequested, clock);
                    if (signal.Kind == SignalKind.Cancelled)
                        return signal;
                    if (signal.Kind == SignalKind.LoopTimeLimit)
                    {
                        if (signal.Context == context)
                            return Completed;
                        return signal;
                    }

                    iterations++;
                    signal = ExecuteBlocks(block.Children, loops, sendText, sendKey,
                        cancellationRequested, wait, clock);
                    if (signal.Kind == SignalKind.Cancelled)
                        return signal;
                    if (signal.Kind == SignalKind.LoopTimeLimit)
                    {
                        if (signal.Context == context)
                            return Completed;
                        return signal;
                    }
                }
            }
            finally
            {
                loops.RemoveAt(loops.Count - 1);
            }
        }

        private static RunSignal WaitFor(double seconds, List<LoopContext> loops,
            Func<bool> cancellationRequested, Action<int> wait, Func<double> clock)
        {
            double deadline = clock() + seconds;
            while (clock() < deadline)
            {
                RunSignal signal = GetInterruption(loops, cancellationRequested, clock);
                if (signal.Kind != SignalKind.Completed)
                    return signal;
                int milliseconds = (int)Math.Ceiling(Math.Min(25.0, (deadline - clock()) * 1000.0));
                wait(Math.Max(1, milliseconds));
            }
            return GetInterruption(loops, cancellationRequested, clock);
        }

        private static RunSignal GetInterruption(List<LoopContext> loops,
            Func<bool> cancellationRequested, Func<double> clock)
        {
            if (cancellationRequested())
                return Cancelled;
            double now = clock();
            for (int i = 0; i < loops.Count; i++)
            {
                LoopContext context = loops[i];
                double limit = context.Block.MaxDurationSeconds;
                if (limit > 0 && now - context.StartedAt >= limit)
                    return new RunSignal { Kind = SignalKind.LoopTimeLimit, Context = context };
            }
            return Completed;
        }
    }

    public static class ManualProgramTests
    {
        public static string RunSelfTests()
        {
            List<Keys> chord = ManualProgramValidator.ParseKeyChord("Ctrl+Shift+A");
            Assert(chord.Count == 3 && chord[0] == Keys.ControlKey && chord[1] == Keys.ShiftKey && chord[2] == Keys.A,
                "Key-chord parsing did not preserve modifier order.");
            Assert(ManualProgramValidator.ParseKeyChord("Enter")[0] == Keys.Enter,
                "The Enter key name was not recognized.");
            Assert(ManualProgramValidator.ParseKeyChord("Prior")[0] == Keys.PageUp &&
                ManualProgramValidator.ParseKeyChord("Next")[0] == Keys.PageDown,
                "The PageUp/PageDown aliases were not recognized.");
            string[] extendedKeyNames = new string[]
            {
                "PageUp", "PageDown", "Home", "End", "Insert", "Delete", "Left", "Right", "Up", "Down",
                "Snapshot", "PrintScreen", "LWin", "RWin", "Apps", "Divide", "NumLock"
            };
            for (int i = 0; i < extendedKeyNames.Length; i++)
            {
                List<Stroke> keyStrokes = KeyboardInput.BuildKeyChordStrokes(extendedKeyNames[i]);
                Assert(keyStrokes.Count == 2 && keyStrokes[0].VirtualKey == 0 &&
                    keyStrokes[0].ScanCode != 0 &&
                    (keyStrokes[0].Flags & KeyboardInput.KeyEventScanCode) != 0 &&
                    (keyStrokes[0].Flags & KeyboardInput.KeyEventExtended) != 0 &&
                    keyStrokes[1].VirtualKey == 0 && keyStrokes[1].ScanCode == keyStrokes[0].ScanCode &&
                    (keyStrokes[1].Flags & (KeyboardInput.KeyEventScanCode | KeyboardInput.KeyEventExtended | KeyboardInput.KeyEventKeyUp)) ==
                        (KeyboardInput.KeyEventScanCode | KeyboardInput.KeyEventExtended | KeyboardInput.KeyEventKeyUp),
                    "Scan-code extended-key events were not created for " + extendedKeyNames[i] +
                    " (vk=" + keyStrokes[0].VirtualKey + ", scan=" + keyStrokes[0].ScanCode +
                    ", flags=" + keyStrokes[0].Flags + ").");
            }
            List<Stroke> letterKey = KeyboardInput.BuildKeyChordStrokes("A");
            Assert(letterKey.Count == 2 && letterKey[0].VirtualKey == (ushort)Keys.A && letterKey[0].ScanCode == 0 &&
                letterKey[0].Flags == 0 && letterKey[1].VirtualKey == (ushort)Keys.A &&
                letterKey[1].Flags == KeyboardInput.KeyEventKeyUp,
                "A regular key no longer preserves its virtual-key down/up pair.");
            List<Stroke> combinedPageUp = KeyboardInput.BuildKeyChordStrokes("Ctrl+PageUp");
            Assert(combinedPageUp.Count == 4 && combinedPageUp[0].VirtualKey == (ushort)Keys.ControlKey &&
                combinedPageUp[0].Flags == 0 && combinedPageUp[1].VirtualKey == 0 &&
                combinedPageUp[1].ScanCode == 0x49 &&
                (combinedPageUp[1].Flags & (KeyboardInput.KeyEventScanCode | KeyboardInput.KeyEventExtended)) ==
                    (KeyboardInput.KeyEventScanCode | KeyboardInput.KeyEventExtended) &&
                (combinedPageUp[2].Flags & (KeyboardInput.KeyEventScanCode | KeyboardInput.KeyEventExtended | KeyboardInput.KeyEventKeyUp)) ==
                    (KeyboardInput.KeyEventScanCode | KeyboardInput.KeyEventExtended | KeyboardInput.KeyEventKeyUp) &&
                combinedPageUp[3].VirtualKey == (ushort)Keys.ControlKey &&
                combinedPageUp[3].Flags == KeyboardInput.KeyEventKeyUp,
                "Ctrl+PageUp did not produce the expected extended scan-code sequence.");
            bool invalidChordRejected = false;
            try
            {
                ManualProgramValidator.ParseKeyChord("Ctrl+");
            }
            catch (InvalidDataException)
            {
                invalidChordRejected = true;
            }
            Assert(invalidChordRejected, "Malformed key chords must be rejected.");

            ManualProgram original = new ManualProgram();
            ManualBlock loop = new ManualBlock
            {
                    Type = ManualBlock.Loop,
                    MaxIterations = 3,
                    Children = new List<ManualBlock>
                    {
                    new ManualBlock { Type = ManualBlock.Text, Value = "\u4f60\u597d\ud83d\ude00" },
                    new ManualBlock { Type = ManualBlock.Wait, Seconds = 0.25 }
                }
            };
            original.Blocks.Add(loop);
            string path = Path.Combine(Path.GetTempPath(), "SimulateKeyboardInput-flow-" + Guid.NewGuid().ToString("N") + ".json");
            try
            {
                File.WriteAllText(path + ".tmp", "keep-existing-temporary-file");
                ManualProgramStore.Save(path, original);
                Assert(File.ReadAllText(path + ".tmp") == "keep-existing-temporary-file",
                    "Saving a flow changed an unrelated file using the old fixed temporary path.");
                ManualProgram loaded = ManualProgramStore.Load(path);
                Assert(loaded.Version == 1 && loaded.Blocks.Count == 1 && loaded.Blocks[0].Children.Count == 2 &&
                    loaded.Blocks[0].Children[0].Value == "\u4f60\u597d\ud83d\ude00" && loaded.Blocks[0].MaxIterations == 3,
                    "Manual program JSON did not round-trip its nested blocks.");
                original.Blocks[0].Children[0].Value = "updated";
                ManualProgramStore.Save(path, original);
                Assert(ManualProgramStore.Load(path).Blocks[0].Children[0].Value == "updated",
                    "Saving again did not replace the selected JSON file.");
                Assert(File.ReadAllText(path + ".tmp") == "keep-existing-temporary-file",
                    "Saving again changed an unrelated temporary-path file.");
            }
            finally
            {
                if (File.Exists(path))
                    File.Delete(path);
                if (File.Exists(path + ".tmp"))
                    File.Delete(path + ".tmp");
            }

            ManualProgram counted = new ManualProgram();
            counted.Blocks.Add(new ManualBlock
            {
                Type = ManualBlock.Loop,
                MaxIterations = 3,
                Children = new List<ManualBlock> { new ManualBlock { Type = ManualBlock.Text, Value = "x" } }
            });
            int sentCount = 0;
            double fakeTime = 0;
            bool completed = ManualProgramRunner.Run(counted,
                delegate(string text, Func<bool> cancel) { sentCount++; return !cancel(); },
                delegate { }, delegate { return false; }, delegate(int milliseconds) { fakeTime += milliseconds / 1000.0; },
                delegate { return fakeTime; });
            Assert(completed && sentCount == 3, "A count-limited loop did not run exactly the configured number of times.");

            ManualProgram timed = new ManualProgram();
            timed.Blocks.Add(new ManualBlock
            {
                Type = ManualBlock.Loop,
                MaxDurationSeconds = 0.05,
                Children = new List<ManualBlock> { new ManualBlock { Type = ManualBlock.Wait, Seconds = 1 } }
            });
            fakeTime = 0;
            completed = ManualProgramRunner.Run(timed,
                delegate(string text, Func<bool> cancel) { return true; }, delegate { }, delegate { return false; },
                delegate(int milliseconds) { fakeTime += milliseconds / 1000.0; }, delegate { return fakeTime; });
            Assert(completed && fakeTime >= 0.05 && fakeTime < 0.1,
                "A time-limited loop did not interrupt its wait at the configured limit.");

            ManualProgram nested = new ManualProgram();
            nested.Blocks.Add(new ManualBlock
            {
                Type = ManualBlock.Loop,
                MaxIterations = 2,
                Children = new List<ManualBlock>
                {
                    new ManualBlock
                    {
                        Type = ManualBlock.Loop,
                        MaxDurationSeconds = 0.05,
                        Children = new List<ManualBlock> { new ManualBlock { Type = ManualBlock.Wait, Seconds = 1 } }
                    },
                    new ManualBlock { Type = ManualBlock.Text, Value = "outer" }
                }
            });
            fakeTime = 0;
            sentCount = 0;
            completed = ManualProgramRunner.Run(nested,
                delegate(string text, Func<bool> cancel) { sentCount++; return !cancel(); }, delegate { },
                delegate { return false; }, delegate(int milliseconds) { fakeTime += milliseconds / 1000.0; },
                delegate { return fakeTime; });
            Assert(completed && sentCount == 2,
                "An inner loop time limit did not return control to the enclosing loop.");

            ManualProgram outerTimed = new ManualProgram();
            outerTimed.Blocks.Add(new ManualBlock
            {
                Type = ManualBlock.Loop,
                MaxDurationSeconds = 0.05,
                Children = new List<ManualBlock>
                {
                    new ManualBlock
                    {
                        Type = ManualBlock.Loop,
                        MaxIterations = 10,
                        Children = new List<ManualBlock>
                        {
                            new ManualBlock { Type = ManualBlock.Wait, Seconds = 1 },
                            new ManualBlock { Type = ManualBlock.Text, Value = "inner" }
                        }
                    },
                    new ManualBlock { Type = ManualBlock.Text, Value = "outer" }
                }
            });
            outerTimed.Blocks.Add(new ManualBlock { Type = ManualBlock.Text, Value = "after" });
            fakeTime = 0;
            List<string> output = new List<string>();
            completed = ManualProgramRunner.Run(outerTimed,
                delegate(string text, Func<bool> cancel) { output.Add(text); return !cancel(); }, delegate { },
                delegate { return false; }, delegate(int milliseconds) { fakeTime += milliseconds / 1000.0; },
                delegate { return fakeTime; });
            Assert(completed && output.Count == 1 && output[0] == "after",
                "An outer loop time limit did not interrupt a nested loop and continue after it.");

            ManualProgram cancelledProgram = new ManualProgram();
            cancelledProgram.Blocks.Add(new ManualBlock { Type = ManualBlock.Text, Value = "first" });
            cancelledProgram.Blocks.Add(new ManualBlock { Type = ManualBlock.Text, Value = "second" });
            sentCount = 0;
            completed = ManualProgramRunner.Run(cancelledProgram,
                delegate(string text, Func<bool> cancel) { sentCount++; return true; }, delegate { },
                delegate { return sentCount > 0; }, delegate(int milliseconds) { }, delegate { return 0; });
            Assert(!completed && sentCount == 1, "A cancellation request did not stop later blocks.");

            ManualProgramValidator.Validate(timed, true);
            KeyCaptureTextBox.RunCaptureSelfTests();
            using (ManualOperationPanel panel = new ManualOperationPanel())
            {
                panel.RunFooterLayoutSelfTest();
                panel.RunCaptureIntegrationSelfTest();
            }
            using (KeyboardForm form = new KeyboardForm())
            {
                Assert(form.Controls.Count == 3, "The shared header and source tabs were not initialized.");
                form.RunSharedChromeSelfTest();
                form.RunStatusRoutingSelfTest();
                form.RunFileDropSelfTest();
            }
            return "Self-test passed: nested JSON persistence, key-chord parsing, loop limits, cancellation, control-key capture/display, aligned status actions, shared page chrome, page-specific status routing, and file drag-and-drop.";
        }

        private static void Assert(bool condition, string message)
        {
            if (!condition)
                throw new InvalidOperationException(message);
        }
    }

    public sealed class KeyCaptureTextBox : TextBox
    {
        public KeyCaptureTextBox()
        {
            ReadOnly = true;
            BackColor = SystemColors.Window;
        }

        protected override bool ProcessCmdKey(ref Message message, Keys keyData)
        {
            CaptureKey(keyData);
            return true;
        }

        protected override bool ProcessDialogKey(Keys keyData)
        {
            CaptureKey(keyData);
            return true;
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            CaptureKey(e.KeyData);
            e.Handled = true;
            e.SuppressKeyPress = true;
            base.OnKeyDown(e);
        }

        protected override void OnKeyPress(KeyPressEventArgs e)
        {
            e.Handled = true;
            base.OnKeyPress(e);
        }

        private void CaptureKey(Keys keyData)
        {
            Keys key = keyData & Keys.KeyCode;
            if (key == Keys.None || key == Keys.ControlKey || key == Keys.ShiftKey || key == Keys.Menu ||
                key == Keys.LControlKey || key == Keys.RControlKey ||
                key == Keys.LShiftKey || key == Keys.RShiftKey ||
                key == Keys.LMenu || key == Keys.RMenu)
                return;

            string name;
            switch (key)
            {
                case Keys.PageUp: name = "PageUp"; break;
                case Keys.PageDown: name = "PageDown"; break;
                case Keys.Enter: name = "Enter"; break;
                case Keys.Back: name = "Back"; break;
                case Keys.PrintScreen: name = "PrintScreen"; break;
                default: name = key.ToString(); break;
            }

            string chord = ((keyData & Keys.Control) != 0 ? "Ctrl+" : String.Empty) +
                ((keyData & Keys.Alt) != 0 ? "Alt+" : String.Empty) +
                ((keyData & Keys.Shift) != 0 ? "Shift+" : String.Empty) + name;
            try
            {
                ManualProgramValidator.ParseKeyChord(chord);
            }
            catch (InvalidDataException)
            {
                // Ignore unsupported key codes rather than storing an unrunnable block.
                return;
            }
            Text = chord;
            SelectionStart = Text.Length;
        }

        internal static void RunCaptureSelfTests()
        {
            using (KeyCaptureTextBox input = new KeyCaptureTextBox())
            {
                Keys[] keys = new Keys[]
                {
                    Keys.PageUp, Keys.PageDown, Keys.Left, Keys.Right, Keys.Up, Keys.Down,
                    Keys.Home, Keys.End, Keys.Insert, Keys.Delete, Keys.Tab, Keys.Enter,
                    Keys.Escape, Keys.Back, Keys.F1, Keys.A, Keys.Control | Keys.PageUp,
                    Keys.Control | Keys.Shift | Keys.A, Keys.Alt | Keys.F4
                };
                string[] names = new string[]
                {
                    "PageUp", "PageDown", "Left", "Right", "Up", "Down",
                    "Home", "End", "Insert", "Delete", "Tab", "Enter",
                    "Escape", "Back", "F1", "A", "Ctrl+PageUp", "Ctrl+Shift+A", "Alt+F4"
                };
                for (int i = 0; i < keys.Length; i++)
                {
                    Message message = Message.Create(IntPtr.Zero, 0x0100, IntPtr.Zero, IntPtr.Zero);
                    if (!input.ProcessCmdKey(ref message, keys[i]) || input.Text != names[i])
                        throw new InvalidOperationException("Command-key capture failed for " + names[i] + ".");
                    ManualProgramValidator.ParseKeyChord(input.Text);
                }
                input.Text = "PageUp";
                input.ProcessDialogKey(Keys.Tab);
                if (input.Text != "Tab")
                    throw new InvalidOperationException("Dialog-key capture failed for Tab.");
                KeyEventArgs down = new KeyEventArgs(Keys.Control | Keys.PageUp);
                input.OnKeyDown(down);
                if (input.Text != "Ctrl+PageUp" || !down.Handled || !down.SuppressKeyPress)
                    throw new InvalidOperationException("KeyDown capture did not suppress the original key.");
                input.OnKeyDown(new KeyEventArgs(Keys.Control | Keys.ControlKey));
                if (input.Text != "Ctrl+PageUp")
                    throw new InvalidOperationException("A modifier-only press replaced the recorded chord.");
                KeyPressEventArgs character = new KeyPressEventArgs('x');
                input.OnKeyPress(character);
                if (!character.Handled || input.Text != "Ctrl+PageUp")
                    throw new InvalidOperationException("Captured keys leaked into ordinary text entry.");

                // Exercise WinForms preprocessing and window dispatch locally, without SendInput.
                Keys[] routedKeys = new Keys[] { Keys.PageUp, Keys.PageDown, Keys.Left, Keys.Tab, Keys.Enter, Keys.Escape };
                string[] routedNames = new string[] { "PageUp", "PageDown", "Left", "Tab", "Enter", "Escape" };
                for (int i = 0; i < routedKeys.Length; i++)
                {
                    Message message = Message.Create(input.Handle, 0x0100, new IntPtr((int)routedKeys[i]), IntPtr.Zero);
                    if (!input.PreProcessMessage(ref message))
                        input.WndProc(ref message);
                    if (input.Text != routedNames[i])
                        throw new InvalidOperationException("WinForms message routing failed for " + routedNames[i] + ".");
                }
            }
        }
    }

    public static class UiChrome
    {
        public static readonly Color Background = Color.FromArgb(243, 245, 249);
        public static readonly Color Surface = Color.White;
        public static readonly Color SurfaceSoft = Color.FromArgb(248, 249, 252);
        public static readonly Color Text = Color.FromArgb(32, 36, 49);
        public static readonly Color Muted = Color.FromArgb(114, 121, 139);
        public static readonly Color Line = Color.FromArgb(230, 233, 240);
        public static readonly Color Primary = Color.FromArgb(101, 88, 232);
        public static readonly Color PrimaryDark = Color.FromArgb(80, 68, 207);
        public static readonly Color PrimarySoft = Color.FromArgb(239, 237, 255);
        public static readonly Color Success = Color.FromArgb(33, 135, 93);
        public static readonly Color SuccessSoft = Color.FromArgb(234, 248, 241);
        public static readonly Color Warning = Color.FromArgb(168, 103, 23);
        public static readonly Color WarningSoft = Color.FromArgb(255, 246, 230);
        public static readonly Color Danger = Color.FromArgb(197, 72, 90);
        public static readonly Color NeutralSoft = Color.FromArgb(238, 240, 244);
        public static readonly Color HoverSoft = Color.FromArgb(245, 244, 251);
        public static readonly Color KeyText = Color.FromArgb(80, 86, 104);

        public static Font Font(float size = 9.0F, FontStyle style = FontStyle.Regular)
        {
            return new Font("Microsoft YaHei UI", size, style, GraphicsUnit.Point);
        }

        public static Label Label(string text, float size = 9.0F, Color? color = null, FontStyle style = FontStyle.Regular)
        {
            return new Label
            {
                AutoSize = true,
                BackColor = Color.Transparent,
                ForeColor = color ?? Text,
                Font = Font(size, style),
                Text = text
            };
        }

        public static Button Button(string text, bool primary = false)
        {
            Button button = new Button();
            button.Text = text;
            button.AutoSize = false;
            button.Size = new Size(92, 34);
            button.Padding = new Padding(8, 0, 8, 0);
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderSize = primary ? 0 : 1;
            button.FlatAppearance.BorderColor = Line;
            button.FlatAppearance.MouseOverBackColor = primary ? PrimaryDark : SurfaceSoft;
            button.FlatAppearance.MouseDownBackColor = primary ? PrimaryDark : PrimarySoft;
            button.BackColor = primary ? Primary : Surface;
            button.ForeColor = primary ? Color.White : Color.FromArgb(81, 88, 106);
            button.Font = Font(8.5F);
            button.Cursor = Cursors.Hand;
            button.UseVisualStyleBackColor = false;
            button.EnabledChanged += delegate
            {
                if (button.Enabled)
                {
                    button.BackColor = primary ? Primary : Surface;
                    button.ForeColor = primary ? Color.White : Color.FromArgb(81, 88, 106);
                }
                else
                {
                    button.BackColor = Color.FromArgb(246, 247, 249);
                    button.ForeColor = Color.FromArgb(174, 178, 188);
                }
            };
            return button;
        }

        public static Button SoftButton(string text)
        {
            Button button = Button(text);
            button.BackColor = PrimarySoft;
            button.ForeColor = PrimaryDark;
            button.FlatAppearance.BorderSize = 0;
            button.FlatAppearance.MouseOverBackColor = Color.FromArgb(229, 225, 255);
            button.FlatAppearance.MouseDownBackColor = Color.FromArgb(222, 217, 252);
            return button;
        }

        public static Button PlainButton(string text, Color foreColor)
        {
            Button button = Button(text);
            button.BackColor = Surface;
            button.ForeColor = foreColor;
            button.FlatAppearance.BorderSize = 0;
            button.FlatAppearance.MouseOverBackColor = SurfaceSoft;
            button.FlatAppearance.MouseDownBackColor = PrimarySoft;
            return button;
        }

        public static Panel Card()
        {
            return new Panel { BackColor = Surface, Padding = new Padding(1) };
        }

        public static GraphicsPath RoundRect(Rectangle bounds, int radius)
        {
            GraphicsPath path = new GraphicsPath();
            if (bounds.Width <= 0 || bounds.Height <= 0)
            {
                path.AddRectangle(bounds);
                return path;
            }
            int diameter = Math.Max(2, radius * 2);
            if (diameter >= Math.Min(bounds.Width, bounds.Height))
                diameter = Math.Min(bounds.Width, bounds.Height);
            path.AddArc(bounds.X, bounds.Y, diameter, diameter, 180, 90);
            path.AddArc(bounds.Right - diameter, bounds.Y, diameter, diameter, 270, 90);
            path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
            path.AddArc(bounds.X, bounds.Bottom - diameter, diameter, diameter, 90, 90);
            path.CloseFigure();
            return path;
        }

        public static void StyleTextBox(TextBox input)
        {
            input.BorderStyle = BorderStyle.FixedSingle;
            input.BackColor = Surface;
            input.ForeColor = Text;
            input.Font = Font();
        }

        public static void StyleNumeric(NumericUpDown input)
        {
            input.BorderStyle = BorderStyle.FixedSingle;
            input.BackColor = Surface;
            input.ForeColor = Text;
            input.Font = Font();
        }

        public static void PaintCard(object sender, PaintEventArgs e)
        {
            Control control = (Control)sender;
            using (Pen pen = new Pen(Line))
                e.Graphics.DrawRectangle(pen, 0, 0, Math.Max(0, control.Width - 1), Math.Max(0, control.Height - 1));
        }
    }

    public sealed class Badge : Control
    {
        private string _text = String.Empty;
        private Color _fill = UiChrome.NeutralSoft;
        private Color _fore = UiChrome.Muted;

        public Badge()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Font = UiChrome.Font(8.0F);
            Height = 26;
            Visible = false;
        }

        public string Value
        {
            get { return _text; }
        }

        public bool HasContent
        {
            get { return _text.Length > 0; }
        }

        public void Set(string text, Color fill, Color fore)
        {
            _text = text ?? String.Empty;
            _fill = fill;
            _fore = fore;
            Width = TextRenderer.MeasureText(_text, Font).Width + 22;
            Visible = _text.Length > 0;
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath path = UiChrome.RoundRect(new Rectangle(0, 0, Width - 1, Height - 1), Height / 2))
            using (SolidBrush brush = new SolidBrush(_fill))
                e.Graphics.FillPath(brush, path);
            TextRenderer.DrawText(e.Graphics, _text, Font, ClientRectangle, _fore,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
    }

    public sealed class PageHeading : Panel
    {
        private readonly Badge _badge;

        public PageHeading(string title, string description)
        {
            Dock = DockStyle.Top;
            Height = 80;
            BackColor = UiChrome.Background;

            Label titleLabel = UiChrome.Label(title, 17.0F, UiChrome.Text, FontStyle.Bold);
            titleLabel.Location = new Point(1, -2);
            Label descriptionLabel = UiChrome.Label(description, 9.0F, UiChrome.Muted);
            descriptionLabel.Location = new Point(2, 42);

            _badge = new Badge();
            Controls.Add(titleLabel);
            Controls.Add(descriptionLabel);
            Controls.Add(_badge);
            Resize += delegate { LayoutBadge(); };
        }

        public Badge StatusBadge
        {
            get { return _badge; }
        }

        public void SetBadge(string text, Color fill, Color fore)
        {
            _badge.Set(text, fill, fore);
            LayoutBadge();
        }

        public void HideBadge()
        {
            _badge.Visible = false;
        }

        protected override void OnLayout(LayoutEventArgs levent)
        {
            base.OnLayout(levent);
            LayoutBadge();
        }

        protected override void OnVisibleChanged(EventArgs e)
        {
            base.OnVisibleChanged(e);
            LayoutBadge();
        }

        private void LayoutBadge()
        {
            if (_badge == null || !_badge.HasContent)
                return;
            _badge.Location = new Point(Math.Max(0, ClientSize.Width - _badge.Width), 4);
        }
    }

    public sealed class RoundedPanel : Panel
    {
        private int _radius = 12;
        private Color _fill = UiChrome.Surface;
        private Color _border = Color.Empty;

        public RoundedPanel()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = _fill;
        }

        public int Radius
        {
            get { return _radius; }
            set { _radius = value; Invalidate(); }
        }

        public Color FillColor
        {
            get { return _fill; }
            set { _fill = value; BackColor = value; Invalidate(); }
        }

        public Color BorderColor
        {
            get { return _border; }
            set { _border = value; Invalidate(); }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.Clear(_fill);
            using (GraphicsPath path = UiChrome.RoundRect(new Rectangle(0, 0, Width - 1, Height - 1), _radius))
            {
                using (SolidBrush brush = new SolidBrush(_fill))
                    e.Graphics.FillPath(brush, path);
                if (!_border.IsEmpty)
                {
                    using (Pen pen = new Pen(_border))
                        e.Graphics.DrawPath(pen, path);
                }
            }
        }
    }

    public enum VectorIconKind
    {
        Upload,
        File,
        Info,
        Bolt
    }

    public sealed class VectorIcon : Control
    {
        private VectorIconKind _kind;
        private Color _tint = UiChrome.Muted;

        public VectorIcon()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Size = new Size(18, 18);
            BackColor = UiChrome.Surface;
        }

        public VectorIconKind Kind
        {
            get { return _kind; }
            set { _kind = value; Invalidate(); }
        }

        public Color Tint
        {
            get { return _tint; }
            set { _tint = value; Invalidate(); }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.Clear(BackColor);
            float scale = Math.Min(Width, Height) / 24F;
            graphics.TranslateTransform((Width - 24F * scale) / 2F, (Height - 24F * scale) / 2F);
            graphics.ScaleTransform(scale, scale);

            if (_kind == VectorIconKind.Bolt)
            {
                PointF[] bolt = new PointF[]
                {
                    new PointF(13F, 3F), new PointF(6F, 13.5F), new PointF(11F, 13.5F),
                    new PointF(10F, 21F), new PointF(18F, 10.5F), new PointF(13F, 10.5F)
                };
                using (SolidBrush brush = new SolidBrush(_tint))
                    graphics.FillPolygon(brush, bolt);
                return;
            }

            using (Pen pen = new Pen(_tint, 1.9F))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                pen.LineJoin = LineJoin.Round;
                if (_kind == VectorIconKind.Upload)
                {
                    graphics.DrawLine(pen, 12F, 19F, 12F, 5F);
                    graphics.DrawLine(pen, 7F, 10F, 12F, 5F);
                    graphics.DrawLine(pen, 17F, 10F, 12F, 5F);
                    graphics.DrawLine(pen, 5F, 18F, 5F, 21F);
                    graphics.DrawLine(pen, 5F, 21F, 19F, 21F);
                    graphics.DrawLine(pen, 19F, 21F, 19F, 18F);
                }
                else if (_kind == VectorIconKind.File)
                {
                    using (GraphicsPath path = UiChrome.RoundRect(new Rectangle(5, 3, 14, 18), 3))
                        graphics.DrawPath(pen, path);
                    graphics.DrawLine(pen, 9F, 12F, 16F, 12F);
                    graphics.DrawLine(pen, 9F, 16F, 16F, 16F);
                }
                else
                {
                    graphics.DrawEllipse(pen, 4F, 4F, 16F, 16F);
                    graphics.DrawLine(pen, 12F, 10.5F, 12F, 16F);
                    graphics.DrawLine(pen, 12F, 7.5F, 12.1F, 7.5F);
                }
            }
        }
    }

    public sealed class ToggleSwitch : Control
    {
        private bool _checked;

        public event EventHandler CheckedChanged;

        public ToggleSwitch()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw |
                ControlStyles.Selectable, true);
            Size = new Size(40, 23);
            BackColor = UiChrome.Surface;
            Cursor = Cursors.Hand;
            TabStop = true;
        }

        public bool Checked
        {
            get { return _checked; }
            set
            {
                if (_checked == value)
                    return;
                _checked = value;
                Invalidate();
                EventHandler handler = CheckedChanged;
                if (handler != null)
                    handler(this, EventArgs.Empty);
            }
        }

        protected override void OnClick(EventArgs e)
        {
            Checked = !Checked;
            base.OnClick(e);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter)
            {
                Checked = !Checked;
                e.Handled = true;
                e.SuppressKeyPress = true;
                return;
            }
            base.OnKeyDown(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.Clear(BackColor);
            Rectangle track = new Rectangle(0, 0, Width - 1, Height - 1);
            using (GraphicsPath path = UiChrome.RoundRect(track, Height / 2))
            using (SolidBrush brush = new SolidBrush(_checked ? UiChrome.Primary : Color.FromArgb(217, 220, 229)))
                e.Graphics.FillPath(brush, path);
            int knob = Height - 6;
            int knobX = _checked ? Width - knob - 3 : 3;
            using (SolidBrush brush = new SolidBrush(Color.White))
                e.Graphics.FillEllipse(brush, knobX, 3, knob, knob);
            if (Focused && ShowFocusCues)
                ControlPaint.DrawFocusRectangle(e.Graphics, new Rectangle(0, 0, Width - 1, Height - 1));
        }
    }

    public sealed class HotkeyDisplay : Control
    {
        private const int PlusWidth = 14;
        private readonly Font _chipFont;
        private readonly Font _plusFont;
        private string _display = String.Empty;

        public HotkeyDisplay()
        {
            _chipFont = UiChrome.Font(8.0F, FontStyle.Bold);
            _plusFont = UiChrome.Font(8.0F);
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Height = 28;
            BackColor = UiChrome.Surface;
        }

        public string DisplayText
        {
            get { return _display; }
        }

        public void SetDisplay(string display)
        {
            _display = display ?? String.Empty;
            RecalculateWidth();
            Invalidate();
        }

        private string[] Parts()
        {
            string[] parts = _display.Split(new char[] { '+' }, StringSplitOptions.RemoveEmptyEntries);
            if (!_display.EndsWith("+"))
                return parts;
            string[] extended = new string[parts.Length + 1];
            Array.Copy(parts, extended, parts.Length);
            extended[extended.Length - 1] = "+";
            return extended;
        }

        private int ChipWidth(string text)
        {
            return TextRenderer.MeasureText(text, _chipFont).Width + 16;
        }

        private void RecalculateWidth()
        {
            int width = 0;
            string[] parts = Parts();
            for (int i = 0; i < parts.Length; i++)
            {
                width += ChipWidth(parts[i]);
                if (i > 0)
                    width += PlusWidth;
            }
            Width = Math.Max(0, width);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.Clear(BackColor);
            int x = 0;
            string[] parts = Parts();
            for (int i = 0; i < parts.Length; i++)
            {
                if (i > 0)
                {
                    TextRenderer.DrawText(graphics, "+", _plusFont,
                        new Rectangle(x, 0, PlusWidth, Height), UiChrome.Muted,
                        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
                    x += PlusWidth;
                }
                int width = ChipWidth(parts[i]);
                Rectangle chip = new Rectangle(x, 1, width, Height - 3);
                using (GraphicsPath path = UiChrome.RoundRect(chip, 7))
                {
                    using (SolidBrush fill = new SolidBrush(BackColor))
                        graphics.FillPath(fill, path);
                    using (Pen pen = new Pen(Color.FromArgb(223, 226, 234)))
                        graphics.DrawPath(pen, path);
                }
                TextRenderer.DrawText(graphics, parts[i], _chipFont,
                    new Rectangle(chip.X, chip.Y, chip.Width, chip.Height), UiChrome.KeyText,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
                x += width;
            }
        }
    }

    public sealed class DropZone : Panel
    {
        private bool _dragging;

        public DropZone()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Color.FromArgb(251, 251, 253);
            Cursor = Cursors.Hand;
        }

        public bool Dragging
        {
            get { return _dragging; }
            set
            {
                if (_dragging == value)
                    return;
                _dragging = value;
                Invalidate();
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.Clear(BackColor);
            Rectangle border = new Rectangle(1, 1, Math.Max(0, Width - 3), Math.Max(0, Height - 3));
            using (GraphicsPath path = UiChrome.RoundRect(border, 13))
            using (Pen pen = new Pen(_dragging ? UiChrome.Primary : Color.FromArgb(216, 219, 234), 1.4F))
            {
                pen.DashStyle = DashStyle.Dash;
                pen.DashPattern = new float[] { 4F, 3F };
                e.Graphics.DrawPath(pen, path);
            }
        }
    }

    public sealed class NavButton : Button
    {
        private readonly bool _fileIcon;
        private bool _active;
        private bool _hover;

        public NavButton(string text, bool fileIcon)
        {
            _fileIcon = fileIcon;
            Text = text;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            BackColor = UiChrome.Surface;
            ForeColor = UiChrome.Muted;
            Font = UiChrome.Font(9.0F);
            Cursor = Cursors.Hand;
            TabStop = true;
        }

        public bool Active
        {
            get { return _active; }
            set
            {
                if (_active == value)
                    return;
                _active = value;
                Invalidate();
            }
        }

        protected override void OnMouseEnter(EventArgs e)
        {
            _hover = true;
            Invalidate();
            base.OnMouseEnter(e);
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            _hover = false;
            Invalidate();
            base.OnMouseLeave(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.Clear(BackColor);
            Color back = _active ? UiChrome.PrimarySoft : (_hover ? UiChrome.HoverSoft : UiChrome.Surface);
            using (GraphicsPath path = UiChrome.RoundRect(new Rectangle(0, 0, Width - 1, Height - 1), 10))
            using (SolidBrush brush = new SolidBrush(back))
                graphics.FillPath(brush, path);

            Color fore = _active ? UiChrome.PrimaryDark : (_hover ? UiChrome.Text : Color.FromArgb(102, 110, 128));
            DrawIcon(graphics, new Rectangle(14, (Height - 18) / 2, 18, 18), fore);
            Rectangle textBounds = new Rectangle(42, 0, Math.Max(0, Width - 56), Height);
            TextRenderer.DrawText(graphics, Text, Font, textBounds, fore,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);

            if (_active)
            {
                using (SolidBrush dot = new SolidBrush(UiChrome.Primary))
                    graphics.FillEllipse(dot, Width - 20, Height / 2 - 3, 6, 6);
            }
            if (Focused && ShowFocusCues)
                ControlPaint.DrawFocusRectangle(graphics, new Rectangle(4, 4, Width - 8, Height - 8));
        }

        private void DrawIcon(Graphics graphics, Rectangle bounds, Color color)
        {
            using (Pen pen = new Pen(color, 1.6F))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                if (_fileIcon)
                {
                    Rectangle page = new Rectangle(bounds.X + 3, bounds.Y + 1, bounds.Width - 7, bounds.Height - 2);
                    using (GraphicsPath path = UiChrome.RoundRect(page, 3))
                        graphics.DrawPath(pen, path);
                    graphics.DrawLine(pen, page.X + 4, page.Y + 8, page.Right - 4, page.Y + 8);
                    graphics.DrawLine(pen, page.X + 4, page.Y + 12, page.Right - 5, page.Y + 12);
                }
                else
                {
                    Rectangle first = new Rectangle(bounds.X + 1, bounds.Y + 2, 6, 6);
                    Rectangle second = new Rectangle(bounds.X + 11, bounds.Y + 10, 6, 6);
                    using (GraphicsPath firstPath = UiChrome.RoundRect(first, 2))
                        graphics.DrawPath(pen, firstPath);
                    using (GraphicsPath secondPath = UiChrome.RoundRect(second, 2))
                        graphics.DrawPath(pen, secondPath);
                    graphics.DrawLine(pen, first.Right, first.Y + 3, bounds.X + 10, first.Y + 3);
                    graphics.DrawLine(pen, bounds.X + 10, first.Y + 3, bounds.X + 10, second.Y);
                    graphics.DrawLine(pen, bounds.X + 10, second.Y, second.X, second.Y);
                }
            }
        }
    }

    public sealed class BrandMark : Control
    {
        public BrandMark()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            Size = new Size(38, 38);
            BackColor = UiChrome.Surface;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics;
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.Clear(BackColor);
            Rectangle bounds = new Rectangle(0, 0, Width - 1, Height - 1);
            using (GraphicsPath path = UiChrome.RoundRect(bounds, 12))
            using (LinearGradientBrush brush = new LinearGradientBrush(bounds,
                Color.FromArgb(120, 108, 241), Color.FromArgb(85, 71, 213), 45F))
                graphics.FillPath(brush, path);

            Rectangle keyboard = new Rectangle(9, 13, 20, 12);
            using (GraphicsPath path = UiChrome.RoundRect(keyboard, 3))
            using (SolidBrush white = new SolidBrush(Color.FromArgb(245, 245, 255)))
                graphics.FillPath(white, path);
            using (SolidBrush purple = new SolidBrush(Color.FromArgb(101, 88, 232)))
            {
                for (int row = 0; row < 2; row++)
                {
                    for (int column = 0; column < 4; column++)
                        graphics.FillRectangle(purple, 12 + column * 4, 16 + row * 3, 2, 2);
                }
                graphics.FillRectangle(purple, 13, 22, 12, 2);
            }
        }
    }

    public sealed class ModernTabPage : Panel
    {
        public ModernTabPage(string text)
        {
            Text = text;
        }
    }

    public sealed class ModernTabControl : Panel
    {
        private readonly ModernTabPageCollection _pages;
        private ModernTabPage _selectedTab;

        public event EventHandler SelectedIndexChanged;

        public ModernTabControl()
        {
            _pages = new ModernTabPageCollection(this);
        }

        public ModernTabPageCollection TabPages
        {
            get { return _pages; }
        }

        public ModernTabPage SelectedTab
        {
            get { return _selectedTab; }
            set
            {
                if (value != null && !Controls.Contains(value))
                    throw new ArgumentException("The page does not belong to this control.");
                if (_selectedTab == value)
                    return;
                _selectedTab = value;
                SuspendLayout();
                foreach (Control page in Controls)
                    page.Visible = page == value;
                if (value != null)
                    value.BringToFront();
                ResumeLayout(true);
                EventHandler handler = SelectedIndexChanged;
                if (handler != null)
                    handler(this, EventArgs.Empty);
            }
        }

        public int SelectedIndex
        {
            get { return _pages.IndexOf(_selectedTab); }
            set
            {
                if (value < 0 || value >= _pages.Count)
                    throw new ArgumentOutOfRangeException("value");
                SelectedTab = _pages[value];
            }
        }

        public void HideHeaders()
        {
        }
    }

    public sealed class ModernTabPageCollection
    {
        private readonly ModernTabControl _owner;
        private readonly List<ModernTabPage> _pages = new List<ModernTabPage>();

        internal ModernTabPageCollection(ModernTabControl owner)
        {
            _owner = owner;
        }

        public int Count
        {
            get { return _pages.Count; }
        }

        public ModernTabPage this[int index]
        {
            get { return _pages[index]; }
        }

        internal int IndexOf(ModernTabPage page)
        {
            return _pages.IndexOf(page);
        }

        public void Add(ModernTabPage page)
        {
            page.Dock = DockStyle.Fill;
            page.Visible = false;
            _pages.Add(page);
            _owner.Controls.Add(page);
            if (_owner.SelectedTab == null)
                _owner.SelectedTab = page;
        }
    }

    public sealed class ManualOperationPanel : UserControl
    {
        private readonly TreeView _tree;
        private readonly Panel _propertiesPanel;
        private readonly Label _statusLabel;
        private readonly Button _stopButton;
        private readonly Label _selectionLabel;
        private readonly TableLayoutPanel _footer;
        private readonly PageHeading _heading;
        private readonly Label _blockCountLabel;
        private readonly Label _emptyFlow;
        private readonly List<Control> _stretchControls = new List<Control>();
        private string _currentPath;
        private bool _dirty;
        private bool _loadingProperties;

        public event EventHandler StopRequested;

        public ManualOperationPanel()
        {
            Dock = DockStyle.Fill;
            BackColor = UiChrome.Background;
            Font = UiChrome.Font();
            ForeColor = UiChrome.Text;

            TableLayoutPanel toolbar = new TableLayoutPanel();
            toolbar.Dock = DockStyle.Top;
            toolbar.Height = 56;
            toolbar.ColumnCount = 2;
            toolbar.RowCount = 1;
            toolbar.Padding = new Padding(0, 4, 0, 12);
            toolbar.BackColor = UiChrome.Background;
            toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            toolbar.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            FlowLayoutPanel fileActions = new FlowLayoutPanel();
            fileActions.Dock = DockStyle.Fill;
            fileActions.WrapContents = false;
            fileActions.AutoSize = false;
            fileActions.Margin = new Padding(0);
            fileActions.BackColor = UiChrome.Background;
            AddToolbarButton(fileActions, "\u65b0\u5efa", NewProgram);
            AddToolbarButton(fileActions, "\u6253\u5f00 JSON", OpenProgram);
            AddToolbarButton(fileActions, "\u4fdd\u5b58", SaveProgramClick);
            AddToolbarButton(fileActions, "\u53e6\u5b58\u4e3a", SaveAsProgramClick);

            FlowLayoutPanel blockActions = new FlowLayoutPanel();
            blockActions.AutoSize = true;
            blockActions.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            blockActions.WrapContents = false;
            blockActions.Margin = new Padding(0);
            blockActions.BackColor = UiChrome.Background;
            Panel blockSeparator = new Panel();
            blockSeparator.Size = new Size(1, 24);
            blockSeparator.BackColor = UiChrome.Line;
            blockSeparator.Margin = new Padding(9, 5, 9, 0);
            blockActions.Controls.Add(blockSeparator);
            AddToolbarButton(blockActions, "+ \u8f93\u5165", delegate { AddBlock(ManualBlock.Text); }, true);
            AddToolbarButton(blockActions, "+ \u7b49\u5f85", delegate { AddBlock(ManualBlock.Wait); }, true);
            AddToolbarButton(blockActions, "+ \u5faa\u73af", delegate { AddBlock(ManualBlock.Loop); }, true);
            AddToolbarButton(blockActions, "\u5220\u9664", DeleteSelectedBlock, false, true);

            toolbar.Controls.Add(fileActions, 0, 0);
            toolbar.Controls.Add(blockActions, 1, 0);

            SplitContainer split = new SplitContainer();
            split.Dock = DockStyle.Fill;
            split.Orientation = Orientation.Vertical;
            split.Size = new Size(900, 400);
            split.BackColor = UiChrome.Background;
            split.Panel1.BackColor = UiChrome.Background;
            split.Panel2.BackColor = UiChrome.Background;
            split.Panel1.Padding = new Padding(0, 0, 5, 0);
            split.Panel2.Padding = new Padding(5, 0, 0, 0);
            split.Panel1MinSize = 280;
            split.Panel2MinSize = 280;
            split.SplitterDistance = 570;

            Panel flowCard = UiChrome.Card();
            flowCard.Dock = DockStyle.Fill;
            flowCard.Paint += UiChrome.PaintCard;
            Panel flowHeader = new Panel();
            flowHeader.Dock = DockStyle.Top;
            flowHeader.Height = 46;
            flowHeader.BackColor = UiChrome.Surface;
            Label flowTitle = UiChrome.Label("\u64cd\u4f5c\u6d41\u7a0b", 10.0F, UiChrome.Text, FontStyle.Bold);
            flowTitle.AutoSize = false;
            flowTitle.Dock = DockStyle.Fill;
            flowTitle.TextAlign = ContentAlignment.MiddleLeft;
            flowTitle.Padding = new Padding(16, 0, 0, 0);
            _blockCountLabel = UiChrome.Label(String.Empty, 8.0F, UiChrome.Muted);
            _blockCountLabel.Dock = DockStyle.Right;
            _blockCountLabel.TextAlign = ContentAlignment.MiddleRight;
            _blockCountLabel.Padding = new Padding(0, 15, 16, 0);
            flowHeader.Controls.Add(flowTitle);
            flowHeader.Controls.Add(_blockCountLabel);

            _tree = new TreeView();
            _tree.Dock = DockStyle.Fill;
            _tree.BorderStyle = BorderStyle.None;
            _tree.BackColor = UiChrome.Surface;
            _tree.ForeColor = UiChrome.Text;
            _tree.Font = UiChrome.Font(9.0F);
            _tree.ItemHeight = 28;
            _tree.HideSelection = false;
            _tree.AllowDrop = true;
            _tree.ShowLines = false;
            _tree.ShowPlusMinus = true;
            _tree.ShowRootLines = false;
            _tree.AfterSelect += delegate { RenderProperties(); };
            _tree.ItemDrag += TreeItemDrag;
            _tree.DragEnter += TreeDragEnter;
            _tree.DragOver += TreeDragOver;
            _tree.DragDrop += TreeDragDrop;
            flowCard.Controls.Add(_tree);
            flowCard.Controls.Add(flowHeader);

            _emptyFlow = UiChrome.Label("\u6682\u65E0\u64CD\u4F5C\u79EF\u6728\r\n\u70B9\u51FB\u4E0A\u65B9\u300C\u8F93\u5165\u300D\u300C\u7B49\u5F85\u300D\u6216\u300C\u5FAA\u73AF\u300D\u5F00\u59CB\u7F16\u6392", 9.0F, UiChrome.Muted);
            _emptyFlow.AutoSize = false;
            _emptyFlow.Size = new Size(360, 48);
            _emptyFlow.TextAlign = ContentAlignment.MiddleCenter;
            _emptyFlow.BackColor = UiChrome.Surface;
            flowCard.Controls.Add(_emptyFlow);
            _emptyFlow.BringToFront();
            flowCard.Resize += delegate { LayoutEmptyFlow(); };
            split.Panel1.Controls.Add(flowCard);

            Panel propertyCard = UiChrome.Card();
            propertyCard.Dock = DockStyle.Fill;
            propertyCard.Paint += UiChrome.PaintCard;
            _propertiesPanel = new Panel();
            _propertiesPanel.Dock = DockStyle.Fill;
            _propertiesPanel.AutoScroll = true;
            _propertiesPanel.BackColor = UiChrome.Surface;
            _propertiesPanel.ClientSizeChanged += delegate { LayoutPropertyWidths(); };
            propertyCard.Controls.Add(_propertiesPanel);

            Panel propertyHeader = new Panel();
            propertyHeader.Dock = DockStyle.Top;
            propertyHeader.Height = 46;
            propertyHeader.BackColor = UiChrome.Surface;
            _selectionLabel = UiChrome.Label("\u79ef\u6728\u5c5e\u6027", 10.0F, UiChrome.Text, FontStyle.Bold);
            _selectionLabel.AutoSize = false;
            _selectionLabel.Dock = DockStyle.Fill;
            _selectionLabel.TextAlign = ContentAlignment.MiddleLeft;
            _selectionLabel.Padding = new Padding(16, 0, 0, 0);
            Label propertyCaption = UiChrome.Label("\u9009\u4e2d\u540e\u7f16\u8f91", 8.0F, UiChrome.Muted);
            propertyCaption.Dock = DockStyle.Right;
            propertyCaption.TextAlign = ContentAlignment.MiddleRight;
            propertyCaption.Padding = new Padding(0, 15, 16, 0);
            propertyHeader.Controls.Add(_selectionLabel);
            propertyHeader.Controls.Add(propertyCaption);
            propertyCard.Controls.Add(propertyHeader);
            split.Panel2.Controls.Add(propertyCard);

            _footer = new TableLayoutPanel();
            _footer.Dock = DockStyle.Bottom;
            _footer.Height = 42;
            _footer.ColumnCount = 2;
            _footer.RowCount = 1;
            _footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            _footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            _footer.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            _footer.Padding = new Padding(2, 0, 2, 0);
            _footer.BackColor = UiChrome.Background;

            _statusLabel = UiChrome.Label("\u62d6\u52a8\u79ef\u6728\u53ef\u8c03\u6574\u987a\u5e8f\uff0c\u653e\u5230\u5faa\u73af\u79ef\u6728\u4e0a\u53ef\u52a0\u5165\u5faa\u73af\u4f53\u3002", 8.0F, UiChrome.Muted);
            _statusLabel.Dock = DockStyle.Fill;
            _statusLabel.TextAlign = ContentAlignment.MiddleLeft;
            _statusLabel.AutoEllipsis = true;

            _stopButton = UiChrome.Button("\u505c\u6b62\u8fd0\u884c");
            _stopButton.Size = new Size(92, 30);
            _stopButton.Anchor = AnchorStyles.None;
            _stopButton.Margin = new Padding(10, 0, 0, 0);
            _stopButton.Enabled = false;
            _stopButton.Click += delegate
            {
                EventHandler handler = StopRequested;
                if (handler != null)
                    handler(this, EventArgs.Empty);
            };
            _footer.Controls.Add(_statusLabel, 0, 0);
            _footer.Controls.Add(_stopButton, 1, 0);

            _heading = new PageHeading("\u624b\u52a8\u64cd\u4f5c\u79ef\u6728",
                "\u81ea\u7531\u7ec4\u5408\u6587\u672c\u3001\u6309\u952e\u3001\u7b49\u5f85\u548c\u5faa\u73af\uff0c\u7f16\u6392\u60a8\u7684\u8f93\u5165\u6d41\u7a0b\u3002");

            Controls.Add(split);
            Controls.Add(_footer);
            Controls.Add(toolbar);
            Controls.Add(_heading);

            RenderProperties();
            UpdateBlockCount();
            LayoutEmptyFlow();
        }

        public void SetStatusText(string message)
        {
            _statusLabel.Text = message ?? String.Empty;
        }

        internal string GetStatusTextForSelfTest()
        {
            return _statusLabel.Text;
        }

        internal void RunFooterLayoutSelfTest()
        {
            _footer.PerformLayout();
            int buttonCenter = _stopButton.Top + _stopButton.Height / 2;
            if (_statusLabel.Dock != DockStyle.Fill ||
                _statusLabel.TextAlign != ContentAlignment.MiddleLeft ||
                Math.Abs(buttonCenter - _footer.ClientSize.Height / 2) > 2)
                throw new InvalidOperationException("The manual-page status and stop action are not vertically aligned.");
        }

        public ManualProgram GetProgram()
        {
            ManualProgram program = new ManualProgram();
            program.Blocks = ReadBlocks(_tree.Nodes);
            return program;
        }

        internal void RunCaptureIntegrationSelfTest()
        {
            AddBlock(ManualBlock.Text);
            ComboBox mode = null;
            foreach (Control control in _propertiesPanel.Controls)
            {
                if (control is ComboBox)
                    mode = (ComboBox)control;
            }
            if (mode == null)
                throw new InvalidOperationException("The input-mode selector was not created.");
            mode.SelectedIndex = 1;
            KeyCaptureTextBox capture = null;
            foreach (Control control in _propertiesPanel.Controls)
            {
                if (control is KeyCaptureTextBox)
                    capture = (KeyCaptureTextBox)control;
            }
            if (capture == null)
                throw new InvalidOperationException("Key mode is not connected to a capture textbox.");
            _dirty = false;
            Message message = Message.Create(capture.Handle, 0x0100, new IntPtr((int)Keys.PageUp), IntPtr.Zero);
            // PageUp is a command key; WinForms must consume it before scrolling/focus handling.
            if (!capture.PreProcessMessage(ref message))
                throw new InvalidOperationException("PageUp was not intercepted by the capture control.");
            ManualProgram program = GetProgram();
            if (capture.Text != "PageUp" || program.Blocks[0].Type != ManualBlock.Key ||
                program.Blocks[0].Value != "PageUp" || !_dirty ||
                !_tree.SelectedNode.Text.Contains("PageUp"))
                throw new InvalidOperationException("Captured PageUp was not reflected in the block label/model.");

            string path = Path.Combine(Path.GetTempPath(), "SimulateKeyboardInput-capture-" + Guid.NewGuid().ToString("N") + ".json");
            try
            {
                ManualProgramStore.Save(path, program);
                LoadProgram(ManualProgramStore.Load(path));
                _tree.SelectedNode = _tree.Nodes[0];
                if (!_tree.Nodes[0].Text.Contains("PageUp") || GetProgram().Blocks[0].Value != "PageUp")
                    throw new InvalidOperationException("Captured key names did not survive JSON reload.");
            }
            finally
            {
                if (File.Exists(path))
                    File.Delete(path);
            }

            foreach (Control control in _propertiesPanel.Controls)
            {
                if (control is ComboBox)
                    mode = (ComboBox)control;
            }
            mode.SelectedIndex = 0;
            foreach (Control control in _propertiesPanel.Controls)
            {
                TextBox text = control as TextBox;
                if (text == null)
                    continue;
                if (text is KeyCaptureTextBox || text.ReadOnly || !text.Multiline)
                    throw new InvalidOperationException("Text mode retained key capture instead of normal editing.");
                text.Text = "normal text";
            }
            if (GetProgram().Blocks[0].Type != ManualBlock.Text || GetProgram().Blocks[0].Value != "normal text")
                throw new InvalidOperationException("Normal text editing was not preserved.");
            _dirty = false;
        }

        public void SetRunState(bool running, string message)
        {
            _stopButton.Enabled = running;
            _statusLabel.Text = message;
        }

        public bool ConfirmClose()
        {
            if (!_dirty)
                return true;
            DialogResult result = MessageBox.Show(this,
                "\u5f53\u524d\u6d41\u7a0b\u6709\u672a\u4fdd\u5b58\u7684\u4fee\u6539\uff0c\u662f\u5426\u4fdd\u5b58\uff1f",
                "\u64cd\u4f5c\u6d41\u7a0b", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
            if (result == DialogResult.Yes)
                return SaveProgram();
            return result == DialogResult.No;
        }

        private static void AddToolbarButton(FlowLayoutPanel toolbar, string text, EventHandler handler, bool soft = false, bool danger = false)
        {
            Button button;
            if (soft)
                button = UiChrome.SoftButton(text);
            else if (danger)
                button = UiChrome.PlainButton(text, UiChrome.Danger);
            else
                button = UiChrome.Button(text);
            if (!soft && !danger)
                button.BackColor = UiChrome.Surface;
            button.Width = Math.Max(72, TextRenderer.MeasureText(text, button.Font).Width + 30);
            button.Height = 32;
            button.Margin = new Padding(0, 0, 6, 0);
            button.Click += handler;
            toolbar.Controls.Add(button);
        }

        private void NewProgram(object sender, EventArgs e)
        {
            if (!ConfirmReplace())
                return;
            _tree.Nodes.Clear();
            _currentPath = null;
            _dirty = false;
            _heading.HideBadge();
            UpdateBlockCount();
            SetStatus("\u65b0\u5efa\u6d41\u7a0b\u5df2\u5c31\u7eea\u3002");
            RenderProperties();
        }

        private void OpenProgram(object sender, EventArgs e)
        {
            if (!ConfirmReplace())
                return;
            using (OpenFileDialog dialog = new OpenFileDialog())
            {
                dialog.Title = "\u6253\u5f00 JSON \u6d41\u7a0b";
                dialog.Filter = "JSON \u6d41\u7a0b\u6587\u4ef6 (*.json)|*.json|\u6240\u6709\u6587\u4ef6 (*.*)|*.*";
                dialog.Multiselect = false;
                dialog.CheckFileExists = true;
                if (dialog.ShowDialog(this) != DialogResult.OK)
                    return;
                try
                {
                    ManualProgram program = ManualProgramStore.Load(dialog.FileName);
                    LoadProgram(program);
                    _currentPath = dialog.FileName;
                    _dirty = false;
                    _heading.HideBadge();
                    SetStatus("\u64cd\u4f5c\u6d41\u7a0b\u5df2\u6253\u5f00\u3002");
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, ex.Message, "\u8bfb\u53d6\u5931\u8d25", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }

        private void SaveProgramClick(object sender, EventArgs e)
        {
            SaveProgram();
        }

        private void SaveAsProgramClick(object sender, EventArgs e)
        {
            SaveAsProgram();
        }

        private bool SaveProgram()
        {
            if (String.IsNullOrEmpty(_currentPath))
                return SaveAsProgram();
            try
            {
                ManualProgramStore.Save(_currentPath, GetProgram());
                _dirty = false;
                _heading.SetBadge("\u2713  \u6240\u6709\u4fee\u6539\u5df2\u4fdd\u5b58", UiChrome.SuccessSoft, UiChrome.Success);
                SetStatus("\u64cd\u4f5c\u6d41\u7a0b\u5df2\u4fdd\u5b58\u3002");
                return true;
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "\u4fdd\u5b58\u5931\u8d25", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }
        }

        private bool SaveAsProgram()
        {
            using (SaveFileDialog dialog = new SaveFileDialog())
            {
                dialog.Title = "\u4fdd\u5b58 JSON \u6d41\u7a0b";
                dialog.Filter = "JSON \u6d41\u7a0b\u6587\u4ef6 (*.json)|*.json|\u6240\u6709\u6587\u4ef6 (*.*)|*.*";
                dialog.DefaultExt = "json";
                dialog.AddExtension = true;
                dialog.OverwritePrompt = true;
                if (!String.IsNullOrEmpty(_currentPath))
                {
                    dialog.InitialDirectory = Path.GetDirectoryName(_currentPath);
                    dialog.FileName = Path.GetFileName(_currentPath);
                }
                if (dialog.ShowDialog(this) != DialogResult.OK)
                    return false;
                try
                {
                    ManualProgramStore.Save(dialog.FileName, GetProgram());
                    _currentPath = dialog.FileName;
                    _dirty = false;
                    _heading.SetBadge("\u2713  \u6240\u6709\u4fee\u6539\u5df2\u4fdd\u5b58", UiChrome.SuccessSoft, UiChrome.Success);
                    SetStatus("\u64cd\u4f5c\u6d41\u7a0b\u5df2\u4fdd\u5b58\u3002");
                    return true;
                }
                catch (Exception ex)
                {
                    MessageBox.Show(this, ex.Message, "\u4fdd\u5b58\u5931\u8d25", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return false;
                }
            }
        }

        private bool ConfirmReplace()
        {
            if (!_dirty)
                return true;
            DialogResult result = MessageBox.Show(this,
                "\u5f53\u524d\u6d41\u7a0b\u6709\u672a\u4fdd\u5b58\u7684\u4fee\u6539\uff0c\u662f\u5426\u4fdd\u5b58\uff1f",
                "\u64cd\u4f5c\u6d41\u7a0b", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
            if (result == DialogResult.Yes)
                return SaveProgram();
            return result == DialogResult.No;
        }

        private void AddBlock(string type)
        {
            ManualBlock block = new ManualBlock { Type = type };
            if (type == ManualBlock.Wait)
                block.Seconds = 1;
            else if (type == ManualBlock.Loop)
                block.MaxIterations = 1;
            else if (type == ManualBlock.Key)
                block.Value = "Enter";
            else
                block.Value = String.Empty;

            TreeNode node = CreateNode(block);
            TreeNode selected = _tree.SelectedNode;
            TreeNodeCollection destination;
            int index;
            if (selected == null)
            {
                destination = _tree.Nodes;
                index = destination.Count;
            }
            else if (((ManualBlock)selected.Tag).Type == ManualBlock.Loop)
            {
                destination = selected.Nodes;
                index = destination.Count;
                selected.Expand();
            }
            else
            {
                destination = selected.Parent == null ? _tree.Nodes : selected.Parent.Nodes;
                index = selected.Index + 1;
            }
            destination.Insert(index, node);
            _tree.SelectedNode = node;
            node.EnsureVisible();
            MarkDirty();
        }

        private void DeleteSelectedBlock(object sender, EventArgs e)
        {
            if (_tree.SelectedNode == null)
                return;
            TreeNode node = _tree.SelectedNode;
            TreeNode next = node.NextNode ?? node.PrevNode ?? node.Parent;
            node.Remove();
            _tree.SelectedNode = next;
            MarkDirty();
        }

        private void TreeItemDrag(object sender, ItemDragEventArgs e)
        {
            TreeNode node = e.Item as TreeNode;
            if (node != null)
                DoDragDrop(node, DragDropEffects.Move);
        }

        private void TreeDragEnter(object sender, DragEventArgs e)
        {
            e.Effect = e.Data.GetDataPresent(typeof(TreeNode)) ? DragDropEffects.Move : DragDropEffects.None;
        }

        private void TreeDragOver(object sender, DragEventArgs e)
        {
            TreeNode source = e.Data.GetData(typeof(TreeNode)) as TreeNode;
            TreeNode target = _tree.GetNodeAt(_tree.PointToClient(new Point(e.X, e.Y)));
            e.Effect = source != null && (target == null || (target != source && !IsDescendant(source, target))) ?
                DragDropEffects.Move : DragDropEffects.None;
        }

        private void TreeDragDrop(object sender, DragEventArgs e)
        {
            TreeNode source = e.Data.GetData(typeof(TreeNode)) as TreeNode;
            TreeNode target = _tree.GetNodeAt(_tree.PointToClient(new Point(e.X, e.Y)));
            if (source == null || target == source || (target != null && IsDescendant(source, target)))
                return;

            TreeNodeCollection destination;
            bool append;
            if (target == null)
            {
                destination = _tree.Nodes;
                append = true;
            }
            else if (((ManualBlock)target.Tag).Type == ManualBlock.Loop)
            {
                destination = target.Nodes;
                append = true;
                target.Expand();
            }
            else
            {
                destination = target.Parent == null ? _tree.Nodes : target.Parent.Nodes;
                append = false;
            }

            source.Remove();
            int index = append ? destination.Count : target.Index + 1;
            destination.Insert(index, source);
            _tree.SelectedNode = source;
            MarkDirty();
        }

        private static bool IsDescendant(TreeNode node, TreeNode possibleAncestor)
        {
            TreeNode current = node.Parent;
            while (current != null)
            {
                if (current == possibleAncestor)
                    return true;
                current = current.Parent;
            }
            return false;
        }

        private TreeNode CreateNode(ManualBlock block)
        {
            TreeNode node = new TreeNode(FormatBlock(block));
            node.Tag = block;
            if (block.Type == ManualBlock.Loop)
                node.BackColor = Color.FromArgb(255, 248, 235);
            else if (block.Type == ManualBlock.Wait)
                node.BackColor = Color.FromArgb(237, 245, 251);
            else if (block.Type == ManualBlock.Key)
                node.BackColor = Color.FromArgb(243, 239, 252);
            else
                node.BackColor = Color.FromArgb(237, 248, 241);
            if (block.Type == ManualBlock.Loop && block.Children != null)
            {
                for (int i = 0; i < block.Children.Count; i++)
                    node.Nodes.Add(CreateNode(block.Children[i]));
            }
            return node;
        }

        private static string FormatBlock(ManualBlock block)
        {
            if (block.Type == ManualBlock.Text)
            {
                string value = (block.Value ?? String.Empty).Replace("\r", " ").Replace("\n", " ");
                if (value.Length > 32)
                    value = value.Substring(0, 32) + "...";
                return "\u8f93\u5165\u6587\u672c\uff1a\u300c" + value + "\u300d";
            }
            if (block.Type == ManualBlock.Key)
                return "\u6309\u952e\uff1a\u300c" + (block.Value ?? String.Empty) + "\u300d";
            if (block.Type == ManualBlock.Wait)
                return "\u7b49\u5f85\uff1a" + block.Seconds.ToString("0.##", CultureInfo.CurrentCulture) + " \u79d2";
            string count = block.MaxIterations == 0 ? "\u4e0d\u9650" :
                block.MaxIterations.ToString(CultureInfo.CurrentCulture) + " \u6b21";
            string duration = block.MaxDurationSeconds == 0 ? "\u4e0d\u9650" :
                block.MaxDurationSeconds.ToString("0.##", CultureInfo.CurrentCulture) + " \u79d2";
            return "\u5faa\u73af\uff1a" + count + " / \u6700\u957f " + duration;
        }

        private void LoadProgram(ManualProgram program)
        {
            _tree.BeginUpdate();
            try
            {
                _tree.Nodes.Clear();
                for (int i = 0; i < program.Blocks.Count; i++)
                    _tree.Nodes.Add(CreateNode(program.Blocks[i]));
            }
            finally
            {
                _tree.EndUpdate();
            }
            RenderProperties();
            UpdateBlockCount();
        }

        private static List<ManualBlock> ReadBlocks(TreeNodeCollection nodes)
        {
            List<ManualBlock> blocks = new List<ManualBlock>();
            for (int i = 0; i < nodes.Count; i++)
            {
                ManualBlock source = (ManualBlock)nodes[i].Tag;
                ManualBlock block = new ManualBlock
                {
                    Type = source.Type,
                    Value = source.Value,
                    Seconds = source.Seconds,
                    MaxIterations = source.MaxIterations,
                    MaxDurationSeconds = source.MaxDurationSeconds,
                    Children = ReadBlocks(nodes[i].Nodes)
                };
                blocks.Add(block);
            }
            return blocks;
        }

        private void RenderProperties()
        {
            _propertiesPanel.Controls.Clear();
            _stretchControls.Clear();
            TreeNode node = _tree.SelectedNode;
            if (node == null)
            {
                _selectionLabel.Text = "\u79ef\u6728\u5c5e\u6027";
                Label empty = UiChrome.Label("\u5148\u9009\u62e9\u4e00\u4e2a\u79ef\u6728\uff0c\u5728\u8fd9\u91cc\u4fee\u6539\u53c2\u6570\u3002", 8.5F, UiChrome.Muted);
                empty.Location = new Point(20, 24);
                _propertiesPanel.Controls.Add(empty);
                return;
            }

            ManualBlock block = (ManualBlock)node.Tag;
            _loadingProperties = true;
            try
            {
                if (block.Type == ManualBlock.Text || block.Type == ManualBlock.Key)
                {
                    _selectionLabel.Text = block.Type == ManualBlock.Text ? "\u8f93\u5165\u79ef\u6728" : "\u6309\u952e\u79ef\u6728";
                    AddPropertyLabel("\u8f93\u5165\u65b9\u5f0f", 15);
                    ComboBox mode = new ComboBox();
                    mode.DropDownStyle = ComboBoxStyle.DropDownList;
                    mode.FlatStyle = FlatStyle.Standard;
                    mode.BackColor = UiChrome.Surface;
                    mode.ForeColor = UiChrome.Text;
                    mode.Font = UiChrome.Font();
                    mode.Items.Add("\u6587\u672c");
                    mode.Items.Add("\u6309\u952e/\u7ec4\u5408\u952e");
                    mode.SelectedIndex = block.Type == ManualBlock.Text ? 0 : 1;
                    mode.Location = new Point(20, 40);
                    mode.Width = Math.Max(180, _propertiesPanel.ClientSize.Width - 42);
                    _propertiesPanel.Controls.Add(mode);
                    _stretchControls.Add(mode);

                    AddPropertyLabel("\u8f93\u5165\u5185\u5bb9", 82);
                    TextBox value = block.Type == ManualBlock.Key ? (TextBox)new KeyCaptureTextBox() : new TextBox();
                    UiChrome.StyleTextBox(value);
                    value.Text = block.Value ?? String.Empty;
                    value.MaxLength = block.Type == ManualBlock.Text ? 100000 : 100;
                    value.Location = new Point(20, 105);
                    value.Width = Math.Max(180, _propertiesPanel.ClientSize.Width - 42);
                    value.Multiline = block.Type == ManualBlock.Text;
                    value.Height = value.Multiline ? 138 : 24;
                    value.ScrollBars = value.Multiline ? ScrollBars.Vertical : ScrollBars.None;
                    _propertiesPanel.Controls.Add(value);
                    _stretchControls.Add(value);

                    mode.SelectedIndexChanged += delegate
                    {
                        if (_loadingProperties)
                            return;
                        block.Type = mode.SelectedIndex == 0 ? ManualBlock.Text : ManualBlock.Key;
                        UpdateNode(node, block);
                        MarkDirty();
                        RenderProperties();
                    };
                    value.TextChanged += delegate
                    {
                        if (_loadingProperties)
                            return;
                        block.Value = value.Text;
                        UpdateNode(node, block);
                        MarkDirty();
                    };
                    if (block.Type == ManualBlock.Key)
                    {
                        Label hint = UiChrome.Label("\u70b9\u51fb\u6846\u540e\u76f4\u63a5\u6309\u952e\uff08\u5982 PageUp\uff09", 8.0F, UiChrome.Muted);
                        hint.Location = new Point(20, 137);
                        _propertiesPanel.Controls.Add(hint);
                    }
                    else
                    {
                        Label hint = UiChrome.Label("\u6587\u672c\u5c06\u6309\u539f\u6837\u8f93\u5165\uff0c\u6362\u884c\u4f1a\u6a21\u62df\u4e3a Enter\u3002", 8.0F, UiChrome.Muted);
                        hint.Location = new Point(20, 250);
                        _propertiesPanel.Controls.Add(hint);
                    }
                }
                else if (block.Type == ManualBlock.Wait)
                {
                    _selectionLabel.Text = "\u7b49\u5f85\u79ef\u6728";
                    AddPropertyLabel("\u7b49\u5f85\u65f6\u95f4\uff08\u79d2\uff09", 15);
                    NumericUpDown seconds = new NumericUpDown();
                    UiChrome.StyleNumeric(seconds);
                    seconds.DecimalPlaces = 2;
                    seconds.Minimum = 0.01M;
                    seconds.Maximum = 3600M;
                    seconds.Increment = 0.1M;
                    seconds.Value = (decimal)block.Seconds;
                    seconds.Location = new Point(16, 39);
                    seconds.Width = 150;
                    seconds.ValueChanged += delegate
                    {
                        if (_loadingProperties)
                            return;
                        block.Seconds = (double)seconds.Value;
                        UpdateNode(node, block);
                        MarkDirty();
                    };
                    _propertiesPanel.Controls.Add(seconds);
                }
                else
                {
                    _selectionLabel.Text = "\u5faa\u73af\u79ef\u6728";
                    AddPropertyLabel("\u5faa\u73af\u6b21\u6570\u4e0a\u9650", 15);
                    NumericUpDown iterations = new NumericUpDown();
                    UiChrome.StyleNumeric(iterations);
                    iterations.Minimum = 0;
                    iterations.Maximum = 1000000;
                    iterations.Value = block.MaxIterations;
                    iterations.Location = new Point(16, 39);
                    iterations.Width = 150;
                    _propertiesPanel.Controls.Add(iterations);
                    AddPropertyLabel("0 \u8868\u793a\u4e0d\u9650", 65);
                    AddPropertyLabel("\u6700\u957f\u8fd0\u884c\u65f6\u95f4\uff08\u79d2\uff09", 95);
                    NumericUpDown duration = new NumericUpDown();
                    UiChrome.StyleNumeric(duration);
                    duration.DecimalPlaces = 2;
                    duration.Minimum = 0;
                    duration.Maximum = 86400;
                    duration.Increment = 1;
                    duration.Value = (decimal)block.MaxDurationSeconds;
                    duration.Location = new Point(16, 119);
                    duration.Width = 150;
                    _propertiesPanel.Controls.Add(duration);
                    AddPropertyLabel("0 \u8868\u793a\u4e0d\u9650", 145);
                    AddPropertyLabel("\u6b21\u6570\u6216\u8fd0\u884c\u65f6\u95f4\u81f3\u5c11\u8bbe\u7f6e\u4e00\u9879\uff1b\u8fbe\u5230\u4efb\u4e00\u4e0a\u9650\u5373\u9000\u51fa\u3002", 178);

                    iterations.ValueChanged += delegate
                    {
                        if (_loadingProperties)
                            return;
                        block.MaxIterations = (int)iterations.Value;
                        UpdateNode(node, block);
                        MarkDirty();
                    };
                    duration.ValueChanged += delegate
                    {
                        if (_loadingProperties)
                            return;
                        block.MaxDurationSeconds = (double)duration.Value;
                        UpdateNode(node, block);
                        MarkDirty();
                    };
                }
            }
            finally
            {
                _loadingProperties = false;
            }
            LayoutPropertyWidths();
        }

        private void AddPropertyLabel(string text, int top)
        {
            Label label = UiChrome.Label(text, 8.5F, UiChrome.Muted);
            label.Location = new Point(20, top);
            _propertiesPanel.Controls.Add(label);
        }

        private void UpdateNode(TreeNode node, ManualBlock block)
        {
            node.Text = FormatBlock(block);
            node.BackColor = block.Type == ManualBlock.Loop ? Color.FromArgb(255, 248, 235) :
                block.Type == ManualBlock.Wait ? Color.FromArgb(237, 245, 251) :
                block.Type == ManualBlock.Key ? Color.FromArgb(243, 239, 252) : Color.FromArgb(237, 248, 241);
        }

        private void MarkDirty()
        {
            _dirty = true;
            _heading.SetBadge("\u25cf  \u6709\u672a\u4fdd\u5b58\u7684\u4fee\u6539", UiChrome.WarningSoft, UiChrome.Warning);
            UpdateBlockCount();
            SetStatus("\u6709\u672a\u4fdd\u5b58\u7684\u4fee\u6539\u3002");
        }

        private void UpdateBlockCount()
        {
            int count = _tree.GetNodeCount(true);
            _blockCountLabel.Text = count.ToString(CultureInfo.CurrentCulture) +
                " \u4e2a\u79ef\u6728 \u00b7 \u6309\u987a\u5e8f\u6267\u884c";
            if (_emptyFlow != null)
                _emptyFlow.Visible = count == 0;
        }

        private void LayoutEmptyFlow()
        {
            if (_emptyFlow == null || _emptyFlow.Parent == null)
                return;
            int width = _emptyFlow.Parent.ClientSize.Width;
            int top = _tree.Top + Math.Max(0, (_tree.Height - _emptyFlow.Height) / 2);
            _emptyFlow.Location = new Point(Math.Max(0, (width - _emptyFlow.Width) / 2), top);
        }

        private void LayoutPropertyWidths()
        {
            int width = Math.Max(160, _propertiesPanel.ClientSize.Width - 40 - SystemInformation.VerticalScrollBarWidth);
            for (int i = 0; i < _stretchControls.Count; i++)
                _stretchControls[i].Width = width;
        }

        private void SetStatus(string text)
        {
            _statusLabel.Text = text;
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
            Text = "\u4fee\u6539\u5168\u5c40\u5feb\u6377\u952e";
            ClientSize = new Size(460, 238);
            BackColor = UiChrome.Surface;
            ForeColor = UiChrome.Text;
            Font = UiChrome.Font();
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterParent;
            KeyPreview = true;

            Label title = UiChrome.Label("\u4fee\u6539\u5168\u5c40\u5feb\u6377\u952e", 13.0F, UiChrome.Text, FontStyle.Bold);
            title.Location = new Point(24, 20);
            Label instruction = UiChrome.Label("\u70b9\u51fb\u4e0b\u65b9\u8f93\u5165\u6846\uff0c\u518d\u6309\u4e0b\u65b0\u7684\u5feb\u6377\u952e\u7ec4\u5408\u3002", 8.5F, UiChrome.Muted);
            instruction.AutoSize = false;
            instruction.Location = new Point(24, 57);
            instruction.Size = new Size(412, 38);
            instruction.Text += "\r\n\u7ec4\u5408\u4e2d\u81f3\u5c11\u5305\u542b Ctrl\u3001Alt \u6216 Shift \u4e4b\u4e00\u3002";

            _captureBox = new TextBox();
            UiChrome.StyleTextBox(_captureBox);
            _captureBox.ReadOnly = true;
            _captureBox.Location = new Point(24, 103);
            _captureBox.Size = new Size(412, 32);
            _captureBox.BackColor = UiChrome.SurfaceSoft;
            _captureBox.Font = UiChrome.Font(11.0F, FontStyle.Bold);
            _captureBox.TextAlign = HorizontalAlignment.Center;
            _captureBox.Text = current.DisplayText();

            _messageLabel = UiChrome.Label("\u7b49\u5f85\u6309\u952e\u2026", 8.0F, UiChrome.Muted);
            _messageLabel.AutoSize = false;
            _messageLabel.Location = new Point(24, 143);
            _messageLabel.Size = new Size(412, 24);

            _saveButton = UiChrome.Button("\u4fdd\u5b58\u5feb\u6377\u952e", true);
            _saveButton.Location = new Point(328, 185);
            _saveButton.Size = new Size(108, 34);
            _saveButton.Enabled = false;
            _saveButton.Click += delegate
            {
                if (SelectedShortcut != null)
                {
                    DialogResult = DialogResult.OK;
                    Close();
                }
            };

            Button cancelButton = UiChrome.Button("\u53d6\u6d88");
            cancelButton.Location = new Point(242, 185);
            cancelButton.Size = new Size(76, 34);
            cancelButton.DialogResult = DialogResult.Cancel;

            Controls.Add(title);
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

        private readonly Panel _shortcutBar;
        private readonly Panel _titleBar;
        private readonly Button _maximizeButton;
        private readonly Label _breadcrumbCurrent;
        private readonly FlowLayoutPanel _headerActions;
        private readonly Label _readyLabel;
        private readonly HotkeyDisplay _hotkeyDisplay;
        private readonly HotkeyDisplay _hotkeySteps;
        private readonly Button _changeShortcutButton;
        private readonly Label _statusLabel;
        private readonly ToggleSwitch _intervalToggle;
        private readonly NumericUpDown _intervalMillisecondsInput;
        private readonly RoundedPanel _intervalControl;
        private readonly Label _intervalDescription;
        private readonly Label _intervalUnitLabel;
        private readonly Panel _settingsBody;
        private readonly Panel _settingsDivider;
        private readonly RoundedPanel _infoBox;
        private readonly Label _infoText;
        private readonly DropZone _dropSurface;
        private readonly Panel _dropEmpty;
        private readonly RoundedPanel _selectedFile;
        private readonly Label _selectedFileName;
        private readonly Label _selectedFileSize;
        private readonly Button _selectedFileRemove;
        private readonly PageHeading _fileHeading;
        private readonly ModernTabControl _sourceTabs;
        private readonly ModernTabPage _manualTab;
        private readonly ManualOperationPanel _manualPanel;
        private string _selectedPath;
        private ShortcutConfiguration _shortcut;
        private bool _hotkeyRegistered;
        private bool _isSending;
        private bool _manualRunning;
        private volatile bool _cancelSending;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr windowHandle, int id, uint modifiers, uint virtualKey);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnregisterHotKey(IntPtr windowHandle, int id);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int virtualKey);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern bool ReleaseCapture();

        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr handle, int message, IntPtr wParam, IntPtr lParam);

        public KeyboardForm()
        {
            _shortcut = ShortcutConfiguration.Load();
            Text = "\u952E\u76D8\u8F93\u5165\u52A9\u624B";
            AutoScaleMode = AutoScaleMode.None;
            BackColor = UiChrome.Background;
            ForeColor = UiChrome.Text;
            Font = UiChrome.Font();
            FormBorderStyle = FormBorderStyle.None;
            MaximizeBox = true;
            StartPosition = FormStartPosition.CenterScreen;

            Rectangle workArea = Screen.PrimaryScreen.WorkingArea;
            int clientWidth = Math.Max(920, Math.Min(1200, workArea.Width - 48));
            int clientHeight = Math.Max(520, Math.Min(760, workArea.Height - 48));
            ClientSize = new Size(clientWidth, clientHeight);
            MinimumSize = new Size(
                Math.Min(1120, workArea.Width - 16),
                Math.Min(600, workArea.Height - 16));
            Padding = new Padding(5);

            _titleBar = new Panel { Dock = DockStyle.Top, Height = 46, BackColor = UiChrome.Surface };
            _titleBar.Paint += delegate(object sender, PaintEventArgs e)
            {
                using (Pen pen = new Pen(UiChrome.Line))
                    e.Graphics.DrawLine(pen, 0, _titleBar.Height - 1, _titleBar.Width, _titleBar.Height - 1);
            };
            BrandMark titleMark = new BrandMark { Location = new Point(10, 4) };
            Label titleText = UiChrome.Label(Text, 9.0F, UiChrome.Text, FontStyle.Bold);
            titleText.Location = new Point(49, 14);
            Button closeButton = CreateWindowButton("\u00D7", "\u5173\u95ED", true);
            closeButton.Click += delegate { Close(); };
            _maximizeButton = CreateWindowButton("\u25A1", "\u6700\u5927\u5316", false);
            _maximizeButton.Click += delegate { ToggleMaximize(); };
            Button minimizeButton = CreateWindowButton("\u2212", "\u6700\u5C0F\u5316", false);
            minimizeButton.Click += delegate { WindowState = FormWindowState.Minimized; };
            _titleBar.Controls.Add(titleMark);
            _titleBar.Controls.Add(titleText);
            _titleBar.Controls.Add(minimizeButton);
            _titleBar.Controls.Add(_maximizeButton);
            _titleBar.Controls.Add(closeButton);
            _titleBar.MouseDown += TitleBarMouseDown;
            titleMark.MouseDown += TitleBarMouseDown;
            titleText.MouseDown += TitleBarMouseDown;
            _titleBar.DoubleClick += delegate { ToggleMaximize(); };
            titleMark.DoubleClick += delegate { ToggleMaximize(); };
            titleText.DoubleClick += delegate { ToggleMaximize(); };

            _shortcutBar = new Panel();
            _shortcutBar.Dock = DockStyle.Top;
            _shortcutBar.Height = 64;
            _shortcutBar.BackColor = UiChrome.Surface;
            _shortcutBar.Paint += delegate(object sender, PaintEventArgs e)
            {
                using (Pen pen = new Pen(UiChrome.Line))
                    e.Graphics.DrawLine(pen, 0, _shortcutBar.Height - 1, _shortcutBar.Width, _shortcutBar.Height - 1);
            };

            FlowLayoutPanel breadcrumb = new FlowLayoutPanel();
            breadcrumb.AutoSize = true;
            breadcrumb.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            breadcrumb.WrapContents = false;
            breadcrumb.Location = new Point(26, 20);
            breadcrumb.BackColor = UiChrome.Surface;
            Label breadcrumbRoot = UiChrome.Label("\u5DE5\u4F5C\u533A", 8.5F, UiChrome.Muted);
            breadcrumbRoot.Margin = new Padding(0, 2, 6, 0);
            Label breadcrumbChevron = UiChrome.Label("\u203A", 9.0F, Color.FromArgb(172, 176, 188));
            breadcrumbChevron.Margin = new Padding(0, 0, 6, 0);
            _breadcrumbCurrent = UiChrome.Label("\u6587\u672C\u6587\u4EF6\u8F93\u5165", 9.0F, Color.FromArgb(69, 75, 91), FontStyle.Bold);
            _breadcrumbCurrent.Margin = new Padding(0, 1, 0, 0);
            breadcrumb.Controls.Add(breadcrumbRoot);
            breadcrumb.Controls.Add(breadcrumbChevron);
            breadcrumb.Controls.Add(_breadcrumbCurrent);
            _shortcutBar.Controls.Add(breadcrumb);

            _headerActions = new FlowLayoutPanel();
            _headerActions.AutoSize = true;
            _headerActions.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            _headerActions.WrapContents = false;
            _headerActions.BackColor = UiChrome.Surface;
            _readyLabel = UiChrome.Label("\u25CF  \u5FEB\u6377\u952E\u5DF2\u5C31\u7EEA", 8.0F, UiChrome.Success);
            _readyLabel.Margin = new Padding(0, 6, 14, 0);
            _hotkeyDisplay = new HotkeyDisplay();
            _hotkeyDisplay.SetDisplay(_shortcut.DisplayText());
            _hotkeyDisplay.Margin = new Padding(0, 2, 12, 0);
            _changeShortcutButton = UiChrome.Button("\u4FEE\u6539");
            _changeShortcutButton.Size = new Size(70, 32);
            _changeShortcutButton.Margin = new Padding(0, 0, 0, 0);
            _changeShortcutButton.Click += ChangeShortcut;
            _headerActions.Controls.Add(_readyLabel);
            _headerActions.Controls.Add(_hotkeyDisplay);
            _headerActions.Controls.Add(_changeShortcutButton);
            _shortcutBar.Controls.Add(_headerActions);
            _shortcutBar.Resize += delegate { LayoutHeaderActions(); };

            Panel workspace = new Panel { Dock = DockStyle.Fill, BackColor = UiChrome.Background };
            Panel sidebar = new Panel { Dock = DockStyle.Left, Width = 210, BackColor = UiChrome.Surface };
            sidebar.Paint += delegate(object sender, PaintEventArgs e)
            {
                using (Pen pen = new Pen(UiChrome.Line))
                    e.Graphics.DrawLine(pen, sidebar.Width - 1, 0, sidebar.Width - 1, sidebar.Height);
            };

            Panel brand = new Panel();
            brand.Location = new Point(18, 20);
            brand.Size = new Size(180, 58);
            brand.BackColor = UiChrome.Surface;
            BrandMark brandMark = new BrandMark();
            brandMark.Location = new Point(0, 0);
            Label brandTitle = UiChrome.Label("\u952E\u76D8\u8F93\u5165\u52A9\u624B", 11.0F, UiChrome.Text, FontStyle.Bold);
            brandTitle.Location = new Point(50, 0);
            Label brandSubtitle = UiChrome.Label("KEYBOARD FLOW", 6.5F, UiChrome.Muted);
            brandSubtitle.Location = new Point(52, 25);
            brand.Controls.Add(brandMark);
            brand.Controls.Add(brandTitle);
            brand.Controls.Add(brandSubtitle);

            Label navHeading = UiChrome.Label("\u5DE5\u4F5C\u533A", 7.5F, UiChrome.Muted);
            navHeading.Location = new Point(20, 102);

            NavButton fileNav = new NavButton("\u6587\u672C\u6587\u4EF6\u8F93\u5165", true);
            fileNav.Location = new Point(14, 126);
            fileNav.Size = new Size(182, 44);
            fileNav.Click += delegate { _sourceTabs.SelectedIndex = 0; };
            NavButton manualNav = new NavButton("\u624B\u52A8\u64CD\u4F5C\u79EF\u6728", false);
            manualNav.Location = new Point(14, 176);
            manualNav.Size = new Size(182, 44);
            manualNav.Click += delegate { _sourceTabs.SelectedIndex = 1; };

            Panel hintContainer = new Panel();
            hintContainer.Dock = DockStyle.Bottom;
            hintContainer.Height = 142;
            hintContainer.Padding = new Padding(12, 0, 12, 12);
            hintContainer.BackColor = UiChrome.Surface;
            RoundedPanel sidebarHint = new RoundedPanel();
            sidebarHint.Dock = DockStyle.Fill;
            sidebarHint.Radius = 12;
            sidebarHint.FillColor = UiChrome.SurfaceSoft;
            sidebarHint.BorderColor = UiChrome.Line;
            VectorIcon hintIcon = new VectorIcon();
            hintIcon.Kind = VectorIconKind.Bolt;
            hintIcon.Tint = UiChrome.Primary;
            hintIcon.BackColor = UiChrome.SurfaceSoft;
            hintIcon.Size = new Size(12, 12);
            hintIcon.Location = new Point(14, 16);
            Label hintTitle = UiChrome.Label("\u5168\u5C40\u5FEB\u901F\u89E6\u53D1", 8.5F, UiChrome.Text, FontStyle.Bold);
            hintTitle.Location = new Point(32, 13);
            Label hintText = UiChrome.Label("\u65E0\u9700\u505C\u7559\u5728\u672C\u7A97\u53E3\uFF0C\u5207\u6362\u5230\u76EE\u6807\u5E94\u7528\u540E\u6309\u5FEB\u6377\u952E\u5373\u53EF\u5F00\u59CB\u3002", 8.0F, UiChrome.Muted);
            hintText.AutoSize = false;
            hintText.Location = new Point(14, 44);
            hintText.Size = new Size(150, 68);
            sidebarHint.Resize += delegate { hintText.Width = Math.Max(60, sidebarHint.ClientSize.Width - 28); };
            sidebarHint.Controls.Add(hintIcon);
            sidebarHint.Controls.Add(hintTitle);
            sidebarHint.Controls.Add(hintText);
            hintContainer.Controls.Add(sidebarHint);

            Label version = UiChrome.Label("Keyboard Flow  \u00b7  v1.2.0", 7.0F, UiChrome.Muted);
            version.Dock = DockStyle.Bottom;
            version.Height = 34;
            version.TextAlign = ContentAlignment.MiddleLeft;
            version.Padding = new Padding(18, 0, 0, 0);

            sidebar.Controls.Add(brand);
            sidebar.Controls.Add(navHeading);
            sidebar.Controls.Add(fileNav);
            sidebar.Controls.Add(manualNav);
            sidebar.Controls.Add(hintContainer);
            sidebar.Controls.Add(version);

            Panel mainHost = new Panel();
            mainHost.Dock = DockStyle.Fill;
            mainHost.BackColor = UiChrome.Background;
            mainHost.Padding = new Padding(28, 22, 28, 16);

            ModernTabPage filePage = new ModernTabPage("\u6587\u672C\u6587\u4EF6\u8F93\u5165");
            filePage.BackColor = UiChrome.Background;
            filePage.Padding = new Padding(0);
            _manualTab = new ModernTabPage("\u624B\u52A8\u64CD\u4F5C\u79EF\u6728");
            _manualTab.BackColor = UiChrome.Background;
            _manualTab.Padding = new Padding(0);
            _manualPanel = new ManualOperationPanel();
            _manualTab.Controls.Add(_manualPanel);

            _fileHeading = new PageHeading("\u6587\u672C\u6587\u4EF6\u8F93\u5165",
                "\u9009\u62E9\u6587\u672C\u5185\u5BB9\uFF0C\u4EE5\u81EA\u7136\u3001\u53EF\u63A7\u7684\u8282\u594F\u8F93\u5165\u5230\u76EE\u6807\u7A97\u53E3\u3002");
            _fileHeading.SetBadge("\u7B49\u5F85\u9009\u62E9\u6587\u4EF6", UiChrome.NeutralSoft, UiChrome.Muted);

            Panel fileFooter = new Panel();
            fileFooter.Dock = DockStyle.Bottom;
            fileFooter.Height = 96;
            fileFooter.BackColor = UiChrome.Background;

            Panel stepsCard = UiChrome.Card();
            stepsCard.Dock = DockStyle.Top;
            stepsCard.Height = 56;
            stepsCard.Paint += UiChrome.PaintCard;
            TableLayoutPanel stepsLayout = new TableLayoutPanel();
            stepsLayout.Dock = DockStyle.Fill;
            stepsLayout.ColumnCount = 3;
            stepsLayout.RowCount = 1;
            stepsLayout.Padding = new Padding(16, 0, 16, 0);
            stepsLayout.BackColor = UiChrome.Surface;
            stepsLayout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            stepsLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            stepsLayout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            stepsLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            FlowLayoutPanel stepsTitle = new FlowLayoutPanel();
            stepsTitle.AutoSize = true;
            stepsTitle.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            stepsTitle.WrapContents = false;
            stepsTitle.Anchor = AnchorStyles.Left;
            stepsTitle.BackColor = UiChrome.Surface;
            VectorIcon stepsIcon = new VectorIcon();
            stepsIcon.Kind = VectorIconKind.Bolt;
            stepsIcon.Tint = UiChrome.Primary;
            stepsIcon.BackColor = UiChrome.Surface;
            stepsIcon.Size = new Size(14, 14);
            stepsIcon.Margin = new Padding(0, 0, 6, 0);
            Label stepsTitleText = UiChrome.Label("\u5F00\u59CB\u8F93\u5165", 9.0F, UiChrome.Text, FontStyle.Bold);
            stepsTitleText.Margin = new Padding(0, 0, 0, 0);
            stepsTitle.Controls.Add(stepsIcon);
            stepsTitle.Controls.Add(stepsTitleText);

            Label stepsText = UiChrome.Label(
                "1  \u9009\u62E9\u6587\u672C\u6587\u4EF6   \u2192   2  \u5207\u6362\u5230\u76EE\u6807\u7A97\u53E3   \u2192   3  \u6309\u4E0B\u5168\u5C40\u5FEB\u6377\u952E",
                8.0F, UiChrome.Muted);
            stepsText.AutoSize = false;
            stepsText.Dock = DockStyle.Fill;
            stepsText.TextAlign = ContentAlignment.MiddleLeft;
            stepsText.AutoEllipsis = true;
            stepsText.Margin = new Padding(20, 0, 12, 0);

            _hotkeySteps = new HotkeyDisplay();
            _hotkeySteps.SetDisplay(_shortcut.DisplayText());
            _hotkeySteps.Anchor = AnchorStyles.None;
            _hotkeySteps.Margin = new Padding(0, 0, 0, 0);

            stepsLayout.Controls.Add(stepsTitle, 0, 0);
            stepsLayout.Controls.Add(stepsText, 1, 0);
            stepsLayout.Controls.Add(_hotkeySteps, 2, 0);
            stepsCard.Controls.Add(stepsLayout);

            Panel statusBar = new Panel();
            statusBar.Dock = DockStyle.Fill;
            statusBar.BackColor = UiChrome.Background;
            statusBar.Padding = new Padding(2, 8, 2, 0);
            TableLayoutPanel statusLayout = new TableLayoutPanel();
            statusLayout.Dock = DockStyle.Fill;
            statusLayout.ColumnCount = 3;
            statusLayout.RowCount = 1;
            statusLayout.BackColor = UiChrome.Background;
            statusLayout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            statusLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            statusLayout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            statusLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));

            VectorIcon statusIcon = new VectorIcon();
            statusIcon.Kind = VectorIconKind.Info;
            statusIcon.Tint = Color.FromArgb(140, 146, 160);
            statusIcon.BackColor = UiChrome.Background;
            statusIcon.Size = new Size(14, 14);
            statusIcon.Anchor = AnchorStyles.None;
            statusIcon.Margin = new Padding(0, 0, 0, 0);
            _statusLabel = UiChrome.Label("\u7B49\u5F85\u9009\u62E9\u6587\u672C\u6587\u4EF6", 8.0F, UiChrome.Muted);
            _statusLabel.AutoSize = false;
            _statusLabel.Dock = DockStyle.Fill;
            _statusLabel.TextAlign = ContentAlignment.MiddleLeft;
            _statusLabel.AutoEllipsis = true;
            _statusLabel.Margin = new Padding(6, 0, 8, 0);
            Label localHint = UiChrome.Label("\u6240\u6709\u5185\u5BB9\u4EC5\u5728\u672C\u673A\u5904\u7406", 8.0F, Color.FromArgb(165, 169, 181));
            localHint.Anchor = AnchorStyles.Right;
            localHint.Margin = new Padding(0, 0, 2, 0);
            statusLayout.Controls.Add(statusIcon, 0, 0);
            statusLayout.Controls.Add(_statusLabel, 1, 0);
            statusLayout.Controls.Add(localHint, 2, 0);
            statusBar.Controls.Add(statusLayout);

            fileFooter.Controls.Add(statusBar);
            fileFooter.Controls.Add(stepsCard);

            TableLayoutPanel fileGrid = new TableLayoutPanel();
            fileGrid.Dock = DockStyle.Fill;
            fileGrid.BackColor = UiChrome.Background;
            fileGrid.ColumnCount = 2;
            fileGrid.RowCount = 1;
            fileGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 64F));
            fileGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 36F));
            fileGrid.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            fileGrid.Margin = new Padding(0);
            fileGrid.Padding = new Padding(0);

            Panel fileCard = UiChrome.Card();
            fileCard.Dock = DockStyle.Fill;
            fileCard.Margin = new Padding(0, 0, 10, 0);
            fileCard.Paint += UiChrome.PaintCard;

            Panel fileCardHeader = new Panel();
            fileCardHeader.Dock = DockStyle.Top;
            fileCardHeader.Height = 56;
            fileCardHeader.BackColor = UiChrome.Surface;
            Label fileCardTitle = UiChrome.Label("\u9009\u62E9\u8F93\u5165\u5185\u5BB9", 10.5F, UiChrome.Text, FontStyle.Bold);
            fileCardTitle.AutoSize = false;
            fileCardTitle.Dock = DockStyle.Fill;
            fileCardTitle.TextAlign = ContentAlignment.MiddleLeft;
            fileCardTitle.Padding = new Padding(19, 0, 0, 0);
            Label fileTypes = UiChrome.Label("TXT    MD    CSV    LOG", 7.0F, UiChrome.Muted);
            fileTypes.Dock = DockStyle.Right;
            fileTypes.Width = 160;
            fileTypes.TextAlign = ContentAlignment.MiddleRight;
            fileTypes.Padding = new Padding(0, 0, 18, 0);
            fileCardHeader.Controls.Add(fileCardTitle);
            fileCardHeader.Controls.Add(fileTypes);

            _dropSurface = new DropZone();
            _dropSurface.Dock = DockStyle.Fill;

            _dropEmpty = new Panel();
            _dropEmpty.Size = new Size(360, 190);
            _dropEmpty.BackColor = _dropSurface.BackColor;

            RoundedPanel uploadBox = new RoundedPanel();
            uploadBox.Location = new Point(152, 0);
            uploadBox.Size = new Size(56, 56);
            uploadBox.Radius = 16;
            uploadBox.FillColor = UiChrome.PrimarySoft;
            VectorIcon uploadIcon = new VectorIcon();
            uploadIcon.Kind = VectorIconKind.Upload;
            uploadIcon.Tint = UiChrome.Primary;
            uploadIcon.BackColor = UiChrome.PrimarySoft;
            uploadIcon.Size = new Size(28, 28);
            uploadIcon.Location = new Point(14, 14);
            uploadBox.Controls.Add(uploadIcon);

            Label dropTitle = UiChrome.Label("\u5C06\u6587\u672C\u6587\u4EF6\u62D6\u5230\u8FD9\u91CC", 11.0F, UiChrome.Text, FontStyle.Bold);
            dropTitle.AutoSize = false;
            dropTitle.Location = new Point(0, 66);
            dropTitle.Size = new Size(360, 26);
            dropTitle.TextAlign = ContentAlignment.MiddleCenter;
            Label dropDescription = UiChrome.Label("\u6216\u4ECE\u60A8\u7684\u7535\u8111\u4E2D\u9009\u62E9\u4E00\u4E2A\u6587\u4EF6", 8.5F, UiChrome.Muted);
            dropDescription.AutoSize = false;
            dropDescription.Location = new Point(0, 96);
            dropDescription.Size = new Size(360, 22);
            dropDescription.TextAlign = ContentAlignment.MiddleCenter;
            Button browseButton = UiChrome.Button("\u6D4F\u89C8\u6587\u4EF6", true);
            browseButton.Location = new Point(128, 132);
            browseButton.Size = new Size(104, 36);
            browseButton.Click += BrowseForFile;
            _dropEmpty.Controls.Add(uploadBox);
            _dropEmpty.Controls.Add(dropTitle);
            _dropEmpty.Controls.Add(dropDescription);
            _dropEmpty.Controls.Add(browseButton);

            _selectedFile = new RoundedPanel();
            _selectedFile.Location = new Point(0, 0);
            _selectedFile.Size = new Size(390, 76);
            _selectedFile.Radius = 12;
            _selectedFile.FillColor = Color.White;
            _selectedFile.BorderColor = Color.FromArgb(225, 222, 249);
            _selectedFile.Visible = false;

            RoundedPanel fileIconBox = new RoundedPanel();
            fileIconBox.Location = new Point(14, 18);
            fileIconBox.Size = new Size(40, 40);
            fileIconBox.Radius = 10;
            fileIconBox.FillColor = UiChrome.PrimarySoft;
            VectorIcon fileIcon = new VectorIcon();
            fileIcon.Kind = VectorIconKind.File;
            fileIcon.Tint = UiChrome.Primary;
            fileIcon.BackColor = UiChrome.PrimarySoft;
            fileIcon.Size = new Size(22, 22);
            fileIcon.Location = new Point(9, 9);
            fileIconBox.Controls.Add(fileIcon);

            _selectedFileName = UiChrome.Label(String.Empty, 9.5F, UiChrome.Text, FontStyle.Bold);
            _selectedFileName.AutoSize = false;
            _selectedFileName.Location = new Point(66, 16);
            _selectedFileName.Size = new Size(250, 22);
            _selectedFileName.AutoEllipsis = true;
            _selectedFileSize = UiChrome.Label(String.Empty, 8.0F, UiChrome.Muted);
            _selectedFileSize.AutoSize = false;
            _selectedFileSize.Location = new Point(66, 41);
            _selectedFileSize.Size = new Size(250, 18);
            _selectedFileSize.AutoEllipsis = true;

            _selectedFileRemove = new Button();
            _selectedFileRemove.Text = "\u00D7";
            _selectedFileRemove.Font = UiChrome.Font(11.0F);
            _selectedFileRemove.FlatStyle = FlatStyle.Flat;
            _selectedFileRemove.FlatAppearance.BorderSize = 0;
            _selectedFileRemove.BackColor = Color.White;
            _selectedFileRemove.ForeColor = UiChrome.Muted;
            _selectedFileRemove.FlatAppearance.MouseOverBackColor = UiChrome.SurfaceSoft;
            _selectedFileRemove.Size = new Size(28, 28);
            _selectedFileRemove.Location = new Point(348, 24);
            _selectedFileRemove.Cursor = Cursors.Hand;
            _selectedFileRemove.Click += delegate { ClearFile(); };

            _selectedFile.Controls.Add(fileIconBox);
            _selectedFile.Controls.Add(_selectedFileName);
            _selectedFile.Controls.Add(_selectedFileSize);
            _selectedFile.Controls.Add(_selectedFileRemove);

            _dropSurface.Controls.Add(_dropEmpty);
            _dropSurface.Controls.Add(_selectedFile);
            _dropSurface.Resize += delegate { LayoutDropStates(); };
            WireDropClick(_dropSurface);

            Panel dropPadding = new Panel();
            dropPadding.Dock = DockStyle.Fill;
            dropPadding.BackColor = UiChrome.Surface;
            dropPadding.Padding = new Padding(20, 14, 20, 20);
            dropPadding.Controls.Add(_dropSurface);

            fileCard.Controls.Add(dropPadding);
            fileCard.Controls.Add(fileCardHeader);

            Panel settingsCard = UiChrome.Card();
            settingsCard.Dock = DockStyle.Fill;
            settingsCard.Margin = new Padding(10, 0, 0, 0);
            settingsCard.Paint += UiChrome.PaintCard;

            Panel settingsHeader = new Panel();
            settingsHeader.Dock = DockStyle.Top;
            settingsHeader.Height = 56;
            settingsHeader.BackColor = UiChrome.Surface;
            Label settingsTitle = UiChrome.Label("\u8F93\u51FA\u8BBE\u7F6E", 10.5F, UiChrome.Text, FontStyle.Bold);
            settingsTitle.AutoSize = false;
            settingsTitle.Dock = DockStyle.Fill;
            settingsTitle.TextAlign = ContentAlignment.MiddleLeft;
            settingsTitle.Padding = new Padding(20, 0, 0, 0);
            Label settingsCaption = UiChrome.Label("\u6309\u9700\u8C03\u6574", 8.0F, UiChrome.Muted);
            settingsCaption.Dock = DockStyle.Right;
            settingsCaption.TextAlign = ContentAlignment.MiddleRight;
            settingsCaption.Padding = new Padding(0, 15, 20, 0);
            settingsHeader.Controls.Add(settingsTitle);
            settingsHeader.Controls.Add(settingsCaption);

            _settingsBody = new Panel();
            _settingsBody.Dock = DockStyle.Fill;
            _settingsBody.BackColor = UiChrome.Surface;

            Label intervalName = UiChrome.Label("\u6309\u5B57\u7B26\u95F4\u9694\u8F93\u51FA", 9.0F, UiChrome.Text, FontStyle.Bold);
            intervalName.Location = new Point(22, 16);
            _intervalDescription = UiChrome.Label("\u6A21\u62DF\u9010\u5B57\u8F93\u5165\uFF0C\u9002\u5408\u9700\u8981\u7B49\u5F85\u54CD\u5E94\u7684\u5E94\u7528", 8.0F, UiChrome.Muted);
            _intervalDescription.AutoSize = true;
            _intervalDescription.Location = new Point(22, 40);
            _intervalDescription.MaximumSize = new Size(200, 0);
            _intervalToggle = new ToggleSwitch();
            _intervalToggle.Location = new Point(200, 18);
            _intervalControl = new RoundedPanel();
            _intervalControl.Location = new Point(22, 88);
            _intervalControl.Size = new Size(240, 44);
            _intervalControl.Radius = 10;
            _intervalControl.FillColor = UiChrome.SurfaceSoft;
            _intervalMillisecondsInput = new NumericUpDown();
            UiChrome.StyleNumeric(_intervalMillisecondsInput);
            _intervalMillisecondsInput.Location = new Point(10, 10);
            _intervalMillisecondsInput.Size = new Size(62, 25);
            _intervalMillisecondsInput.Minimum = 1;
            _intervalMillisecondsInput.Maximum = 1000;
            _intervalMillisecondsInput.Value = 50;
            _intervalMillisecondsInput.Enabled = false;
            _intervalUnitLabel = UiChrome.Label("\u6BEB\u79D2/\u5B57\u7B26 \u00B7 1\u20131000", 7.0F, UiChrome.KeyText);
            _intervalUnitLabel.AutoSize = false;
            _intervalUnitLabel.Location = new Point(78, 13);
            _intervalUnitLabel.Size = new Size(108, 20);
            _intervalUnitLabel.TextAlign = ContentAlignment.MiddleLeft;
            _intervalUnitLabel.BackColor = UiChrome.SurfaceSoft;
            _intervalControl.Controls.Add(_intervalMillisecondsInput);
            _intervalControl.Controls.Add(_intervalUnitLabel);

            _settingsDivider = new Panel();
            _settingsDivider.Location = new Point(22, 146);
            _settingsDivider.Size = new Size(240, 1);
            _settingsDivider.BackColor = UiChrome.Line;

            _infoBox = new RoundedPanel();
            _infoBox.Location = new Point(22, 162);
            _infoBox.Size = new Size(240, 70);
            _infoBox.Radius = 10;
            _infoBox.FillColor = UiChrome.SurfaceSoft;
            VectorIcon infoIcon = new VectorIcon();
            infoIcon.Kind = VectorIconKind.Info;
            infoIcon.Tint = Color.FromArgb(140, 132, 220);
            infoIcon.BackColor = UiChrome.SurfaceSoft;
            infoIcon.Size = new Size(16, 16);
            infoIcon.Location = new Point(14, 16);
            _infoText = UiChrome.Label("\u5173\u95ED\u95F4\u9694\u65F6\u5C06\u5FEB\u901F\u8F93\u51FA\u5168\u6587\uFF1B\u6362\u884C\u548C\u5236\u8868\u7B26\u5206\u522B\u6A21\u62DF\u4E3A Enter \u4E0E Tab\u3002",
                7.5F, UiChrome.Muted);
            _infoText.AutoSize = true;
            _infoText.Location = new Point(40, 12);
            _infoText.MaximumSize = new Size(190, 0);
            _infoText.BackColor = UiChrome.SurfaceSoft;
            _infoBox.Controls.Add(infoIcon);
            _infoBox.Controls.Add(_infoText);

            _intervalToggle.CheckedChanged += delegate { ApplyIntervalState(); };
            _settingsBody.Controls.Add(intervalName);
            _settingsBody.Controls.Add(_intervalDescription);
            _settingsBody.Controls.Add(_intervalToggle);
            _settingsBody.Controls.Add(_intervalControl);
            _settingsBody.Controls.Add(_settingsDivider);
            _settingsBody.Controls.Add(_infoBox);
            _settingsBody.Resize += delegate { LayoutSettings(); };

            settingsCard.Controls.Add(_settingsBody);
            settingsCard.Controls.Add(settingsHeader);
            fileGrid.Controls.Add(fileCard, 0, 0);
            fileGrid.Controls.Add(settingsCard, 1, 0);

            filePage.Controls.Add(fileGrid);
            filePage.Controls.Add(fileFooter);
            filePage.Controls.Add(_fileHeading);
            EnableFileDrop(filePage);

            _sourceTabs = new ModernTabControl();
            _sourceTabs.Dock = DockStyle.Fill;
            _sourceTabs.TabStop = false;
            _sourceTabs.SelectedIndexChanged += delegate
            {
                UpdateNavigation(fileNav, manualNav);
                _sourceTabs.HideHeaders();
            };
            _sourceTabs.TabPages.Add(filePage);
            _sourceTabs.TabPages.Add(_manualTab);
            mainHost.Controls.Add(_sourceTabs);
            _sourceTabs.SendToBack();

            workspace.Controls.Add(mainHost);
            workspace.Controls.Add(sidebar);
            Controls.Add(workspace);
            Controls.Add(_shortcutBar);
            Controls.Add(_titleBar);

            UpdateNavigation(fileNav, manualNav);
            ApplyIntervalState();
            LayoutDropStates();
            LayoutSettings();
            LayoutHeaderActions();

            _manualPanel.StopRequested += delegate
            {
                if (_manualRunning)
                {
                    _cancelSending = true;
                    _manualPanel.SetRunState(true, "\u6B63\u5728\u505C\u6B62\u64CD\u4F5C\u6D41\u7A0B\u2026");
                }
            };
            FormClosing += delegate(object sender, FormClosingEventArgs e)
            {
                if (!_manualPanel.ConfirmClose())
                {
                    e.Cancel = true;
                    return;
                }
                _cancelSending = true;
            };
        }

        public static void Run()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            KeyboardForm form = new KeyboardForm();
            form.Shown += delegate { form.InitializeRuntime(); };
            Application.Run(form);
        }

        private void UpdateNavigation(NavButton fileNav, NavButton manualNav)
        {
            bool manual = _sourceTabs.SelectedTab == _manualTab;
            manualNav.Active = manual;
            fileNav.Active = !manual;
            _breadcrumbCurrent.Text = manual ? "\u624B\u52A8\u64CD\u4F5C\u79EF\u6728" : "\u6587\u672C\u6587\u4EF6\u8F93\u5165";
            LayoutHeaderActions();
        }

        internal void RunSharedChromeSelfTest()
        {
            PerformLayout();
            _shortcutBar.PerformLayout();
            if (Controls.Count != 3 || _titleBar.Parent != this || _shortcutBar.Parent != this ||
                _shortcutBar.Dock != DockStyle.Top || _sourceTabs.Dock != DockStyle.Fill ||
                _headerActions.Parent != _shortcutBar ||
                _hotkeyDisplay.Parent != _headerActions ||
                _changeShortcutButton.Parent != _headerActions ||
                _sourceTabs.TabPages.Count != 2 ||
                _changeShortcutButton.Text != "\u4FEE\u6539" ||
                _hotkeyDisplay.DisplayText != _shortcut.DisplayText() ||
                _shortcutBar.Top != _titleBar.Bottom || _sourceTabs.Height <= 0)
                throw new InvalidOperationException(
                    "The shared shortcut header and sidebar navigation are not connected to both source pages.");
        }

        internal void RunStatusRoutingSelfTest()
        {
            ModernTabPage originalTab = _sourceTabs.SelectedTab;
            string originalFileStatus = _statusLabel.Text;
            string originalManualStatus = _manualPanel.GetStatusTextForSelfTest();
            try
            {
                const string manualMessage = "manual status routing test";
                _sourceTabs.SelectedTab = _manualTab;
                SetStatus(manualMessage);
                if (_statusLabel.Text != originalFileStatus ||
                    _manualPanel.GetStatusTextForSelfTest() != manualMessage)
                    throw new InvalidOperationException("Manual-page status was not isolated from the inactive file page.");

                const string fileMessage = "file status routing test";
                _sourceTabs.SelectedTab = _sourceTabs.TabPages[0];
                SetStatus(fileMessage);
                if (_statusLabel.Text != fileMessage ||
                    _manualPanel.GetStatusTextForSelfTest() != manualMessage)
                    throw new InvalidOperationException("File-page status leaked into the inactive manual page.");
            }
            finally
            {
                _statusLabel.Text = originalFileStatus;
                _manualPanel.SetStatusText(originalManualStatus);
                _sourceTabs.SelectedTab = originalTab;
            }
        }

        private void InitializeRuntime()
        {
            if (_sourceTabs.TabPages.Count > 0)
                _sourceTabs.SelectedIndex = 0;
            if (RegisterShortcut(_shortcut))
            {
                SetReadyState(true);
                SetStatus("\u5FEB\u6377\u952E\u5DF2\u5C31\u7EEA\uFF08" + _shortcut.DisplayText() + "\uFF09\uFF1B\u8BF7\u9009\u62E9\u6587\u4EF6\u3002");
            }
            else
            {
                SetReadyState(false);
                SetStatus("\u5FEB\u6377\u952E\u6CE8\u518C\u5931\u8D25\uFF08Windows \u9519\u8BEF\u7801: " + Marshal.GetLastWin32Error() + "\uFF09\uFF0C\u53EF\u80FD\u5DF2\u88AB\u5360\u7528\u3002");
                _manualPanel.SetRunState(false, "\u5168\u5C40\u5FEB\u6377\u952E\u6CE8\u518C\u5931\u8D25\uFF0C\u8BF7\u4FEE\u6539\u5FEB\u6377\u952E\u540E\u91CD\u8BD5\u3002");
            }
            _sourceTabs.HideHeaders();
        }

        private void SetReadyState(bool ready)
        {
            _readyLabel.Text = ready ? "\u25CF  \u5FEB\u6377\u952E\u5DF2\u5C31\u7EEA" : "\u25CF  \u5FEB\u6377\u952E\u4E0D\u53EF\u7528";
            _readyLabel.ForeColor = ready ? UiChrome.Success : UiChrome.Danger;
            LayoutHeaderActions();
        }

        private void ShowShortcut()
        {
            string text = _shortcut.DisplayText();
            _hotkeyDisplay.SetDisplay(text);
            _hotkeySteps.SetDisplay(text);
            LayoutHeaderActions();
        }

        private void LayoutHeaderActions()
        {
            _headerActions.Location = new Point(
                Math.Max(24, _shortcutBar.ClientSize.Width - _headerActions.Width - 24), 16);
        }

        private static Button CreateWindowButton(string text, string accessibleName, bool close)
        {
            Button button = UiChrome.PlainButton(text, UiChrome.Muted);
            button.Dock = DockStyle.Right;
            button.Width = 45;
            button.Font = UiChrome.Font(12.0F);
            button.AccessibleName = accessibleName;
            button.TabStop = true;
            if (close)
            {
                button.FlatAppearance.MouseOverBackColor = UiChrome.Danger;
                button.MouseEnter += delegate { button.ForeColor = Color.White; };
                button.MouseLeave += delegate { button.ForeColor = UiChrome.Muted; };
            }
            return button;
        }

        private void ToggleMaximize()
        {
            if (WindowState == FormWindowState.Maximized)
                WindowState = FormWindowState.Normal;
            else
            {
                MaximizedBounds = Screen.FromControl(this).WorkingArea;
                WindowState = FormWindowState.Maximized;
            }
        }

        private void TitleBarMouseDown(object sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left && e.Clicks == 1)
            {
                ReleaseCapture();
                SendMessage(Handle, 0x00A1, new IntPtr(2), IntPtr.Zero);
            }
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            Padding = WindowState == FormWindowState.Maximized ? Padding.Empty : new Padding(5);
            if (_maximizeButton != null)
            {
                _maximizeButton.Text = WindowState == FormWindowState.Maximized ? "\u2750" : "\u25A1";
                _maximizeButton.AccessibleName = WindowState == FormWindowState.Maximized ? "\u8FD8\u539F" : "\u6700\u5927\u5316";
            }
        }

        protected override void OnHandleDestroyed(EventArgs e)
        {
            UnregisterCurrentShortcut();
            base.OnHandleDestroyed(e);
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x0084 && WindowState == FormWindowState.Normal)
            {
                Point point = PointToClient(new Point(unchecked((short)(long)message.LParam),
                    unchecked((short)((long)message.LParam >> 16))));
                bool left = point.X < 5, right = point.X >= ClientSize.Width - 5;
                bool top = point.Y < 5, bottom = point.Y >= ClientSize.Height - 5;
                int hit = top ? (left ? 13 : right ? 14 : 12) :
                    bottom ? (left ? 16 : right ? 17 : 15) : left ? 10 : right ? 11 : 0;
                if (hit != 0)
                {
                    message.Result = new IntPtr(hit);
                    return;
                }
            }
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
                dialog.Title = "\u9009\u62E9\u8981\u8F93\u5165\u7684\u6587\u672C\u6587\u4EF6";
                dialog.Filter = "\u6587\u672C\u6587\u4EF6 (*.txt;*.text;*.md;*.csv;*.log)|*.txt;*.text;*.md;*.csv;*.log|\u6240\u6709\u6587\u4EF6 (*.*)|*.*";
                dialog.Multiselect = false;
                dialog.CheckFileExists = true;
                if (dialog.ShowDialog(this) == DialogResult.OK)
                    SelectFile(dialog.FileName);
            }
        }

        private void SelectFile(string path)
        {
            _selectedPath = path;
            _dropEmpty.Visible = false;
            _selectedFile.Visible = true;
            _selectedFileName.Text = Path.GetFileName(path);
            long length = 0;
            try
            {
                length = new FileInfo(path).Length;
            }
            catch
            {
                // A file that disappears between selection and display still leaves a usable name.
            }
            _selectedFileSize.Text = FormatFileSize(length) + " \u00B7 \u5DF2\u51C6\u5907\u8F93\u5165";
            _fileHeading.SetBadge("\u2713  \u6587\u4EF6\u5DF2\u5C31\u7EEA", UiChrome.SuccessSoft, UiChrome.Success);
            if (_hotkeyRegistered)
                SetStatus("\u6587\u4EF6\u5DF2\u9009\u4E2D\uFF1B\u5207\u6362\u5230\u76EE\u6807\u7A97\u53E3\u540E\u6309 " + _shortcut.DisplayText() + "\u3002");
            else
                SetStatus("\u6587\u4EF6\u5DF2\u9009\u4E2D\uFF0C\u4F46\u5168\u5C40\u5FEB\u6377\u952E\u4E0D\u53EF\u7528\u3002");
            LayoutDropStates();
        }

        private void ClearFile()
        {
            _selectedPath = null;
            _selectedFileName.Text = String.Empty;
            _selectedFileSize.Text = String.Empty;
            _dropEmpty.Visible = true;
            _selectedFile.Visible = false;
            _fileHeading.SetBadge("\u7B49\u5F85\u9009\u62E9\u6587\u4EF6", UiChrome.NeutralSoft, UiChrome.Muted);
            SetStatus("\u7B49\u5F85\u9009\u62E9\u6587\u672C\u6587\u4EF6");
        }

        private static string FormatFileSize(long bytes)
        {
            if (bytes < 1024)
                return bytes.ToString(CultureInfo.CurrentCulture) + " B";
            if (bytes < 1024 * 1024)
                return (bytes / 1024.0).ToString("0.0", CultureInfo.CurrentCulture) + " KB";
            return (bytes / (1024.0 * 1024.0)).ToString("0.0", CultureInfo.CurrentCulture) + " MB";
        }

        private void LayoutDropStates()
        {
            int width = _dropSurface.ClientSize.Width;
            int height = _dropSurface.ClientSize.Height;
            _dropEmpty.Location = new Point(
                Math.Max(0, (width - _dropEmpty.Width) / 2),
                Math.Max(0, (height - _dropEmpty.Height) / 2));
            int chipWidth = Math.Min(390, Math.Max(220, width - 64));
            _selectedFile.Size = new Size(chipWidth, 76);
            _selectedFile.Location = new Point(
                Math.Max(0, (width - chipWidth) / 2),
                Math.Max(0, (height - _selectedFile.Height) / 2));
            int removeX = chipWidth - 42;
            _selectedFileRemove.Location = new Point(removeX, 24);
            _selectedFileName.Width = Math.Max(60, removeX - 66 - 10);
            _selectedFileSize.Width = _selectedFileName.Width;
        }

        private void ApplyIntervalState()
        {
            bool enabled = _intervalToggle.Checked;
            _intervalMillisecondsInput.Enabled = enabled;
            Color fill = enabled ? UiChrome.SurfaceSoft : Color.FromArgb(243, 244, 247);
            _intervalControl.FillColor = fill;
            _intervalUnitLabel.BackColor = fill;
            _intervalUnitLabel.ForeColor = enabled ? UiChrome.KeyText : Color.FromArgb(163, 167, 178);
        }

        private void LayoutSettings()
        {
            int usable = Math.Max(200, _settingsBody.ClientSize.Width - SystemInformation.VerticalScrollBarWidth);
            int inner = Math.Max(160, usable - 44);
            int switchX = Math.Max(22, usable - 22 - _intervalToggle.Width);
            _intervalToggle.Location = new Point(switchX, 18);
            _intervalDescription.MaximumSize = new Size(Math.Max(100, switchX - 22 - 14), 0);
            _intervalControl.Width = inner;
            _intervalControl.Location = new Point(22, _intervalDescription.Bottom + 14);
            _intervalUnitLabel.Width = Math.Max(80, inner - 88);

            _infoText.MaximumSize = new Size(Math.Max(80, inner - 54), 0);
            int infoHeight = Math.Max(52, _infoText.Height + 24);
            int dividerTop = _intervalControl.Bottom + 12;
            int infoTop = dividerTop + 10;
            int naturalBottom = infoTop + infoHeight + 10;
            int spare = _settingsBody.ClientSize.Height - naturalBottom;
            bool showInfo = _settingsBody.ClientSize.Height >= naturalBottom;
            _settingsDivider.Visible = showInfo;
            _infoBox.Visible = showInfo;
            if (showInfo)
            {
                if (spare > 0)
                {
                    dividerTop += spare;
                    infoTop = dividerTop + 10;
                }
                _settingsDivider.Location = new Point(22, dividerTop);
                _settingsDivider.Width = inner;
                _infoBox.Location = new Point(22, infoTop);
                _infoBox.Width = inner;
                _infoBox.Height = infoHeight;
            }
            else
            {
                _settingsDivider.Bounds = new Rectangle(0, 0, 0, 0);
                _infoBox.Bounds = new Rectangle(0, 0, 0, 0);
            }
        }

        private void WireDropClick(Control control)
        {
            if (!(control is Button))
                control.Click += BrowseForFile;
            foreach (Control child in control.Controls)
                WireDropClick(child);
        }

        private void EnableFileDrop(Control control)
        {
            control.AllowDrop = true;
            control.DragEnter += FileDragEnter;
            control.DragOver += FileDragEnter;
            control.DragLeave += FileDragLeave;
            control.DragDrop += FileDragDrop;
            foreach (Control child in control.Controls)
                EnableFileDrop(child);
        }

        private static string GetDroppedFile(DragEventArgs e)
        {
            if ((e.AllowedEffect & DragDropEffects.Copy) == 0 || e.Data == null ||
                !e.Data.GetDataPresent(DataFormats.FileDrop))
                return null;
            string[] paths = e.Data.GetData(DataFormats.FileDrop) as string[];
            return paths != null && paths.Length == 1 && File.Exists(paths[0]) ? paths[0] : null;
        }

        private void FileDragEnter(object sender, DragEventArgs e)
        {
            bool valid = GetDroppedFile(e) != null;
            e.Effect = valid ? DragDropEffects.Copy : DragDropEffects.None;
            Control control = sender as Control;
            if (control != null && (control == _dropSurface || _dropSurface.Contains(control)))
                _dropSurface.Dragging = valid;
        }

        private void FileDragLeave(object sender, EventArgs e)
        {
            Control control = sender as Control;
            if (control != null && (control == _dropSurface || _dropSurface.Contains(control)))
                _dropSurface.Dragging = false;
        }

        private void FileDragDrop(object sender, DragEventArgs e)
        {
            string path = GetDroppedFile(e);
            e.Effect = path != null ? DragDropEffects.Copy : DragDropEffects.None;
            _dropSurface.Dragging = false;
            if (path != null)
                SelectFile(path);
        }

        internal void RunFileDropSelfTest()
        {
            string originalPath = _selectedPath;
            string originalStatus = _statusLabel.Text;
            string temporaryPath = Path.Combine(Path.GetTempPath(),
                "SimulateKeyboardInput-drop-" + Guid.NewGuid().ToString("N") + " \u6587\u672C.txt");
            try
            {
                File.WriteAllText(temporaryPath, "drop test");
                Control[] targets = new Control[] { _sourceTabs.TabPages[0], _dropSurface };
                foreach (Control target in targets)
                {
                    ClearFile();
                    _statusLabel.Text = originalStatus;
                    DataObject data = new DataObject(DataFormats.FileDrop, new string[] { temporaryPath });
                    DragEventArgs drag = new DragEventArgs(data, 0, 0, 0, DragDropEffects.Copy, DragDropEffects.None);
                    if (!target.AllowDrop)
                        throw new InvalidOperationException("The file page and drop area must accept drops.");
                    typeof(Control).GetMethod("OnDragEnter", System.Reflection.BindingFlags.Instance |
                        System.Reflection.BindingFlags.NonPublic).Invoke(target, new object[] { drag });
                    if (drag.Effect != DragDropEffects.Copy)
                        throw new InvalidOperationException("A single existing file was not accepted.");
                    typeof(Control).GetMethod("OnDragDrop", System.Reflection.BindingFlags.Instance |
                        System.Reflection.BindingFlags.NonPublic).Invoke(target, new object[] { drag });
                    if (_selectedPath != temporaryPath ||
                        _selectedFileName.Text != Path.GetFileName(temporaryPath) ||
                        _selectedFileSize.Text.Length == 0 ||
                        _statusLabel.Text == originalStatus)
                        throw new InvalidOperationException("A dropped file did not update the selection and status.");
                }

                object[] rejectedData = new object[]
                {
                    new string[] { Path.GetDirectoryName(temporaryPath) },
                    new string[] { temporaryPath, temporaryPath },
                    new string[] { temporaryPath + ".missing" },
                    new string[0], "plain text"
                };
                foreach (object value in rejectedData)
                {
                    DataObject data = value is string[] ? new DataObject(DataFormats.FileDrop, value) :
                        new DataObject(DataFormats.Text, value);
                    DragEventArgs drag = new DragEventArgs(data, 0, 0, 0, DragDropEffects.Copy, DragDropEffects.Copy);
                    FileDragEnter(_dropSurface, drag);
                    FileDragDrop(_dropSurface, drag);
                    if (drag.Effect != DragDropEffects.None || _selectedPath != temporaryPath ||
                        _selectedFileName.Text != Path.GetFileName(temporaryPath))
                        throw new InvalidOperationException("An invalid drop replaced the selected file.");
                }
            }
            finally
            {
                if (originalPath == null)
                    ClearFile();
                else
                    SelectFile(originalPath);
                _statusLabel.Text = originalStatus;
                if (File.Exists(temporaryPath))
                    File.Delete(temporaryPath);
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
                        SetStatus("\u5FEB\u6377\u952E\u672A\u66F4\u6539\u3002");
                        return;
                    }

                    ShortcutConfiguration updated = dialog.SelectedShortcut;
                    if (!RegisterShortcut(updated))
                    {
                        int error = Marshal.GetLastWin32Error();
                        SetStatus("\u65B0\u5FEB\u6377\u952E\u4E0D\u53EF\u7528\uFF08Windows \u9519\u8BEF\u7801: " + error + "\uFF09\uFF1B\u53EF\u80FD\u5DF2\u88AB\u5360\u7528\u3002");
                        return;
                    }

                    try
                    {
                        updated.Save();
                    }
                    catch (Exception ex)
                    {
                        SetStatus("\u4FDD\u5B58\u5FEB\u6377\u952E\u5931\u8D25\uFF1A" + ex.Message);
                        return;
                    }

                    _shortcut = updated;
                    ShowShortcut();
                    SetReadyState(true);
                    saved = true;
                    SetStatus("\u5FEB\u6377\u952E\u5DF2\u66F4\u65B0\u5E76\u4FDD\u5B58\u3002");
                }
            }
            catch (Exception ex)
            {
                SetStatus("\u8BBE\u7F6E\u5FEB\u6377\u952E\u5931\u8D25\uFF1A" + ex.Message);
            }
            finally
            {
                if (!saved)
                {
                    UnregisterCurrentShortcut();
                    _shortcut = previous;
                    ShowShortcut();
                    if (RegisterShortcut(previous))
                        SetReadyState(true);
                    else
                    {
                        SetReadyState(false);
                        SetStatus("\u65E0\u6CD5\u6062\u590D\u539F\u5FEB\u6377\u952E\uFF08Windows \u9519\u8BEF\u7801: " + Marshal.GetLastWin32Error() + "\uFF09\u3002");
                    }
                }
            }
        }

        private void HandleHotkey()
        {
            if (!_hotkeyRegistered)
                return;
            if (_manualRunning)
            {
                _cancelSending = true;
                _manualPanel.SetRunState(true, "\u6536\u5230\u505C\u6B62\u6307\u4EE4\uFF0C\u6B63\u5728\u7ED3\u675F\u64CD\u4F5C\u2026");
                return;
            }
            if (_isSending)
            {
                SetStatus("\u6B63\u5728\u9010\u5B57\u7B26\u8F93\u5165\uFF0C\u8BF7\u7A0D\u5019\u3002");
                return;
            }
            if (_sourceTabs.SelectedTab == _manualTab)
            {
                if (GetForegroundWindow() == Handle)
                {
                    _manualPanel.SetRunState(false, "\u8BF7\u5148\u5207\u6362\u5230\u76EE\u6807\u7A97\u53E3\uFF0C\u518D\u6309\u5FEB\u6377\u952E\u6267\u884C\u3002");
                    return;
                }
                StartManualProgram();
                return;
            }
            if (String.IsNullOrEmpty(_selectedPath))
            {
                SetStatus("\u8BF7\u5148\u9009\u62E9\u6587\u672C\u6587\u4EF6\u3002");
                return;
            }

            string text;
            try
            {
                text = KeyboardInput.ReadText(_selectedPath);
            }
            catch (Exception ex)
            {
                SetStatus("\u8BFB\u53D6\u5931\u8D25\uFF1A" + ex.Message);
                return;
            }

            if (text.Length == 0)
            {
                SetStatus("\u6587\u4EF6\u5185\u5BB9\u4E3A\u7A7A\u3002");
                return;
            }

            if (!WaitForHotkeyRelease())
            {
                SetStatus("\u8BF7\u5148\u677E\u5F00\u5FEB\u6377\u952E\u540E\u91CD\u8BD5\u3002");
                return;
            }

            try
            {
                if (_intervalToggle.Checked)
                    StartIntervalSend(text, (int)_intervalMillisecondsInput.Value);
                else
                {
                    KeyboardInput.SendText(text);
                    SetStatus("\u8F93\u5165\u5B8C\u6210\u3002");
                }
            }
            catch (Exception ex)
            {
                SetStatus("\u8F93\u5165\u5931\u8D25\uFF1A" + ex.Message);
            }
        }

        private void StartManualProgram()
        {
            ManualProgram program;
            try
            {
                program = _manualPanel.GetProgram();
                ManualProgramValidator.Validate(program, true);
            }
            catch (Exception ex)
            {
                _manualPanel.SetRunState(false, "\u65E0\u6CD5\u8FD0\u884C\uFF1A" + ex.Message);
                return;
            }

            if (!WaitForHotkeyRelease())
            {
                _manualPanel.SetRunState(false, "\u8BF7\u5148\u677E\u5F00\u5FEB\u6377\u952E\u540E\u91CD\u8BD5\u3002");
                return;
            }

            _isSending = true;
            _manualRunning = true;
            _cancelSending = false;
            _manualPanel.SetRunState(true, "\u6B63\u5728\u8FD0\u884C\u64CD\u4F5C\u6D41\u7A0B\uFF1B\u518D\u6B21\u6309\u5FEB\u6377\u952E\u53EF\u53D6\u6D88\u3002");

            Thread worker = new Thread(delegate()
            {
                string finalStatus;
                try
                {
                    bool completed = ManualProgramRunner.Run(program,
                        delegate(string text, Func<bool> cancellationRequested)
                        {
                            return KeyboardInput.SendTextCancellable(text, cancellationRequested);
                        },
                        delegate(string chord) { KeyboardInput.SendKeyChord(chord); },
                        delegate { return _cancelSending; },
                        delegate(int milliseconds) { Thread.Sleep(milliseconds); });
                    finalStatus = completed ? "\u64CD\u4F5C\u6D41\u7A0B\u6267\u884C\u5B8C\u6210\u3002" : "\u64CD\u4F5C\u6D41\u7A0B\u5DF2\u505C\u6B62\u3002";
                }
                catch (Exception ex)
                {
                    finalStatus = "\u6267\u884C\u5931\u8D25\uFF1A" + ex.Message;
                }

                if (!IsDisposed && IsHandleCreated)
                {
                    try
                    {
                        BeginInvoke(new MethodInvoker(delegate
                        {
                            _manualRunning = false;
                            _isSending = false;
                            _manualPanel.SetRunState(false, finalStatus);
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
            catch (Exception ex)
            {
                _manualRunning = false;
                _isSending = false;
                _manualPanel.SetRunState(false, "\u542F\u52A8\u5931\u8D25\uFF1A" + ex.Message);
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
                    finalStatus = completed ? "\u8F93\u5165\u5B8C\u6210\u3002" : "\u8F93\u5165\u5DF2\u53D6\u6D88\u3002";
                }
                catch (Exception ex)
                {
                    finalStatus = "\u8F93\u5165\u5931\u8D25\uFF1A" + ex.Message;
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
            SetStatus("\u6B63\u5728\u9010\u5B57\u7B26\u8F93\u5165\u2026");
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
            if (_sourceTabs.SelectedTab == _manualTab)
                _manualPanel.SetStatusText(text);
            else
                _statusLabel.Text = text;
        }
    }

}
'@

    Add-Type -TypeDefinition $source -ReferencedAssemblies @(
        'System.Windows.Forms.dll',
        'System.Drawing.dll',
        'System.Runtime.Serialization.dll',
        'System.Xml.dll'
    )
}

if ($SelfTest) {
    Write-Output ([SimulateKeyboardInput.KeyboardInput]::RunSelfTests())
    Write-Output ([SimulateKeyboardInput.ManualProgramTests]::RunSelfTests())
    exit 0
}

[SimulateKeyboardInput.KeyboardForm]::Run()
